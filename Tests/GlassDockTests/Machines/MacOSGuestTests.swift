import Foundation
import Testing
import Virtualization

@testable import GlassDockMachines

@Suite("Native Apple Silicon macOS machines")
struct MacOSGuestTests {
    @Test func nativeProfileIsDistinctAndExistingConfigurationsRemainCompatible() throws {
        let config = MachineConfiguration(name: "macOS", operatingSystem: .macos)
        try config.validate()
        #expect(!config.operatingSystem.isLinux)
        #expect(config.audioEnabled == true)
        #expect(MachineOS.macos.displayName == "macOS")
        #expect(try JSONDecoder().decode(MachineConfiguration.self, from: JSONEncoder().encode(config)) == config)
        for os in [MachineOS.linux, .windows, .omarchy] {
            let old = MachineConfiguration(name: "Existing", operatingSystem: os)
            try JSONDecoder().decode(MachineConfiguration.self, from: JSONEncoder().encode(old)).validate()
        }
    }

    @Test func rejectsUnsupportedQEMUDevicesAndInsufficientResources() throws {
        let config = MachineConfiguration(name: "macOS", operatingSystem: .macos)
        for variant in 0..<7 {
            var invalid = config
            switch variant {
            case 0: invalid.sshPort = 22222
            case 1: invalid.usbEnabled = true
            case 2: invalid.seedMedia = true
            case 3: invalid.graphics = .virgl
            case 4: invalid.cpuCount = 1
            case 5: invalid.memoryMiB = 2048
            default: invalid.diskGiB = 32
            }
            #expect(throws: MachineError.self) { try invalid.validate() }
        }
        let url = URL(fileURLWithPath: "/unused")
        #expect(throws: MachineError.self) { try QEMUArguments.build(config, bundle: url, runtime: MachineRuntime(app: url, launcher: url, supervisor: url)) }
    }

