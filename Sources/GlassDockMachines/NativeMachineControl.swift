import Darwin
import Foundation

/// Local-only adapter for the existing machine control client. This is a small
/// lifecycle protocol, not a QEMU emulator; unsupported commands return errors.
public final class NativeMachineControl: @unchecked Sendable {
    private let listener: Int32
    private let socket: URL
    private let handler: @Sendable (Data, @escaping @Sendable (Data) -> Void) -> Void
    private let clients = DispatchSemaphore(value: 8)

    public init(id: UUID, handler: @escaping @Sendable (Data, @escaping @Sendable (Data) -> Void) -> Void) throws {
        self.handler = handler
        let directory = QEMUArguments.socketDirectory(id: id)
        let parent = directory.deletingLastPathComponent()
        let fm = FileManager.default
        if !fm.fileExists(atPath: parent.path) { try fm.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        let attributes = try fm.attributesOfItem(atPath: parent.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory, (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
            ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o077 == 0
        else { throw MachineError.invalid("Insecure VM socket directory") }
        // The caller holds the machine lifetime lock before removing stale sockets.
        if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        socket = directory.appendingPathComponent("qmp.sock")
        listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw MachineError.command("Cannot allocate native control socket") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socket.path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(listener)
            throw MachineError.invalid("Control socket path is too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, Darwin.listen(listener, 8) == 0 else {
            Darwin.close(listener)
            throw MachineError.command("Cannot bind native control socket")
        }
        _ = chmod(socket.path, 0o600)
    }

    public func serve() {
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { Darwin.close(listener) }
            while true {
                let fd = Darwin.accept(listener, nil, nil)
                if fd < 0 {
                    if errno == EINTR { continue }
                    return
                }
                guard clients.wait(timeout: .now()) == .success else {
                    Darwin.close(fd)
                    continue
                }
                DispatchQueue.global(qos: .utility).async { [self] in
                    defer {
                        Darwin.close(fd)
                        clients.signal()
                    }
                    var timeout = timeval(tv_sec: 10, tv_usec: 0)
                    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                    _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                    var noSignal: Int32 = 1
                    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                    guard Self.write(Data("{\"QMP\":{\"capabilities\":[]}}\n".utf8), to: fd) else { return }
                    var pending = Data()
                    while true {
                        if let newline = pending.firstIndex(of: 10) {
                            let request = Data(pending.prefix(upTo: newline))
                            pending.removeSubrange(...newline)
                            let done = DispatchSemaphore(value: 0)
                            handler(request) { response in
                                var data = response
                                data.append(10)
                                _ = Self.write(data, to: fd)
                                done.signal()
                            }
                            // Lifecycle callbacks finish on the VM's main queue.
                            done.wait()
                            continue
                        }
                        guard pending.count < 65536 else { return }
                        var bytes = [UInt8](repeating: 0, count: 4096)
                        let count = Darwin.recv(fd, &bytes, bytes.count, 0)
                        if count < 0 && errno == EINTR { continue }
                        guard count > 0 else { return }
                        pending.append(contentsOf: bytes.prefix(count))
                    }
                }
            }
        }
    }

    public func stop() {
        _ = Darwin.shutdown(listener, SHUT_RDWR)
        try? FileManager.default.removeItem(at: socket.deletingLastPathComponent())
    }

    private static func write(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }
}
