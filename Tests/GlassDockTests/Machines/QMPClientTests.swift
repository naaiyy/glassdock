import Darwin
import Foundation
import Testing

@testable import GlassDockMachines

@Suite("Machine control transport")
struct QMPClientTests {
    @Test func guestShutdownDoesNotWaitForAnAbsentSuccessResponse() async throws {
        let server = try ControlTestServer()
        let task = Task.detached {
            try server.serve { fd in
                let request = try ControlTestServer.object(fd)
                #expect(request["execute"] as? String == "guest-shutdown")
                #expect((request["arguments"] as? [String: Any])?["mode"] as? String == "powerdown")
                // QGA closes or shuts down without a successful JSON response.
            }
        }
        let client = try QMPClient(socket: server.path, negotiate: false)
        try client.requestGuestShutdown()
        try await task.value
    }
    @Test func guestAgentSynchronizesPastStalePartialResponses() async throws {
        let server = try ControlTestServer()
        let task = Task.detached {
            try server.serve { fd in
                let sentinel = try ControlTestServer.line(fd)
                #expect(sentinel == Data([0xff]))
                let request = try ControlTestServer.object(fd)
                #expect(request["execute"] as? String == "guest-sync-delimited")
                let args = request["arguments"] as! [String: Any]
                let response: [String: Any] = ["id": request["id"]!, "return": args["id"]!]
                try ControlTestServer.send(fd, Data("old broken JSON fragment".utf8))
                try ControlTestServer.send(fd, Data([0xff]))
                try ControlTestServer.send(fd, try JSONSerialization.data(withJSONObject: response) + Data([10]))
                let ping = try ControlTestServer.object(fd)
                try ControlTestServer.send(fd, Data("{\"event\":\"ignored\"}\n{\"return\":{},\"id\":\"old-client\"}\n".utf8))
                try ControlTestServer.send(fd, try JSONSerialization.data(withJSONObject: ["return": [:], "id": ping["id"]!]) + Data([10]))
            }
        }
        let client = try QMPClient(socket: server.path, negotiate: false)
        try client.synchronizeGuestAgent()
        #expect(try client.command("guest-ping")["return"] != nil)
        try await task.value
    }
    @Test func negotiatedControlSurfacesQMPError() async throws {
        let server = try ControlTestServer()
        let task = Task.detached {
            try server.serve { fd in
                try ControlTestServer.send(fd, Data("{\"QMP\":{}}\n".utf8))
                let capabilities = try ControlTestServer.object(fd)
                #expect(capabilities["execute"] as? String == "qmp_capabilities")
                try ControlTestServer.send(fd, try JSONSerialization.data(withJSONObject: ["return": [:], "id": capabilities["id"]!]) + Data([10]))
                let request = try ControlTestServer.object(fd)
                try ControlTestServer.send(fd, try JSONSerialization.data(withJSONObject: ["error": ["desc": "snapshot unsupported"], "id": request["id"]!]) + Data([10]))
            }
        }
        let client = try QMPClient(socket: server.path)
        #expect(throws: MachineError.self) { try client.command("snapshot-save") }
        try await task.value
    }
}

private final class ControlTestServer: @unchecked Sendable {
    let path: URL
    private let directory: URL
    private let fd: Int32
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("qmp-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        path = directory.appendingPathComponent("c.sock")
        fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw MachineError.invalid("Test socket path is too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, Darwin.listen(fd, 1) == 0 else { throw MachineError.command("Cannot start test server") }
    }
    deinit {
        Darwin.close(fd)
        try? FileManager.default.removeItem(at: directory)
    }
    func serve(_ body: (Int32) throws -> Void) throws {
        let client = Darwin.accept(fd, nil, nil)
        guard client >= 0 else { throw MachineError.command("Cannot accept test connection") }
        defer { Darwin.close(client) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        try body(client)
    }
    static func line(_ fd: Int32) throws -> Data {
        var result = Data()
        while result.count < 65536 {
            var byte: UInt8 = 0
            guard Darwin.read(fd, &byte, 1) == 1 else { throw MachineError.command("Test peer closed or timed out") }
            if byte == 10 { return result }
            result.append(byte)
        }
        throw MachineError.command("Test request exceeds limit")
    }
    static func object(_ fd: Int32) throws -> [String: Any] { try JSONSerialization.jsonObject(with: line(fd)) as! [String: Any] }
    static func send(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw MachineError.command("Cannot write test response") }
                offset += count
            }
        }
    }
}
