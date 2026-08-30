import Darwin
import Foundation
import Testing

@testable import GlassDock

@Suite("Persistent engine VM authority")
struct PersistentEngineTests {
    @Test("starts one custom machine and reuses one guest connection")
    func startsAndReuses() async throws {
        let machine = FakeEngineMachineHost()
        let engine = PersistentEngine(machine: machine)

        let first = try await engine.readyConnection()
        let second = try await engine.readyConnection()

        #expect(first === second)
        #expect(await machine.startCount == 1)
        #expect(await machine.connectCount == 1)
        #expect(await machine.lastPort == 1025)
        #expect(await machine.memoryTargets == [PersistentEngine.idleMemoryBytes])
        #expect(await engine.address() == "192.168.72.2")
        #expect(await engine.hostGatewayAddress() == "192.168.72.1")
        await engine.shutdown()
    }

    @Test("expands the guest for work and reclaims it after the idle delay")
    func managesMemoryTarget() async throws {
        let machine = FakeEngineMachineHost()
        let engine = PersistentEngine(machine: machine)

        _ = try await engine.readyConnection()
        try await engine.prepareForWork()
        await engine.finishedWork()
        try await Task.sleep(for: .milliseconds(300))

        #expect(
            await machine.memoryTargets == [
                PersistentEngine.idleMemoryBytes,
                PersistentEngine.activeMemoryBytes,
                PersistentEngine.idleMemoryBytes,
            ]
        )
        #expect(await machine.memoryTargetWaits == [false, false, false])
        await engine.shutdown()
    }

    @Test("does not reclaim while expanding the guest for work")
    func doesNotReclaimDuringExpansion() async throws {
        let machine = FakeEngineMachineHost(memoryTargetDelay: .milliseconds(100))
        let engine = PersistentEngine(machine: machine)

        _ = try await engine.readyConnection()
        await engine.finishedWork()
        let expansion = Task { try await engine.prepareForWork() }
        for _ in 0..<100 {
            if await machine.memoryTargetCallCount == 2 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try await Task.sleep(for: .milliseconds(60))
        try await expansion.value

        #expect(
            await machine.memoryTargets == [
                PersistentEngine.idleMemoryBytes,
                PersistentEngine.activeMemoryBytes,
            ])
        await engine.shutdown()
    }

    @Test("retains a larger target for a published network container")
    func retainsPublishedMemoryTarget() async throws {
        let machine = FakeEngineMachineHost()
        let engine = PersistentEngine(machine: machine)

        _ = try await engine.readyConnection()
        try await engine.retainMemoryTarget(
            id: "nginx", bytes: PersistentEngine.publishedNetworkMemoryBytes
        )
        await engine.releaseMemoryTarget(id: "nginx")
        try await Task.sleep(for: .milliseconds(300))

        #expect(
            await machine.memoryTargets == [
                PersistentEngine.idleMemoryBytes,
                PersistentEngine.publishedNetworkMemoryBytes,
                PersistentEngine.idleMemoryBytes,
            ]
        )
        await engine.shutdown()
    }

    @Test("rejects a ping response without the guest ok payload")
    func rejectsInvalidPing() async {
        let machine = FakeEngineMachineHost(pingOK: false)
        let engine = PersistentEngine(machine: machine)

        await #expect(throws: PersistentEngineError.self) {
            _ = try await engine.readyConnection()
        }
        #expect(await machine.stopCount == 1)
    }

    @Test("fails loudly when the guest agent speaks an old protocol version")
    func rejectsProtocolMismatch() async {
        let machine = FakeEngineMachineHost(protocolVersion: "0")
        let engine = PersistentEngine(machine: machine)

        do {
            _ = try await engine.readyConnection()
            Issue.record("readiness should have failed on protocol mismatch")
        } catch let error as PersistentEngineError {
            guard case .invalidMachineSnapshot(let message) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(message.contains("protocol mismatch"))
            #expect(message.contains("guest speaks 0"))
            #expect(message.contains("host requires 1"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        await engine.shutdown()
    }

    @Test("fails loudly when the guest agent has no version method")
    func rejectsMissingVersionHandshake() async {
        let machine = FakeEngineMachineHost(answersVersion: false)
        let engine = PersistentEngine(machine: machine)

        await #expect(throws: PersistentEngineError.self) {
            _ = try await engine.readyConnection()
        }
        await engine.shutdown()
    }

    @Test("coalesces concurrent readiness calls")
    func coalescesConcurrentReadiness() async throws {
        let machine = FakeEngineMachineHost(startDelay: .milliseconds(20))
        let engine = PersistentEngine(machine: machine)

        let connections = try await withThrowingTaskGroup(of: GuestConnection.self) { group in
            for _ in 0..<32 { group.addTask { try await engine.readyConnection() } }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        #expect(connections.allSatisfy { $0 === connections[0] })
        #expect(await machine.startCount == 1)
        #expect(await machine.connectCount == 1)
        await engine.shutdown()
    }

    @Test("waits for the guest protocol without starting another VM generation")
    func waitsForGuestProtocol() async throws {
        let machine = FakeEngineMachineHost(failedConnections: 2)
        let engine = PersistentEngine(machine: machine)

        _ = try await engine.readyConnection()

        #expect(await machine.startCount == 1)
        #expect(await machine.connectCount == 3)
        await engine.shutdown()
    }

    @Test("bounds a connected guest that has not started answering")
    func boundsConnectedGuestReadinessAttempt() async throws {
        let machine = FakeEngineMachineHost(hangingConnections: 1)
        let engine = PersistentEngine(machine: machine, guestReadinessTimeout: .seconds(1))

        _ = try await engine.readyConnection()

        #expect(await machine.connectCount == 2)
        await engine.shutdown()
    }

    @Test("replaces a terminal guest connection before the next request")
    func replacesTerminalConnection() async throws {
        let machine = FakeEngineMachineHost()
        let engine = PersistentEngine(machine: machine)

        let first = try await engine.readyConnection()
        await first.close()
        let second = try await engine.readyConnection()

        #expect(first !== second)
        #expect(await machine.connectCount == 2)
        #expect(await machine.stopCount == 1)
        await engine.shutdown()
    }

    @Test("coalesces concurrent replacement of a terminal connection")
    func coalescesConcurrentTerminalReplacement() async throws {
        let machine = FakeEngineMachineHost(startDelay: .milliseconds(10))
        let engine = PersistentEngine(machine: machine)
        let first = try await engine.readyConnection()
        await first.close()

        let replacements = try await withThrowingTaskGroup(of: GuestConnection.self) { group in
            for _ in 0..<64 { group.addTask { try await engine.readyConnection() } }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        #expect(replacements.allSatisfy { $0 === replacements[0] })
        #expect(await machine.startCount == 2)
        #expect(await machine.connectCount == 2)
        await engine.shutdown()
    }

    @Test("stale terminal check cannot discard a concurrent replacement")
    func staleTerminalCheckPreservesConcurrentReplacement() async throws {
        let machine = FakeEngineMachineHost()
        let probe = BlockingTerminalProbe()
        let engine = PersistentEngine(
            machine: machine,
            isConnectionTerminal: { connection in await probe.check(connection) }
        )
        let first = try await engine.readyConnection()
        await first.close()
        await probe.block(connection: first)

        let staleCaller = Task { try await engine.readyConnection() }
        await probe.waitUntilBlocked()
        await engine.invalidateConnection(first)
        let replacement = try await engine.readyConnection()
        await probe.release()
        let staleResult = try await staleCaller.value

        #expect(staleResult === replacement)
        #expect(await machine.connectCount == 2)
        await engine.shutdown()
    }

    @Test("event resubscription keeps the healthy shared connection")
    func eventResubscriptionKeepsSharedConnection() async throws {
        let machine = FakeEngineMachineHost()
        let engine = PersistentEngine(machine: machine)
        let connector = PersistentEngineGuestRuntimeEventConnector(engine: engine)
        let connection = try await engine.readyConnection()

        _ = try await connector.connect()
        _ = try await connector.connect()

        #expect(!(await connection.isTerminal()))
        #expect(await machine.connectCount == 1)
        await engine.shutdown()
    }
}

private actor BlockingTerminalProbe {
    private weak var blockedConnection: GuestConnection?
    private var shouldBlock = false
    private var isBlocked = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func block(connection: GuestConnection) {
        blockedConnection = connection
        shouldBlock = true
    }

    func check(_ connection: GuestConnection) async -> Bool {
        if shouldBlock, connection === blockedConnection {
            shouldBlock = false
            isBlocked = true
            await withCheckedContinuation { releaseContinuation = $0 }
        }
        return await connection.isTerminal()
    }

    func waitUntilBlocked() async {
        while !isBlocked { await Task.yield() }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor FakeEngineMachineHost: EngineMachineHosting {
    private let pingOK: Bool
    private let protocolVersion: String
    private let answersVersion: Bool
    private let startDelay: Duration?
    private var hangingConnections: Int
    private var failedConnections: Int
    private(set) var startCount = 0
    private(set) var connectCount = 0
    private(set) var stopCount = 0
    private(set) var memoryTargets: [UInt64] = []
    private(set) var memoryTargetCallCount = 0
    private(set) var lastPort: UInt32?
    private(set) var memoryTargetWaits: [Bool] = []
    private var peer: FileHandle?

    init(
        pingOK: Bool = true,
        protocolVersion: String = PersistentEngine.expectedGuestProtocolVersion,
        answersVersion: Bool = true,
        startDelay: Duration? = nil,
        hangingConnections: Int = 0,
        failedConnections: Int = 0,
        memoryTargetDelay: Duration? = nil
    ) {
        self.pingOK = pingOK
        self.protocolVersion = protocolVersion
        self.answersVersion = answersVersion
        self.startDelay = startDelay
        self.hangingConnections = hangingConnections
        self.failedConnections = failedConnections
        self.memoryTargetDelay = memoryTargetDelay
    }

    private let memoryTargetDelay: Duration?

    func start() async throws -> RuntimeMachineReady {
        startCount += 1
        if let startDelay { try await Task.sleep(for: startDelay) }
        return RuntimeMachineReady(
            generation: UUID(),
            processIdentifier: 62,
            guestIPv4: "192.168.72.2",
            hostGatewayIPv4: "192.168.72.1",
            gvproxyAPI: URL(fileURLWithPath: "/tmp/gvproxy.sock"),
            tcpRelaySocket: URL(fileURLWithPath: "/tmp/tcp-relay.sock")
        )
    }

    func setMemoryTarget(_ bytes: UInt64, waitForTarget: Bool) async throws {
        memoryTargetCallCount += 1
        if let memoryTargetDelay { try await Task.sleep(for: memoryTargetDelay) }
        memoryTargets.append(bytes)
        memoryTargetWaits.append(waitForTarget)
    }

    func connect(to port: UInt32) throws -> FileHandle {
        connectCount += 1
        lastPort = port
        if failedConnections > 0 {
            failedConnections -= 1
            throw POSIXError(.ECONNREFUSED)
        }
        var descriptors: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        let client = FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true)
        let peer = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
        self.peer = peer
        let pingOK = self.pingOK
        let shouldHang = hangingConnections > 0
        if shouldHang { hangingConnections -= 1 }
        Thread.detachNewThread {
            do {
                var codec = GuestFrameCodec()
                while true {
                    let bytes = try Self.readAvailable(peer)
                    guard !bytes.isEmpty else { return }
                    for request in try codec.append(bytes) {
                        if shouldHang { continue }
                        let payload: JSONValue
                        if request.method == "version" {
                            guard self.answersVersion else {
                                let error = GuestFrame(
                                    id: request.id,
                                    kind: .response,
                                    method: request.method,
                                    payload: nil,
                                    stream: nil,
                                    data: nil,
                                    error: GuestProtocolError(
                                        code: "unknown_method", message: "unknown method"
                                    ),
                                    exitCode: nil
                                )
                                try peer.write(contentsOf: GuestFrameCodec.encode(error))
                                continue
                            }
                            // Mirrors api.VersionResponse in
                            // Guest/internal/api/schema.go.
                            payload = .object([
                                "protocol": .string(self.protocolVersion),
                                "agent": .string("test"),
                                "containerd": .string("test"),
                            ])
                        } else {
                            payload = .object(["ok": .bool(pingOK)])
                        }
                        let response = GuestFrame(
                            id: request.id,
                            kind: .response,
                            method: request.method,
                            payload: payload,
                            stream: nil,
                            data: nil,
                            error: nil,
                            exitCode: nil
                        )
                        try peer.write(contentsOf: GuestFrameCodec.encode(response))
                    }
                }
            } catch {}
        }
        return client
    }

    func stop() {
        stopCount += 1
        try? peer?.close()
    }

    private nonisolated static func readAvailable(_ handle: FileHandle) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
            if count > 0 { return Data(bytes.prefix(count)) }
            if count == 0 { return Data() }
            if errno == EINTR { continue }
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }
}
