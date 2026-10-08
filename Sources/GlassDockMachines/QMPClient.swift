import Darwin
import Foundation

public final class QMPClient {
    private let descriptor: Int32
    private var pending = Data()
    private var awaitingSentinel = false

    public init(socket: URL, negotiate: Bool = true, timeoutSeconds: Int = 5) throws {
        descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw MachineError.command("Cannot allocate QMP socket") }
        do {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(socket.path.utf8) + [0]
            guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw MachineError.invalid("QMP socket path is too long") }
            withUnsafeMutableBytes(of: &address.sun_path) { destination in destination.copyBytes(from: bytes) }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard result == 0 else { throw MachineError.command("Machine control socket is unavailable") }
            var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
            _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var noSignal: Int32 = 1
            _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            if negotiate {
                guard try readObject()["QMP"] != nil else { throw MachineError.command("Invalid QMP greeting") }
                _ = try command("qmp_capabilities")
            }
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }
    deinit { Darwin.close(descriptor) }

    public func synchronizeGuestAgent() throws {
        pending.removeAll()
        awaitingSentinel = true
        // The newline also flushes older Windows agents that reject 0xFF input.
        try write(Data([0xff, 10]))
        let token = Int64.random(in: 1...Int64.max)
        let response = try command("guest-sync-delimited", arguments: ["id": token])
        guard (response["return"] as? NSNumber)?.int64Value == token else { throw MachineError.command("Guest agent synchronization failed") }
    }
    private func write(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.send(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw MachineError.command("Cannot write QMP command") }
                offset += count
            }
        }
    }

    @discardableResult
    public func command(_ name: String, arguments: [String: Any] = [:]) throws -> [String: Any] {
        let id = UUID().uuidString
        var object: [String: Any] = ["execute": name, "id": id]
        if !arguments.isEmpty { object["arguments"] = arguments }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        try write(data)
        while true {
            let response = try readObject()
            guard response["id"] as? String == id else { continue }
            if let error = response["error"] as? [String: Any] { throw MachineError.command(error["desc"] as? String ?? "QMP command failed") }
            return response
        }
    }

    /// QGA guest-shutdown deliberately has no successful response: waiting for
    /// one would turn a successful shutdown into a transport timeout.
    public func requestGuestShutdown() throws {
        var data = try JSONSerialization.data(withJSONObject: ["execute": "guest-shutdown", "arguments": ["mode": "powerdown"]])
        data.append(10)
        try write(data)
    }

    private func readObject() throws -> [String: Any] {
        while true {
            if awaitingSentinel {
                if let sentinel = pending.firstIndex(of: 0xff) {
                    pending.removeSubrange(...sentinel)
                    awaitingSentinel = false
                } else {
                    pending.removeAll()
                }
            }
            if !awaitingSentinel, let newline = pending.firstIndex(of: 10) {
                let line = pending.prefix(upTo: newline)
                pending.removeSubrange(...newline)
                guard let value = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw MachineError.command("Invalid QMP response") }
                return value
            }
            guard pending.count < 8 * 1024 * 1024 else { throw MachineError.command("QMP response exceeds limit") }
            var bytes = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.recv(descriptor, &bytes, bytes.count, 0)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw MachineError.command("QMP connection closed or timed out") }
            pending.append(contentsOf: bytes.prefix(count))
        }
    }
}
