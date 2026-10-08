import Foundation

public struct GuestExecution: Sendable {
    public var exitCode: Int
    public var stdout: String
    public var stderr: String
}

public final class GuestAgent {
    private let connection: QMPClient
    private let lock: MachineLock
    public init(id: UUID) throws {
        lock = try MachineLock(bundle: QEMUArguments.socketDirectory(id: id), name: "agent.lock")
        connection = try QMPClient(socket: QEMUArguments.socketDirectory(id: id).appendingPathComponent("agent.sock"), negotiate: false)
        try connection.synchronizeGuestAgent()
        _ = try connection.command("guest-ping")
    }
    public func info() throws -> [String: Any] { try connection.command("guest-info") }
    public func shutdown() throws {
        let details = try info()["return"] as? [String: Any]
        let commands = details?["supported_commands"] as? [[String: Any]] ?? []
        guard commands.contains(where: { $0["name"] as? String == "guest-shutdown" && $0["enabled"] as? Bool == true }) else {
            throw MachineError.command("Guest agent shutdown is unavailable")
        }
        try connection.requestGuestShutdown()
    }
    public func execute(path: String, arguments: [String] = [], timeout: TimeInterval = 60) throws -> GuestExecution {
        let start = try connection.command("guest-exec", arguments: ["path": path, "arg": arguments, "capture-output": true])
        guard let returned = start["return"] as? [String: Any], let pid = returned["pid"] as? Int else {
            throw MachineError.command("Guest agent did not return a process ID")
        }
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let response = try connection.command("guest-exec-status", arguments: ["pid": pid])
            guard let status = response["return"] as? [String: Any] else { throw MachineError.command("Invalid guest process status") }
            if status["exited"] as? Bool == true {
                func output(_ key: String) -> String {
                    guard let encoded = status[key] as? String, let data = Data(base64Encoded: encoded) else { return "" }
                    return String(decoding: data, as: UTF8.self)
                }
                return GuestExecution(exitCode: status["exitcode"] as? Int ?? 128 + (status["signal"] as? Int ?? 0), stdout: output("out-data"), stderr: output("err-data"))
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        throw MachineError.command("Guest process timed out; it may still be running")
    }
}
