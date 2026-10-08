import Darwin
import Foundation
import GlassDockMachines

// The supervisor owns the lifetime lock and the TPM child. Closing the UI does
// not corrupt a running guest; QMP remains available to the app and CLI.
@main
struct MachineSupervisor {
    static func main() {
        do { try run() } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
    private static func run() throws {
        let args = CommandLine.arguments
        guard (4...5).contains(args.count), let id = UUID(uuidString: args[2]) else { throw MachineError.invalid("usage: glassdock-vm-runner root uuid runtime-app") }
        let bin = URL(fileURLWithPath: args[0]).deletingLastPathComponent()
        let runtime = MachineRuntime(app: URL(fileURLWithPath: args[3]), launcher: bin.appendingPathComponent("glassdock-qemu"), supervisor: URL(fileURLWithPath: args[0]))
        let store = try MachineStore(root: URL(fileURLWithPath: args[1]), runtime: runtime)
        let bundle = store.bundle(id)
        let lock = try MachineLock(bundle: bundle)
        try withExtendedLifetime(lock) {
            let runID = bundle.appendingPathComponent("run-id")
            try Data(UUID().uuidString.utf8).write(to: runID, options: .atomic)
            defer { try? FileManager.default.removeItem(at: runID) }
            let config = try store.configuration(id)
            var arguments = try QEMUArguments.build(config, bundle: bundle, runtime: runtime)
            if args.count == 5 {
                try store.validateMemorySnapshot(id, name: args[4])
                arguments += ["-loadvm", args[4], "-S"]
            }
            let sockets = QEMUArguments.socketDirectory(id: id)
            let fm = FileManager.default
            // /tmp parent is private to this uid. Never follow a pre-existing symlink.
            let parent = sockets.deletingLastPathComponent()
            if !fm.fileExists(atPath: parent.path) {
                try fm.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            let attributes = try fm.attributesOfItem(atPath: parent.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o077 == 0
            else {
                throw MachineError.invalid("Insecure VM socket directory")
            }
            if fm.fileExists(atPath: sockets.path) { try fm.removeItem(at: sockets) }
            try fm.createDirectory(at: sockets, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? fm.removeItem(at: sockets) }
            var tpm: Process?
            defer {
                if let tpm, tpm.isRunning {
                    tpm.terminate()
                    tpm.waitUntilExit()
                }
            }
            if config.operatingSystem == .windows {
                let process = Process()
                process.executableURL = runtime.launcher
                process.arguments = [
                    runtime.library("swtpm.0").path, "--tpm2", "--tpmstate", "dir=\(bundle.appendingPathComponent("state/tpm").path)",
                    "--ctrl", "type=unixio,path=\(sockets.appendingPathComponent("tpm.sock").path),terminate",
                ]
                process.environment = ProcessInfo.processInfo.environment.merging(["DYLD_FRAMEWORK_PATH": runtime.frameworks.path]) { _, new in new }
                try process.run()
                tpm = process
                let deadline = Date().addingTimeInterval(5)
                while !fm.fileExists(atPath: sockets.appendingPathComponent("tpm.sock").path) {
                    guard process.isRunning, Date() < deadline else { throw MachineError.command("TPM emulator failed to start") }
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
            let qemu = Process()
            qemu.executableURL = runtime.launcher
            qemu.arguments = [runtime.library("qemu-aarch64-softmmu").path] + arguments
            qemu.environment = ProcessInfo.processInfo.environment.merging(runtime.guestEnvironment(graphics: config.graphics)) { _, new in new }
            try qemu.run()
            qemu.waitUntilExit()
            guard qemu.terminationStatus == 0 else { throw MachineError.command("QEMU exited with status \(qemu.terminationStatus)") }
        }
    }
}
