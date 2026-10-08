import Foundation

public struct MachineStore: Sendable {
    public let root: URL
    public let runtime: MachineRuntime
    // FileManager operations are documented as thread-safe without a delegate.
    // This store never installs one; the injectable instance supports fault tests.
    nonisolated(unsafe) private let fm: FileManager

    public init(root: URL, runtime: MachineRuntime) throws {
        try self.init(root: root, runtime: runtime, fileManager: .default)
    }
    init(root: URL, runtime: MachineRuntime, fileManager: FileManager) throws {
        self.root = root
        self.runtime = runtime
        self.fm = fileManager
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/GlassDock/Machines")
    }
    public func bundle(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".glassvm") }
    public func configuration(_ id: UUID) throws -> MachineConfiguration {
        let value = try JSONDecoder().decode(MachineConfiguration.self, from: Data(contentsOf: bundle(id).appendingPathComponent("machine.json")))
        try value.validate()
        guard value.id == id else { throw MachineError.invalid("Machine identity does not match its bundle") }
        return value
    }
    public func list() throws -> [MachineConfiguration] {
        try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "glassvm" }
            .map { url in
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { throw MachineError.invalid("Invalid machine bundle") }
                return try configuration(id)
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public func resolve(_ value: String) throws -> UUID {
        if let id = UUID(uuidString: value) {
            _ = try configuration(id)
            return id
        }
        let matches = try list().filter { $0.name == value }
        guard matches.count == 1 else { throw MachineError.invalid(matches.isEmpty ? "Machine not found: \(value)" : "Ambiguous machine name; use its UUID") }
        return matches[0].id
    }
    public func save(_ configuration: MachineConfiguration, at location: URL) throws {
        try configuration.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration).write(to: location.appendingPathComponent("machine.json"), options: .atomic)
    }

    public func create(_ input: MachineConfiguration, disk: URL? = nil, media: URL? = nil, seed: URL? = nil) throws -> MachineConfiguration {
        var config = input
        config.installationMedia = media != nil
        config.seedMedia = seed != nil
        try config.validate()
        let registryLock = try MachineLock(bundle: root)
        return try withExtendedLifetime(registryLock) {
            guard !fm.fileExists(atPath: bundle(config.id).path) else { throw MachineError.invalid("Machine already exists") }
            let stage = root.appendingPathComponent(".create-" + UUID().uuidString)
            try fm.createDirectory(at: stage.appendingPathComponent("state"), withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: stage) }
            let state = stage.appendingPathComponent("state")
            let target = state.appendingPathComponent("disk.qcow2")
            if let disk {
                try runtime.tool("qemu-img", ["convert", "-O", "qcow2", disk.path, target.path])
                // resize never shrinks: qemu-img rejects a smaller requested size without --shrink.
                try runtime.tool("qemu-img", ["resize", target.path, "\(config.diskGiB)G"])
            } else {
                try runtime.tool("qemu-img", ["create", "-f", "qcow2", target.path, "\(config.diskGiB)G"])
            }
            let firmware = runtime.firmwareTemplates(for: config.operatingSystem)
            try fm.copyItem(at: firmware.code, to: state.appendingPathComponent("uefi-code.fd"))
            try runtime.tool(
                "qemu-img", ["convert", "-O", "qcow2", firmware.variables.path, state.appendingPathComponent("uefi-vars.qcow2").path])
            try fm.createDirectory(at: state.appendingPathComponent("tpm"), withIntermediateDirectories: false)
            if let media { try fm.copyItem(at: media, to: state.appendingPathComponent("install.iso")) }
            if let seed { try fm.copyItem(at: seed, to: state.appendingPathComponent("seed.iso")) }
            try save(config, at: stage)
            try fm.moveItem(at: stage, to: bundle(config.id))
            return config
        }
    }

    public func configure(_ id: UUID, cpuCount: Int? = nil, memoryMiB: Int? = nil, graphics: MachineGraphics? = nil, audioEnabled: Bool? = nil, usbEnabled: Bool? = nil) throws {
        let lock = try MachineLock(bundle: bundle(id))
        try withExtendedLifetime(lock) {
            var config = try configuration(id)
            if let cpuCount { config.cpuCount = cpuCount }
            if let memoryMiB { config.memoryMiB = memoryMiB }
            if let graphics { config.graphics = graphics }
            if let audioEnabled { config.audioEnabled = audioEnabled }
            if let usbEnabled { config.usbEnabled = usbEnabled }
            try save(config, at: bundle(id))
        }
    }
    public func setMediaMounted(_ id: UUID, installation: Bool? = nil, seed: Bool? = nil) throws {
        let lock = try MachineLock(bundle: bundle(id))
        try withExtendedLifetime(lock) {
            var config = try configuration(id)
            if let installation {
                guard !installation || fm.fileExists(atPath: bundle(id).appendingPathComponent("state/install.iso").path) else {
                    throw MachineError.invalid("This machine has no installation media")
                }
                config.installationMedia = installation
            }
            if let seed {
                guard !seed || fm.fileExists(atPath: bundle(id).appendingPathComponent("state/seed.iso").path) else {
                    throw MachineError.invalid("This machine has no guest tools or seed media")
                }
                config.seedMedia = seed
            }
            try save(config, at: bundle(id))
        }
    }
    public func status(_ id: UUID) -> String {
        do {
            let response = try control(id).command("query-status")
            return (response["return"] as? [String: Any])?["status"] as? String ?? "unknown"
        } catch {
            if let lock = try? MachineLock(bundle: bundle(id)) { return withExtendedLifetime(lock) { "stopped" } }
            return fm.fileExists(atPath: bundle(id).appendingPathComponent("run-id").path) ? "starting or unavailable" : "busy"
        }
    }
    public func control(_ id: UUID) throws -> QMPClient { try QMPClient(socket: QEMUArguments.socketDirectory(id: id).appendingPathComponent("qmp.sock")) }

    public func shutdown(_ id: UUID) throws {
        let qmp = try control(id)
        let state = (try qmp.command("query-status")["return"] as? [String: Any])?["status"] as? String
        // A paused CPU cannot process the ACPI shutdown request.
        if state == "paused" { try qmp.command("cont") }
        // Windows may configure its ACPI power button to sleep. Guest tools can
        // request an actual OS shutdown; ACPI remains the tools-free fallback.
        if let agent = try? GuestAgent(id: id) {
            do {
                try agent.shutdown()
                return
            } catch {}
        }
        try qmp.command("system_powerdown")
    }
    public func powerOff(_ id: UUID) throws {
        try control(id).command("quit")
        try waitUntilStopped(id)
    }
    public func waitUntilStopped(_ id: UUID, timeout: TimeInterval = 20) throws {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let lock = try? MachineLock(bundle: bundle(id)) { return withExtendedLifetime(lock) {} }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        throw MachineError.command("Machine has not stopped; inspect its supervisor log")
    }
    public func start(_ id: UUID, memorySnapshot: String? = nil) throws {
        _ = try configuration(id)
        try checkStopped(id)
        // Release before the supervisor obtains the lifetime lock.
        if let memorySnapshot { try validateMemorySnapshot(id, name: memorySnapshot) }
        try launchSupervisor(id, memorySnapshot: memorySnapshot)
    }
    private func checkStopped(_ id: UUID) throws {
        let lock = try MachineLock(bundle: bundle(id))
        withExtendedLifetime(lock) {}
    }
    private func launchSupervisor(_ id: UUID, memorySnapshot: String?) throws {
        let logURL = bundle(id).appendingPathComponent("supervisor.log")
        if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil) }
        let log = try FileHandle(forWritingTo: logURL)
        try log.seekToEnd()
        defer { try? log.close() }
        let process = Process()
        process.executableURL = runtime.supervisor
        process.arguments = [root.path, id.uuidString, runtime.app.path] + (memorySnapshot.map { [$0] } ?? [])
        process.standardOutput = log
        process.standardError = log
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let qmp = try? control(id), (try? qmp.command("query-status")) != nil {
                return
            }
            guard process.isRunning else {
                let text = String(decoding: (try? Data(contentsOf: logURL))?.suffix(8192) ?? Data(), as: UTF8.self)
                throw MachineError.command("Machine failed to start: \(text)")
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw MachineError.command("Machine startup timed out; inspect \(logURL.path)")
    }

    public func snapshot(_ id: UUID, name: String) throws {
        try validateSnapshotName(name)
        let lock = try MachineLock(bundle: bundle(id))
        try withExtendedLifetime(lock) {
            let target = bundle(id).appendingPathComponent("snapshots/\(name)")
            guard !fm.fileExists(atPath: target.path) else { throw MachineError.invalid("Snapshot already exists") }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let stage = bundle(id).appendingPathComponent(".snapshot-" + UUID().uuidString)
            try fm.createDirectory(at: stage, withIntermediateDirectories: false)
            defer { try? fm.removeItem(at: stage) }
            try copyState(from: bundle(id).appendingPathComponent("state"), to: stage.appendingPathComponent("state"))
            try fm.copyItem(at: bundle(id).appendingPathComponent("machine.json"), to: stage.appendingPathComponent("machine.json"))
            let memory = bundle(id).appendingPathComponent("memory-snapshots")
            if fm.fileExists(atPath: memory.path) { try copyState(from: memory, to: stage.appendingPathComponent("memory-snapshots")) }

            try fm.moveItem(at: stage, to: target)
        }
    }
    public func snapshots(_ id: UUID) throws -> [String] {
        let directory = bundle(id).appendingPathComponent("snapshots")
        guard fm.fileExists(atPath: directory.path) else { return [] }
        return try fm.contentsOfDirectory(atPath: directory.path).filter { !$0.hasPrefix(".") }.sorted()
    }
    public func restore(_ id: UUID, name: String) throws {
        try validateSnapshotName(name)
        let lock = try MachineLock(bundle: bundle(id))
        try withExtendedLifetime(lock) {
            let snapshot = bundle(id).appendingPathComponent("snapshots/\(name)")
            let config = try JSONDecoder().decode(MachineConfiguration.self, from: Data(contentsOf: snapshot.appendingPathComponent("machine.json")))
            try config.validate()
            guard config.id == id else { throw MachineError.invalid("Snapshot belongs to another machine") }
            let stage = bundle(id).appendingPathComponent(".restore-" + UUID().uuidString)
            try fm.createDirectory(at: stage, withIntermediateDirectories: false)
            defer { try? fm.removeItem(at: stage) }
            try copyState(from: snapshot.appendingPathComponent("state"), to: stage.appendingPathComponent("state"))
            let memory = bundle(id).appendingPathComponent("memory-snapshots")
            let snapshotMemory = snapshot.appendingPathComponent("memory-snapshots")
            if fm.fileExists(atPath: snapshotMemory.path) { try copyState(from: snapshotMemory, to: stage.appendingPathComponent("memory-snapshots")) }
            let current = bundle(id).appendingPathComponent("state")
            let backup = bundle(id).appendingPathComponent(".previous-" + UUID().uuidString)
            try fm.createDirectory(at: backup, withIntermediateDirectories: false)
            let originalConfiguration = try configuration(id)
            try fm.moveItem(at: current, to: backup.appendingPathComponent("state"))
            var memoryMoved = false
            var memoryInstalled = false
            do {
                if fm.fileExists(atPath: memory.path) {
                    try fm.moveItem(at: memory, to: backup.appendingPathComponent("memory-snapshots"))
                    memoryMoved = true
                }
                try fm.moveItem(at: stage.appendingPathComponent("state"), to: current)
                if fm.fileExists(atPath: stage.appendingPathComponent("memory-snapshots").path) {
                    try fm.moveItem(at: stage.appendingPathComponent("memory-snapshots"), to: memory)
                    memoryInstalled = true
                }
                try save(config, at: bundle(id))
            } catch {
                try? fm.removeItem(at: current)
                try fm.moveItem(at: backup.appendingPathComponent("state"), to: current)
                if memoryMoved || memoryInstalled {
                    try? fm.removeItem(at: memory)
                    if memoryMoved { try fm.moveItem(at: backup.appendingPathComponent("memory-snapshots"), to: memory) }
                }
                try save(originalConfiguration, at: bundle(id))
                try? fm.removeItem(at: backup)
                throw error
            }
            try fm.removeItem(at: backup)
        }
    }
    public func clone(_ id: UUID, name: String) throws -> MachineConfiguration {
        let lock = try MachineLock(bundle: bundle(id))
        return try withExtendedLifetime(lock) {
            var config = try configuration(id)
            config.id = UUID()
            config.name = name
            config.macAddress = MachineConfiguration.newMAC()
            config.sshPort = nil
            config.createdAt = Date()
            let stage = root.appendingPathComponent(".clone-" + UUID().uuidString)
            try fm.createDirectory(at: stage, withIntermediateDirectories: false)
            defer { try? fm.removeItem(at: stage) }
            try copyState(from: bundle(id).appendingPathComponent("state"), to: stage.appendingPathComponent("state"))
            // TPM persistent state is deliberately preserved so encrypted disks remain usable.
            // OS identity/licensing must be generalized inside Windows separately.
            try save(config, at: stage)
            try fm.moveItem(at: stage, to: bundle(config.id))
            return config
        }
    }
    public func export(_ id: UUID, to destination: URL, compact: Bool = false) throws {
        let lock = try MachineLock(bundle: bundle(id))
        try withExtendedLifetime(lock) {
            guard !fm.fileExists(atPath: destination.path) else { throw MachineError.invalid("Export destination already exists") }
            let stage = root.appendingPathComponent(".export-" + UUID().uuidString)
            let machine = stage.appendingPathComponent("Machine")
            try fm.createDirectory(at: machine, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: stage) }
            try copyState(from: bundle(id).appendingPathComponent("state"), to: machine.appendingPathComponent("state"))
            let config = try configuration(id)
            // Ejected installers remain available locally, but are not part of
            // the exported installed system or its storage requirements.
            for (mounted, filename) in [(config.installationMedia, "install.iso"), (config.seedMedia, "seed.iso")] where !mounted {
                let media = machine.appendingPathComponent("state/\(filename)")
                if fm.fileExists(atPath: media.path) { try fm.removeItem(at: media) }
            }
            guard let files = fm.enumerator(at: machine, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else {
                throw MachineError.command("Cannot inspect export storage requirements")
            }
            var payloadBytes: UInt64 = 0
            for case let file as URL in files {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if values.isRegularFile == true {
                    let (sum, overflow) = payloadBytes.addingReportingOverflow(UInt64(values.fileSize ?? 0))
                    guard !overflow else { throw MachineError.invalid("Machine is too large to export") }
                    payloadBytes = sum
                }
            }
            let available = (try fm.attributesOfFileSystem(forPath: destination.deletingLastPathComponent().path)[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
            guard available >= (try MachineArchiveStorage.requiredExportSpace(payloadBytes: payloadBytes, compact: compact)) else {
                throw MachineError.invalid("Not enough storage for export staging and a 2 GiB reserve. Eject unused media, choose an external volume, or free space.")
            }
            if compact {
                let disk = machine.appendingPathComponent("state/disk.qcow2")
                let compressed = machine.appendingPathComponent("state/.compressed.qcow2")
                try runtime.tool("qemu-img", ["convert", "-c", "-O", "qcow2", disk.path, compressed.path])
                // Conversion happens only in disposable staging; the original
                // disk and all snapshots retain their existing cluster format.
                try fm.removeItem(at: disk)
                try fm.moveItem(at: compressed, to: disk)
            }
            try save(config, at: machine)
            try writeManifest(at: machine)
            let partial = destination.deletingLastPathComponent().appendingPathComponent(".export-" + UUID().uuidString + ".zip")
            defer { try? fm.removeItem(at: partial) }
            guard fm.createFile(atPath: partial.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw MachineError.command("Cannot create export destination")
            }
            try MachineRuntime.execute(URL(fileURLWithPath: "/usr/bin/ditto"), ["-c", "-k", "--keepParent", machine.path, partial.path])
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: partial.path)
            try fm.moveItem(at: partial, to: destination)
        }
    }

    private func copyState(from source: URL, to target: URL) throws {
        // macOS copyItem uses clonefile where supported. All disks are self-contained;
        // there are no mutable backing-file dependencies between machines.
        try fm.copyItem(at: source, to: target)
    }
    private func validateSnapshotName(_ name: String) throws {
        guard name.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$", options: .regularExpression) != nil else {
            throw MachineError.invalid("Snapshot name must be 1–64 letters, digits, underscores, or hyphens")
        }
    }
}
