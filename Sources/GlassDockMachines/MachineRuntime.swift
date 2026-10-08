import Darwin
import Foundation

public struct MachineRuntime: Sendable {
    public let app: URL
    public let launcher: URL
    public let supervisor: URL

    public init(app: URL, launcher: URL, supervisor: URL) {
        self.app = app
        self.launcher = launcher
        self.supervisor = supervisor
    }

    public static func discover() throws -> Self {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let bin = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GLASSDOCK_VM_BIN"] ?? executable.deletingLastPathComponent().path)
        let environment = ProcessInfo.processInfo.environment
        let bundled = bin.deletingLastPathComponent().appendingPathComponent("Resources/UTM.app")
        let native = bin.deletingLastPathComponent().deletingLastPathComponent()
        let nativeLibrary = native.appendingPathComponent("Contents/Frameworks/qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu")
        let developmentNative = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/machines/GlassDock Machines.app")
        let developmentLibrary = developmentNative.appendingPathComponent("Contents/Frameworks/qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu")
        let installedNative = URL(fileURLWithPath: "/Applications/GlassDock Machines.app")
        let installedLibrary = installedNative.appendingPathComponent("Contents/Frameworks/qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu")
        let defaultApp =
            FileManager.default.fileExists(atPath: nativeLibrary.path)
            ? native.path
            : (FileManager.default.fileExists(atPath: developmentLibrary.path)
                ? developmentNative.path
                : (FileManager.default.fileExists(atPath: installedLibrary.path)
                    ? installedNative.path
                    : (FileManager.default.fileExists(atPath: bundled.path) ? bundled.path : FileManager.default.currentDirectoryPath + "/.build/machines/UTM.app")))
        let app = URL(fileURLWithPath: environment["GLASSDOCK_VM_RUNTIME"] ?? defaultApp)
        let helpers = Self.helperDirectory(app: app, fallback: bin, overridden: environment["GLASSDOCK_VM_BIN"] != nil)
        let launcher = helpers.appendingPathComponent("glassdock-qemu")
        let supervisor = helpers.appendingPathComponent("glassdock-vm-runner")
        let runtime = Self(app: app, launcher: launcher, supervisor: supervisor)
        guard FileManager.default.isExecutableFile(atPath: launcher.path), FileManager.default.isExecutableFile(atPath: supervisor.path),
            FileManager.default.fileExists(atPath: runtime.library("qemu-aarch64-softmmu").path)
        else {
            throw MachineError.runtimeMissing(
                "Build GlassDock Machines with scripts/machines/build-app.sh, or set GLASSDOCK_VM_RUNTIME and GLASSDOCK_VM_BIN to a prepared runtime and signed helpers.")
        }
        return runtime
    }

    static func helperDirectory(app: URL, fallback: URL, overridden: Bool) -> URL {
        let bundled = app.appendingPathComponent("Contents/MacOS")
        return !overridden && ["glassdock-qemu", "glassdock-vm-runner"].allSatisfy { FileManager.default.isExecutableFile(atPath: bundled.appendingPathComponent($0).path) }
            ? bundled : fallback
    }

    public var firmware: URL { app.appendingPathComponent("Contents/Resources/qemu") }
    public func firmwareTemplates(for operatingSystem: MachineOS) -> (code: URL, variables: URL) {
        let secure = operatingSystem == .windows ? "-secure" : ""
        return (firmware.appendingPathComponent("edk2-aarch64\(secure)-code.fd"), firmware.appendingPathComponent("edk2-arm\(secure)-vars.fd"))
    }
    public var frameworks: URL { app.appendingPathComponent("Contents/Frameworks") }
    public func guestEnvironment(graphics: MachineGraphics) -> [String: String] {
        var environment = ["DYLD_FRAMEWORK_PATH": frameworks.path]
        if graphics != .basic { environment["ANGLE_DEFAULT_PLATFORM"] = "metal" }
        if graphics == .neptune {
            environment["NPT_BACKEND"] = "dxmt"
            let bundled = app.appendingPathComponent("Contents/MacOS/glassdock-render-server")
            let bootstrap = app.appendingPathComponent("Contents/XPCServices/QEMUHelper.xpc/Contents/MacOS/QEMURenderServer.app/Contents/MacOS/QEMURenderServer")
            environment["RENDER_SERVER_EXEC_PATH"] = FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled.path : bootstrap.path
            for name in ["D3D11", "D3D12", "DXGI"] { environment["NPT_\(name)_LIBRARY_PATH"] = library("dxmt-native").path }
        }
        return environment
    }
    public func library(_ name: String) -> URL { frameworks.appendingPathComponent("\(name).framework/\(name)") }

    @discardableResult
    public func tool(_ name: String, _ arguments: [String]) throws -> String {
        try Self.execute(launcher, [library(name).path] + arguments, environment: ["DYLD_FRAMEWORK_PATH": frameworks.path])
    }

    @discardableResult
    public static func execute(_ executable: URL, _ arguments: [String], environment: [String: String] = [:]) throws -> String {
        // A temporary file prevents output pipe deadlocks, including qemu-img progress.
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw MachineError.command("Cannot create tool output")
        }
        defer { try? FileManager.default.removeItem(at: output) }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        process.waitUntilExit()
        let reader = try FileHandle(forReadingFrom: output)
        defer { try? reader.close() }
        let size = try reader.seekToEnd()
        try reader.seek(toOffset: size > 65536 ? size - 65536 : 0)
        let data = try reader.readToEnd() ?? Data()
        let text = String(decoding: data.suffix(65536), as: UTF8.self)
        guard process.terminationStatus == 0 else { throw MachineError.command(text) }
        return text
    }
}

// Shared by the supervisor and every offline mutation, across all app/CLI processes.
public final class MachineLock {
    private let fd: Int32
    public init(bundle: URL, name: String = "operation.lock") throws {
        guard name.range(of: "^[A-Za-z0-9_-]+\\.lock$", options: .regularExpression) != nil else { throw MachineError.invalid("Invalid lock name") }
        fd = Darwin.open(bundle.appendingPathComponent(name).path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw MachineError.command("Cannot open machine lock") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            throw MachineError.busy
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }
    deinit {
        _ = flock(fd, LOCK_UN)
        Darwin.close(fd)
    }
}