    @Test func creationRequiresIPSWAndRejectsConflictingMediaBeforeMutation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MachineStore(root: root, runtime: MachineRuntime(app: root, launcher: root, supervisor: root))
        let config = MachineConfiguration(name: "macOS", operatingSystem: .macos)
        #expect(throws: MachineError.self) { try store.create(config) }
        #expect(throws: MachineError.self) { try store.create(config, disk: root, macOSRestoreImage: root) }
        #expect(throws: MachineError.self) { try store.create(MachineConfiguration(name: "Linux", operatingSystem: .linux), macOSRestoreImage: root) }
        #expect(try store.list().isEmpty)
    }

    @Test func rejectsIncompleteSymlinkedAndMalformedPlatformState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for file in MacOSGuest.bootFiles + [MacOSGuest.installedMarker] { try Data([42]).write(to: root.appendingPathComponent(file)) }
        #expect(throws: MachineError.self) { try MacOSGuest.validateState(at: root, installed: true) }
        let identifier = root.appendingPathComponent("machine-identifier.bin")
        try FileManager.default.removeItem(at: identifier)
        try FileManager.default.createSymbolicLink(at: identifier, withDestinationURL: root.appendingPathComponent("hardware-model.bin"))
        #expect(throws: MachineError.self) { try MacOSGuest.validateState(at: root, installed: true) }
        #expect(throws: (any Error).self) { try MacOSGuest.validateState(at: root, installed: false) }
    }

    #if arch(arm64)
    @Test func clonesRegenerateAppleIdentifierAndSnapshotsPreserveIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MachineStore(root: root, runtime: MachineRuntime(app: root, launcher: root, supervisor: root))
        let config = MachineConfiguration(name: "macOS", operatingSystem: .macos)
        let state = store.bundle(config.id).appendingPathComponent("state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try Data("disk".utf8).write(to: state.appendingPathComponent("disk.raw"))
        try MacOSGuest.newIdentity(at: state)
        try store.save(config, at: store.bundle(config.id))
        let original = try Data(contentsOf: state.appendingPathComponent("machine-identifier.bin"))
        #expect(VZMacMachineIdentifier(dataRepresentation: original) != nil)
        try store.snapshot(config.id, name: "original")
        let clone = try store.clone(config.id, name: "copy")
        let copy = try Data(contentsOf: store.bundle(clone.id).appendingPathComponent("state/machine-identifier.bin"))
        #expect(copy != original)
        #expect(VZMacMachineIdentifier(dataRepresentation: copy) != nil)
        try MacOSGuest.newIdentity(at: state)
        try store.restore(config.id, name: "original")
        #expect(try Data(contentsOf: state.appendingPathComponent("machine-identifier.bin")) == original)
        #expect(throws: MachineError.self) { try store.saveMemorySnapshot(config.id, name: "unsupported") }
        #expect(throws: MachineError.self) { try store.start(config.id, memorySnapshot: "unsupported") }
        #expect(throws: MachineError.self) { try store.setMediaMounted(config.id, installation: true) }
    }
    @MainActor @Test func nativePowerCommandsRespectInstallationAndSessionState() throws {
        for status in ["prelaunch", "installing", "stopped", "unknown"] {
            for command in ["stop", "cont", "system_powerdown", "quit"] {
                #expect(throws: MachineError.self) { try MacOSSession.validatePowerCommand(command, status: status) }
            }
        }
        try MacOSSession.validatePowerCommand("stop", status: "running")
        try MacOSSession.validatePowerCommand("cont", status: "paused")
        for status in ["running", "paused"] {
            try MacOSSession.validatePowerCommand("system_powerdown", status: status)
            try MacOSSession.validatePowerCommand("quit", status: status)
            #expect(throws: MachineError.self) { try MacOSSession.validatePowerCommand("reset", status: status) }
        }
        #expect(throws: MachineError.self) { try MacOSSession.validatePowerCommand("stop", status: "paused") }
        #expect(throws: MachineError.self) { try MacOSSession.validatePowerCommand("cont", status: "running") }
    }

    @MainActor @Test func failedNativeStartupReleasesItsLifetimeLock() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MachineStore(root: root, runtime: MachineRuntime(app: root, launcher: root, supervisor: root))
        let config = MachineConfiguration(name: "Incomplete native guest", operatingSystem: .macos)
        let bundle = store.bundle(config.id)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try store.save(config, at: bundle)
        let session = try MacOSSession(store: store, id: config.id)
        var stopped = 0
        session.onStopped = { stopped += 1 }
        #expect(throws: MachineError.self) { try MachineLock(bundle: bundle) }
        do {
            try await session.start()
            Issue.record("Missing platform files must fail startup")
        } catch {}
        #expect(session.status == "stopped")
        #expect(session.machine == nil)
        #expect(session.failure != nil)
        #expect(stopped == 1)
        let lock = try MachineLock(bundle: bundle)
        withExtendedLifetime(lock) {}
        do {
            try await session.start()
            Issue.record("A finished session cannot be reused")
        } catch {}
        #expect(stopped == 1)
    }

    #endif

    @Test func nativeControlNegotiatesAndSurfacesUnsupportedCommands() throws {
        let id = UUID()
        let server = try NativeMachineControl(id: id) { request, reply in
            var response: [String: Any] = [:]
            do {
                let object = try #require(JSONSerialization.jsonObject(with: request) as? [String: Any])
                response["id"] = object["id"]
                switch object["execute"] as? String {
                case "qmp_capabilities": response["return"] = [String: String]()
                case "query-status": response["return"] = ["status": "installing"]
                default: response["error"] = ["class": "GenericError", "desc": "Unsupported native command"]
                }
                reply(try JSONSerialization.data(withJSONObject: response))
            } catch { reply(Data("{}".utf8)) }
        }
        server.serve()
        defer { server.stop() }
        let client = try QMPClient(socket: QEMUArguments.socketDirectory(id: id).appendingPathComponent("qmp.sock"))
        #expect((try client.command("query-status")["return"] as? [String: String])?["status"] == "installing")
        #expect(throws: MachineError.self) { try client.command("human-monitor-command") }
    }

    @Test func nativeOnlyRuntimeSelectsBundledHelpersWithoutQEMU() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in ["glassdock-vm-runner", "glassdock-macos"] {
            let helper = bin.appendingPathComponent(name)
            try Data("#!/bin/sh\n".utf8).write(to: helper)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        }
        #expect(MachineRuntime.helperDirectory(app: root, fallback: root, overridden: false).path == bin.path)
        let runtime = MachineRuntime(app: root, launcher: bin.appendingPathComponent("glassdock-qemu"), supervisor: bin.appendingPathComponent("glassdock-vm-runner"))
        #expect(runtime.macOSLauncher == bin.appendingPathComponent("glassdock-macos"))
        #expect(MachineRuntime.helperDirectory(app: root, fallback: root, overridden: true) == root)
    }

    @Test func installationHasNoPrematurePowerOrArchiveActions() {
        let state = MachineDisplayState(status: "installing")
        #expect(state == .installing)
        #expect(state.title == "Installing macOS")
        #expect(!state.canPause)
        #expect(!state.canStart)
        #expect(!state.canShutDown)
    }
}
