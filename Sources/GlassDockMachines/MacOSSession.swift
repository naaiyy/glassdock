import Combine
import Foundation
import Virtualization

#if arch(arm64)
/// The viewer process owns the native VM so VZVirtualMachineView can embed it.
/// The lifetime lock and local control endpoint remain active when its view closes.
@MainActor public final class MacOSSession: NSObject, ObservableObject, @preconcurrency VZVirtualMachineDelegate {
    @Published public private(set) var status = "prelaunch"
    @Published public private(set) var installationProgress = 0.0
    @Published public private(set) var failure: String?
    @Published public private(set) var machine: VZVirtualMachine?
    public var onShow: (() -> Void)?
    public var onStopped: (() -> Void)?
    private let store: MachineStore
    private var config: MachineConfiguration
    private var lock: MachineLock?
    private var control: NativeMachineControl?
    private var installer: VZMacOSInstaller?
    private var timer: Timer?
    private var finished = false
    private var started = false

    public init(store: MachineStore, id: UUID) throws {
        self.store = store
        config = try store.configuration(id)
        guard config.operatingSystem == .macos else { throw MachineError.invalid("Expected a macOS machine") }
        lock = try MachineLock(bundle: store.bundle(id))
        super.init()
    }

    public func start() async throws {
        guard !started else { throw MachineError.invalid("Native session has already started") }
        started = true
        do {
            let state = store.bundle(config.id).appendingPathComponent("state")
            let vm = VZVirtualMachine(configuration: try MacOSGuest.configuration(config, bundle: store.bundle(config.id)))
            vm.delegate = self
            machine = vm
            try Data(UUID().uuidString.utf8).write(to: store.bundle(config.id).appendingPathComponent("run-id"), options: .atomic)
            control = try NativeMachineControl(id: config.id) { [weak self] request, reply in
                Task { @MainActor in
                    guard let self else {
                        reply(Data("{}".utf8))
                        return
                    }
                    await self.handle(request, reply: reply)
                }
            }
            control?.serve()
            if !FileManager.default.fileExists(atPath: state.appendingPathComponent(MacOSGuest.installedMarker).path) {
                status = "installing"
                let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: state.appendingPathComponent("restore.ipsw"))
                self.installer = installer
                timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let installer = self.installer else { return }
                        self.installationProgress = installer.progress.fractionCompleted
                    }
                }
                try await installer.install()
                timer?.invalidate()
                timer = nil
                try Data("installed\n".utf8).write(to: state.appendingPathComponent(MacOSGuest.installedMarker), options: .atomic)
                config.installationMedia = false
                try store.save(config, at: store.bundle(config.id))
                self.installer = nil
                status = "prelaunch"
                if vm.state != .stopped, vm.canStop { try await vm.stop() }
                try? FileManager.default.removeItem(at: state.appendingPathComponent("restore.ipsw"))
            }
            try await vm.start()
            status = "running"
            log("macOS started in the Machines viewer")
        } catch {
            failure = error.localizedDescription
            log(error.localizedDescription)
            if let vm = machine, vm.canStop { try? await vm.stop() }
            finish()
            throw error
        }
    }

    private func handle(_ data: Data, reply: @escaping @Sendable (Data) -> Void) async {
        var response: [String: Any] = [:]
        do {
            guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any], let command = request["execute"] as? String else {
                throw MachineError.invalid("Invalid native control request")
            }
            response["id"] = request["id"]
            guard let vm = machine else { throw MachineError.command("Native VM is not configured") }
            var result: [String: Any] = [:]
            switch command {
            case "qmp_capabilities": break
            case "query-status": result["status"] = status
            case "glassdock-show": onShow?()
            case "glassdock-share":
                guard ["running", "paused"].contains(status) else { throw MachineError.busy }
                let args = request["arguments"] as? [String: Any] ?? [:]
                guard let device = vm.directorySharingDevices.first as? VZVirtioFileSystemDevice else { throw MachineError.command("No directory sharing device") }
                if let path = args["path"] as? String {
                    let url = URL(fileURLWithPath: path)
                    guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw MachineError.invalid("Share a directory") }
                    device.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: url, readOnly: args["read-only"] as? Bool ?? true))
                } else {
                    device.share = nil
                }
            case "stop", "cont", "system_powerdown", "quit":
                try Self.validatePowerCommand(command, status: status)
                switch command {
                case "stop":
                    try await vm.pause()
                    status = "paused"
                case "cont":
                    try await vm.resume()
                    status = "running"
                case "system_powerdown":
                    if vm.state == .paused {
                        try await vm.resume()
                        status = "running"
                    }
                    try vm.requestStop()
                default:
                    try await vm.stop()
                    finish()
                }
            default: throw MachineError.invalid("Unsupported native macOS command: \(command)")
            }
            response["return"] = result
        } catch {
            response["error"] = ["class": "GenericError", "desc": error.localizedDescription]
        }
        reply((try? JSONSerialization.data(withJSONObject: response)) ?? Data("{}".utf8))
    }

    public static func validatePowerCommand(_ command: String, status: String) throws {
        guard ["running", "paused"].contains(status) else { throw MachineError.invalid("Wait for macOS installation/startup to finish before changing power state") }
        guard ["stop", "cont", "system_powerdown", "quit"].contains(command), command != "stop" || status == "running", command != "cont" || status == "paused" else {
            throw MachineError.invalid("This power command is unavailable in the current state")
        }
    }

    public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        if ["running", "paused"].contains(status) { finish() }
    }
    public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        failure = error.localizedDescription
        log(error.localizedDescription)
        finish()
    }
    public func revokeShare() {
        if ["running", "paused"].contains(status), let device = machine?.directorySharingDevices.first as? VZVirtioFileSystemDevice { device.share = nil }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        timer = nil
        installer = nil
        machine = nil
        status = "stopped"
        control?.stop()
        control = nil
        try? FileManager.default.removeItem(at: store.bundle(config.id).appendingPathComponent("run-id"))
        lock = nil
        onStopped?()
    }
    private func log(_ message: String) {
        let url = store.bundle(config.id).appendingPathComponent("supervisor.log")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        if let file = try? FileHandle(forWritingTo: url) {
            defer { try? file.close() }
            _ = try? file.seekToEnd()
            try? file.write(contentsOf: Data((message + "\n").utf8))
        }
    }
}
#endif
