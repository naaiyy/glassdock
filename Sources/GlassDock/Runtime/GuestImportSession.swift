import Foundation

/// Coordinates one streaming `image.import` RPC. Archive chunks are written as
/// they arrive from the HTTP request body and every write awaits its own
/// completion, so backpressure flows end-to-end (network → Vapor drain → guest
/// vsock) without ever buffering the archive in daemon memory.
final class GuestImportSession: @unchecked Sendable {
    /// Gate between the request frame reaching the wire and the first chunk
    /// write. The RPC task fulfills it; chunk writes await it.
    private final class StartGate: @unchecked Sendable {
        private let lock = NSLock()
        private var requestID: UInt64?
        private var failure: Error?
        private var continuation: CheckedContinuation<UInt64, Error>?

        func register(id: UInt64) {
            lock.lock()
            defer { lock.unlock() }
            requestID = id
            continuation?.resume(returning: id)
            continuation = nil
        }

        func fail(_ error: Error) {
            lock.lock()
            defer { lock.unlock() }
            failure = error
            continuation?.resume(throwing: error)
            continuation = nil
        }

        func awaitStart() async throws -> UInt64 {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                defer { lock.unlock() }
                if let requestID {
                    continuation.resume(returning: requestID)
                } else if let failure {
                    continuation.resume(throwing: failure)
                } else {
                    self.continuation = continuation
                }
            }
        }
    }

    private static let maximumChunkSize = 256 * 1024

    private let connection: GuestConnection
    private let gate: StartGate
    private let decodeResponse: @Sendable (GuestFrame) throws -> [DockerRuntimeImage]
    private let onFinish: @Sendable () async -> Void
    private let responseTask: Task<[DockerRuntimeImage], Error>

    init(
        connection: GuestConnection, reference: String?,
        decodeResponse: @escaping @Sendable (GuestFrame) throws -> [DockerRuntimeImage],
        onFinish: @escaping @Sendable () async -> Void = {}
    ) {
        self.connection = connection
        self.decodeResponse = decodeResponse
        self.onFinish = onFinish
        let gate = StartGate()
        self.gate = gate
        var payload: [String: JSONValue] = [:]
        if let reference, !reference.isEmpty {
            payload["reference"] = .string(reference)
        }
        // Captures only immutable members plus the gate — never self — so the
        // task can be created during initialization.
        responseTask = Task { [connection, decodeResponse, gate, onFinish] in
            defer { Task { await onFinish() } }
            let frame = try await connection.request(
                method: "image.import",
                payload: .object(payload),
                onStream: { _ in },
                onRequestID: { requestID in
                    gate.register(id: requestID)
                }
            )
            return try decodeResponse(frame)
        }
    }

    func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        let requestID = try await gate.awaitStart()
        try await Self.send(
            data: data, connection: connection, requestID: requestID
        )
    }

    /// Sends the upload EOF marker. Must be called after the last chunk.
    func endInput() async throws {
        let requestID = try await gate.awaitStart()
        // An empty stdin frame is the upload EOF marker.
        try await connection.sendStream(id: requestID, stream: .stdin, data: Data())
    }

    /// Awaits the guest's final import response.
    func finish() async throws -> [DockerRuntimeImage] {
        try await responseTask.value
    }

    func abort() {
        responseTask.cancel()
    }

    private static func send(
        data: Data, connection: GuestConnection, requestID: UInt64
    ) async throws {
        var offset = 0
        while offset < data.count {
            let end = min(offset + maximumChunkSize, data.count)
            try await connection.sendStream(
                id: requestID, stream: .stdin, data: data.subdata(in: offset..<end)
            )
            offset = end
        }
    }
}
