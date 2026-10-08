import CryptoKit
import Foundation

enum MachineMemoryStorage {
    static func requiredSpace(memoryMiB: Int) -> UInt64 {
        UInt64(memoryMiB) * 1024 * 1024 + MachineArchiveStorage.reserve
    }
}

/// RAM snapshots are local checkpoints, tied to this machine's exact hardware
/// configuration and runtime. They are never automatically resumed by a clone.
public struct MachineMemoryCheckpoint: Codable, Sendable {
    public let name: String
    public let configuration: MachineConfiguration
    public let runtimeVersion: String
    public let runtimeHash: String
    public let createdAt: Date
}

extension MachineStore {
    public func memorySnapshots(_ id: UUID) throws -> [String] {
        let folder = bundle(id).appendingPathComponent("memory-snapshots")
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }
    public func validateMemorySnapshot(_ id: UUID, name: String) throws {
        guard try configuration(id).operatingSystem != .macos else { throw MachineError.invalid("Native macOS RAM checkpoints are unavailable; use stopped snapshots") }
        try validateMemoryName(name)
        let checkpoint = try JSONDecoder().decode(MachineMemoryCheckpoint.self, from: Data(contentsOf: memoryFile(id, name)))
        guard checkpoint.configuration == (try configuration(id)), checkpoint.runtimeVersion == (try runtime.tool("qemu-aarch64-softmmu", ["--version"])),
            checkpoint.runtimeHash == (try memoryRuntimeHash())
        else {
            throw MachineError.invalid("This memory checkpoint needs its original machine settings and QEMU runtime. Restore a stopped snapshot or cold boot instead.")
        }
    }
    public func saveMemorySnapshot(_ id: UUID, name: String) throws {
        guard try configuration(id).operatingSystem != .macos else { throw MachineError.invalid("Native macOS RAM checkpoints are unavailable; use stopped snapshots") }
        try validateMemoryName(name)
        let lock = try MachineLock(bundle: bundle(id), name: "session.lock")
        try withExtendedLifetime(lock) {
            let config = try configuration(id)
            guard config.graphics == .basic else { throw MachineError.invalid("Memory checkpoints require basic graphics; accelerated GPU state cannot be saved by this runtime.") }
            guard !FileManager.default.fileExists(atPath: memoryFile(id, name).path) else { throw MachineError.invalid("Memory checkpoint already exists") }
            let available = (try FileManager.default.attributesOfFileSystem(forPath: bundle(id).path)[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
            guard available >= MachineMemoryStorage.requiredSpace(memoryMiB: config.memoryMiB) else {
                throw MachineError.invalid("A memory checkpoint needs space for the guest RAM plus 2 GiB of headroom")
            }
            let version = try runtime.tool("qemu-aarch64-softmmu", ["--version"])
            let qmp = try QMPClient(socket: QEMUArguments.socketDirectory(id: id).appendingPathComponent("qmp.sock"), timeoutSeconds: 120)
            let previous = (try qmp.command("query-status")["return"] as? [String: Any])?["status"] as? String
            guard ["running", "paused"].contains(previous ?? "") else { throw MachineError.invalid("Start the machine before saving memory") }
            try qmp.command("stop")
            defer { if previous == "running" { _ = try? qmp.command("cont") } }
            try memoryCommand(qmp, "savevm \(name)")
            let checkpoint = MachineMemoryCheckpoint(name: name, configuration: config, runtimeVersion: version, runtimeHash: try memoryRuntimeHash(), createdAt: Date())
            let folder = memoryFile(id, name).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            do {
                try JSONEncoder().encode(checkpoint).write(to: memoryFile(id, name), options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: memoryFile(id, name).path)
            } catch {
                try? memoryCommand(qmp, "delvm \(name)")
                throw error
            }
        }
    }
    public func restoreMemorySnapshot(_ id: UUID, name: String) throws {
        let lock = try MachineLock(bundle: bundle(id), name: "session.lock")
        try withExtendedLifetime(lock) {
            try validateMemorySnapshot(id, name: name)
            let qmp = try QMPClient(socket: QEMUArguments.socketDirectory(id: id).appendingPathComponent("qmp.sock"), timeoutSeconds: 120)
            let previous = (try qmp.command("query-status")["return"] as? [String: Any])?["status"] as? String
            try qmp.command("stop")
            defer { if previous == "running" { _ = try? qmp.command("cont") } }
            try memoryCommand(qmp, "loadvm \(name)")
        }
    }
    public func deleteMemorySnapshot(_ id: UUID, name: String) throws {
        guard try configuration(id).operatingSystem != .macos else { throw MachineError.invalid("Native macOS RAM checkpoints are unavailable; use stopped snapshots") }
        try validateMemoryName(name)
        let lock = try MachineLock(bundle: bundle(id), name: "session.lock")
        try withExtendedLifetime(lock) {
            if ["running", "paused"].contains(status(id)) {
                try memoryCommand(control(id), "delvm \(name)")
            } else {
                let offlineLock = try MachineLock(bundle: bundle(id))
                try withExtendedLifetime(offlineLock) {
                    for file in ["disk.qcow2", "uefi-vars.qcow2"] {
                        try runtime.tool("qemu-img", ["snapshot", "-d", name, bundle(id).appendingPathComponent("state/\(file)").path])
                    }
                }
            }
            try FileManager.default.removeItem(at: memoryFile(id, name))
        }
    }
    private func memoryRuntimeHash() throws -> String {
        let handle = try FileHandle(forReadingFrom: runtime.library("qemu-aarch64-softmmu"))
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private func memoryCommand(_ qmp: QMPClient, _ command: String) throws {
        let response = try qmp.command("human-monitor-command", arguments: ["command-line": command])
        let output = response["return"] as? String ?? ""
        guard output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MachineError.command(output) }
    }
    private func memoryFile(_ id: UUID, _ name: String) -> URL { bundle(id).appendingPathComponent("memory-snapshots/\(name).json") }
    private func validateMemoryName(_ name: String) throws {
        guard name.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$", options: .regularExpression) != nil else {
            throw MachineError.invalid("Checkpoint name must be 1–64 letters, digits, underscores, or hyphens")
        }
    }
}
