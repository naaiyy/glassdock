import CryptoKit
import Foundation
import ZIPFoundation

struct MachineManifest: Codable {
    var schemaVersion = 1
    var files: [String: String]
}

enum MachineArchiveStorage {
    static let reserve: UInt64 = 2 * 1024 * 1024 * 1024
    static func requiredDirectorySpace(payloadBytes: UInt64, canClone: Bool) throws -> UInt64 {
        let (required, overflow) = (canClone ? 0 : payloadBytes).addingReportingOverflow(reserve)
        guard !overflow else { throw MachineError.invalid("Machine is too large to copy") }
        return required
    }
    static func requiredExportSpace(payloadBytes: UInt64, compact: Bool) throws -> UInt64 {
        // Compact conversion and the ZIP coexist. Compression is not guaranteed
        // for already compressed guest data, so budget the uncompressed bound.
        let (staging, overflow) = payloadBytes.multipliedReportingOverflow(by: compact ? 2 : 1)
        let (required, reserveOverflow) = staging.addingReportingOverflow(reserve)
        guard !overflow, !reserveOverflow else { throw MachineError.invalid("Machine is too large to export") }
        return required
    }
}

extension MachineStore {
    func writeManifest(at directory: URL) throws {
        let manifest = MachineManifest(files: try hashes(at: directory))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
    }
    func hashes(at directory: URL) throws -> [String: String] {
        // URL enumerators resolve /var aliases even when Foundation keeps the
        // input URL as /var. Use the enumerator's relative paths directly.
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: directory.path) else {
            throw MachineError.invalid("Cannot enumerate archive state")
        }
        var result: [String: String] = [:]
        var entries = 0
        for case let relative as String in enumerator {
            let file = directory.appendingPathComponent(relative)
            entries += 1
            guard entries <= 65536 else { throw MachineError.invalid("VM archive has too many entries") }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey])
            guard values.isSymbolicLink != true else { throw MachineError.invalid("VM archives cannot contain symbolic links") }
            guard values.isRegularFile == true || values.isDirectory == true else { throw MachineError.invalid("VM archives require regular files and directories") }
            guard result.count < 65536 else { throw MachineError.invalid("VM archive has too many files") }
            guard values.isRegularFile == true, relative != "manifest.json" else { continue }
            let input = try FileHandle(forReadingFrom: file)
            defer { try? input.close() }
            var hash = SHA256()
            while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
            result[relative] = hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return result
    }

    public func importArchive(_ source: URL, name: String? = nil) throws -> MachineConfiguration {
        if try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true { return try importDirectory(source, name: name) }
        let fm = FileManager.default
        let archive = try Archive(url: source, accessMode: .read)
        var paths = Set<String>()
        var total: UInt64 = 0
        let freeSpace = try fm.attributesOfFileSystem(forPath: root.path)[.systemFreeSize] as? NSNumber
        // Keep room for host operation and for a guest's first writes after import.
        let available = freeSpace?.uint64Value ?? 0
        let reserve = MachineArchiveStorage.reserve
        let limit = min(UInt64(128 * 1024 * 1024 * 1024), available > reserve ? available - reserve : 0)
        for entry in archive {
            let components = entry.path.split(separator: "/", omittingEmptySubsequences: true)
            guard components.first == "Machine", !entry.path.hasPrefix("/"), !entry.path.contains("\\"),
                !components.contains(".."), !components.contains("."), entry.type != .symlink,
                entry.path == components.joined(separator: "/") + (entry.type == .directory ? "/" : ""),
                paths.insert(components.joined(separator: "/")).inserted
            else { throw MachineError.invalid("Unsafe or duplicate archive entry") }
            let (sum, overflow) = total.addingReportingOverflow(entry.uncompressedSize)
            guard !overflow, sum <= limit else { throw MachineError.invalid("Archive exceeds available storage") }
            total = sum
        }
        let stage = root.appendingPathComponent(".import-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: stage) }
        for entry in archive { _ = try archive.extract(entry, to: stage.appendingPathComponent(entry.path), skipCRC32: false) }
        let machine = stage.appendingPathComponent("Machine")
        return try acceptImportedMachine(machine, name: name)
    }
    /// A checksummed folder preserves sparse files and APFS clones. It is useful
    /// when ZIP staging would exhaust local storage, and can be copied to a drive.
    public func exportDirectory(_ id: UUID, to destination: URL) throws {
        let lock = try MachineLock(bundle: bundle(id))
        try withExtendedLifetime(lock) {
            let fm = FileManager.default
            guard !fm.fileExists(atPath: destination.path) else { throw MachineError.invalid("Export destination already exists") }
            try checkDirectorySpace(from: bundle(id).appendingPathComponent("state"), to: destination.deletingLastPathComponent())
            let stage = destination.deletingLastPathComponent().appendingPathComponent(".export-" + UUID().uuidString)
            try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? fm.removeItem(at: stage) }
            let machine = stage.appendingPathComponent("Machine")
            try fm.createDirectory(at: machine, withIntermediateDirectories: false)
            try fm.copyItem(at: bundle(id).appendingPathComponent("state"), to: machine.appendingPathComponent("state"))
            let config = try configuration(id)
            for (mounted, filename) in [(config.installationMedia, config.operatingSystem == .macos ? "restore.ipsw" : "install.iso"), (config.seedMedia, "seed.iso")]
            where !mounted {
                let media = machine.appendingPathComponent("state/\(filename)")
                if fm.fileExists(atPath: media.path) { try fm.removeItem(at: media) }
            }
            try save(config, at: machine)
            try writeManifest(at: machine)
            try fm.moveItem(at: stage, to: destination)
        }
    }
    private func importDirectory(_ source: URL, name: String?) throws -> MachineConfiguration {
        let fm = FileManager.default
        let free = (try fm.attributesOfFileSystem(forPath: root.path)[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
        guard free > MachineArchiveStorage.reserve else { throw MachineError.invalid("Import needs at least 2 GiB of free space") }
        // Hashes rejects every symlink before copying. Validate the root too.
        guard try source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw MachineError.invalid("Archive cannot be a symbolic link") }
        let machine = source.appendingPathComponent("Machine")
        _ = try hashes(at: source)
        try checkDirectorySpace(from: machine, to: root)
        let stage = root.appendingPathComponent(".import-" + UUID().uuidString)
        defer { try? fm.removeItem(at: stage) }
        try fm.copyItem(at: machine, to: stage)
        return try acceptImportedMachine(stage, name: name)
    }
    private func checkDirectorySpace(from source: URL, to destination: URL) throws {
        let keys: Set<URLResourceKey> = [.volumeIdentifierKey, .volumeSupportsFileCloningKey]
        let origin = try source.resourceValues(forKeys: keys)
        let target = try destination.resourceValues(forKeys: keys)
        let originID = origin.volumeIdentifier as? AnyHashable
        let targetID = target.volumeIdentifier as? AnyHashable
        let canClone = originID != nil && originID == targetID && target.volumeSupportsFileCloning == true
        guard let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]) else {
            throw MachineError.invalid("Cannot inspect directory storage")
        }
        var payload: UInt64 = 0
        var count = 0
        for case let file as URL in enumerator {
            count += 1
            guard count <= 65536 else { throw MachineError.invalid("Machine has too many entries") }
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw MachineError.invalid("Machine state cannot contain symbolic links") }
            if values.isRegularFile == true {
                let (sum, overflow) = payload.addingReportingOverflow(UInt64(max(0, values.fileSize ?? 0)))
                guard !overflow else { throw MachineError.invalid("Machine is too large to copy") }
                payload = sum
            }
        }
        let required = try MachineArchiveStorage.requiredDirectorySpace(payloadBytes: payload, canClone: canClone)
        let free = (try FileManager.default.attributesOfFileSystem(forPath: destination.path)[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
        guard free >= required else { throw MachineError.invalid("Directory copy needs more free space on the destination volume") }
    }
    private func acceptImportedMachine(_ machine: URL, name: String?) throws -> MachineConfiguration {
        let fm = FileManager.default
        for file in ["manifest.json", "machine.json"] {
            let size = try machine.appendingPathComponent(file).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0 && size <= 2 * 1024 * 1024 else { throw MachineError.invalid("Invalid archive metadata size") }
        }
        let manifest = try JSONDecoder().decode(MachineManifest.self, from: Data(contentsOf: machine.appendingPathComponent("manifest.json")))
        guard manifest.schemaVersion == 1, manifest.files == (try hashes(at: machine)) else { throw MachineError.invalid("Archive integrity check failed") }
        var config = try JSONDecoder().decode(MachineConfiguration.self, from: Data(contentsOf: machine.appendingPathComponent("machine.json")))
        try config.validate()
        let macOSFiles = MacOSGuest.bootFiles + [MacOSGuest.installedMarker, "restore.ipsw"]
        let expected = Set(
            config.operatingSystem == .macos
                ? ["machine.json"] + macOSFiles.map { "state/" + $0 }
                : [
                    "machine.json", "state/disk.qcow2", "state/uefi-code.fd", "state/uefi-vars.qcow2", "state/install.iso", "state/seed.iso", "state/console.log",
                    "state/omarchy-console.log",
                ] + OmarchyGuest.bootFiles.map { "state/" + $0 })
        let required = config.operatingSystem == .macos ? MacOSGuest.bootFiles.map { "state/" + $0 } : ["state/disk.qcow2", "state/uefi-code.fd", "state/uefi-vars.qcow2"]
        guard manifest.files.keys.allSatisfy({ expected.contains($0) || (config.operatingSystem != .macos && $0.hasPrefix("state/tpm/")) }),
            required.allSatisfy({ manifest.files[$0] != nil }),
            !config.installationMedia || manifest.files[config.operatingSystem == .macos ? "state/restore.ipsw" : "state/install.iso"] != nil,
            !config.seedMedia || manifest.files["state/seed.iso"] != nil
        else { throw MachineError.invalid("Archive contains missing or unsupported machine state") }
        if config.operatingSystem == .macos {
            try MacOSGuest.validateState(at: machine.appendingPathComponent("state"), installed: !config.installationMedia)
            let size = try machine.appendingPathComponent("state/disk.raw").resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard size == config.diskGiB * 1024 * 1024 * 1024 else { throw MachineError.invalid("macOS disk size does not match its configuration") }
        }
        if config.operatingSystem == .omarchy {
            guard config.omarchyBoot != nil, OmarchyGuest.bootFiles.allSatisfy({ manifest.files["state/" + $0] != nil }) else {
                throw MachineError.invalid("Archive is missing paired Omarchy boot artifacts")
            }
        } else if OmarchyGuest.bootFiles.contains(where: { manifest.files["state/" + $0] != nil }) {
            throw MachineError.invalid("Unexpected Omarchy boot artifacts")
        }
        for disk in config.operatingSystem == .macos ? [] : ["disk.qcow2", "uefi-vars.qcow2"] {
            let info = try runtime.tool("qemu-img", ["info", "--output=json", machine.appendingPathComponent("state/\(disk)").path])
            let object = try JSONSerialization.jsonObject(with: Data(info.utf8)) as? [String: Any]
            guard object?["format"] as? String == "qcow2", object?["backing-filename"] == nil,
                ((object?["format-specific"] as? [String: Any])?["data"] as? [String: Any])?["data-file"] == nil
            else {
                throw MachineError.invalid("Imported disks must be self-contained QCOW2 images")
            }
        }
        config.id = UUID()
        config.macAddress = MachineConfiguration.newMAC()
        config.sshPort = nil
        if let name { config.name = name }
        try save(config, at: machine)
        try fm.removeItem(at: machine.appendingPathComponent("manifest.json"))
        try fm.moveItem(at: machine, to: bundle(config.id))
        return config

    }

}
