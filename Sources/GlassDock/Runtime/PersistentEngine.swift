import Foundation
import Logging

enum PersistentEngineError: Error, Equatable {
    case invalidMachineSnapshot(String)
    case guestReadinessTimedOut
}

private struct GuestReadinessAttemptTimedOut: Error {}

/// Owns the application-facing lifecycle of the one persistent custom VM.
/// Callers obtain one ready multiplexed guest connection and do not learn VMM
/// provisioning or device details.
actor PersistentEngine {
    static let guestPort: UInt32 = 1025

    /// Keep a large active working set while avoiding a full guest-memory
    /// restore after every idle interval. The idle target lets macOS reclaim
    /// guest pages between requests.
    static let configuredMemoryBytes: UInt64 = 1_024 * 1024 * 1024
    /// Keep a compact working set during ordinary requests. The balloon
    /// remains soft: the guest can deflate it when its OOM notifier or
    /// workload needs more memory.
    static let activeMemoryBytes: UInt64 = 256 * 1024 * 1024
    /// Published network containers keep the active reserve because the NGINX
    /// workload starts serving immediately after creation. Keeping this equal
    /// to the active target avoids a larger balloon expansion on the readiness
    /// path while the ordinary four-container idle sample uses the smaller
    /// reserve.
    static let publishedNetworkMemoryBytes: UInt64 = 256 * 1024 * 1024
    /// Retain a useful idle working set while allowing macOS to reclaim the
    /// guest pages that a normal Docker workload leaves cold.
    static let idleMemoryBytes: UInt64 = 144 * 1024 * 1024
    static let idleReclaimDelay: Duration = .milliseconds(50)

    /// The control-protocol version this host speaks. Must match `Version` in
    /// `Guest/internal/api/schema.go`; bump both sides together.
    static let expectedGuestProtocolVersion = "1"

    private let machine: any EngineMachineHosting
    private let logger: Logger
    private let configuredMemoryTarget: UInt64
    private let guestReadinessTimeout: Duration
    private let isConnectionTerminal: @Sendable (GuestConnection) async -> Bool
    private let socketRelay: DockerSocketRelayService?
    private var connection: GuestConnection?
    private var readyMachine: RuntimeMachineReady?
    private struct Readiness {
        let token: UUID
        let task: Task<(GuestConnection, RuntimeMachineReady), Error>
    }
    private var readiness: Readiness?
    private var requiresMachineRestart = false
    private var activeWork = 0
    private var reclaimTask: Task<Void, Never>?
    private var currentMemoryTarget: UInt64?
    private var retainedMemoryTargets: [String: UInt64] = [:]

    init(
        machine: any EngineMachineHosting,
        logger: Logger = Logger(label: "glassdock.engine"),
        configuredMemoryBytes: UInt64 = PersistentEngine.configuredMemoryBytes,
        guestReadinessTimeout: Duration = .seconds(10),
        isConnectionTerminal: @escaping @Sendable (GuestConnection) async -> Bool = PersistentEngine.connectionIsTerminal,
        socketRelay: DockerSocketRelayService? = nil
    ) {
        self.machine = machine
        self.logger = logger
        self.configuredMemoryTarget = configuredMemoryBytes
        self.guestReadinessTimeout = guestReadinessTimeout
        self.isConnectionTerminal = isConnectionTerminal
        self.socketRelay = socketRelay
    }

    func readyConnection() async throws -> GuestConnection {
        while let candidate = connection {
            let terminal = await isConnectionTerminal(candidate)
            guard connection === candidate else { continue }
            if !terminal { return candidate }
            self.connection = nil
            readyMachine = nil
            requiresMachineRestart = true
            currentMemoryTarget = nil
        }
        let current: Readiness
        if let readiness {
            current = readiness
        } else {
            let restartMachine = requiresMachineRestart
            requiresMachineRestart = false
            current = Readiness(
                token: UUID(),
                task: Task { try await self.establishConnection(restartMachine: restartMachine) }
            )
            readiness = current
        }
        do {
            let (connection, snapshot) = try await current.task.value
            if readiness?.token == current.token { readiness = nil }
            readyMachine = snapshot
            self.connection = connection
            return connection
        } catch {
            if readiness?.token == current.token { readiness = nil }
            throw error
        }
    }

    private nonisolated static func connectionIsTerminal(_ connection: GuestConnection) async
        -> Bool
    {
        await connection.isTerminal()
    }

    private func establishConnection(restartMachine: Bool) async throws
        -> (GuestConnection, RuntimeMachineReady)
    {
        if restartMachine {
            socketRelay?.stop()
            try await machine.stop()
        }
        let snapshot = try await machine.start()
        currentMemoryTarget = nil
        do {
            let connection = try await waitForGuestReadiness()
            try await setMemoryTarget(effectiveIdleMemoryTarget)
            await socketRelay?.start(connection: connection)
            logger.info("persistent engine is ready", metadata: ["ip": "\(snapshot.guestIPv4)"])
            return (connection, snapshot)
        } catch {
            try? await machine.stop()
            throw error
        }
    }

    /// Waits until the already-started guest can complete the control protocol
    /// handshake. libkrun publishes its host listener before the guest binds the
    /// corresponding vsock port, so socket existence alone is not readiness.
    /// This loop retries only the read-only startup ping. It never replays a
    /// Docker operation.
    private func waitForGuestReadiness() async throws -> GuestConnection {
        let deadline = ContinuousClock.now + guestReadinessTimeout
        var delay = Duration.milliseconds(1)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            var connection: GuestConnection?
            do {
                let candidate = try await GuestConnection.connect {
                    try await self.machine.connect(to: Self.guestPort)
                }
                connection = candidate
                let response = try await Self.guestPing(candidate)
                guard response.kind == .response,
                    response.payload == .object(["ok": .bool(true)])
                else {
                    await candidate.close()
                    throw PersistentEngineError.invalidMachineSnapshot(
                        "guest ping returned an invalid response"
                    )
                }
                try await Self.verifyProtocolVersion(candidate)
                return candidate
            } catch let error as PersistentEngineError {
                await connection?.close()
                throw error
            } catch {
                await connection?.close()
                let remaining = deadline - ContinuousClock.now
                guard remaining > .zero else { break }
                try await Task.sleep(for: min(delay, remaining))
                delay = min(delay * 2, .milliseconds(25))
            }
        }
        throw PersistentEngineError.guestReadinessTimedOut
    }

    private static func guestPing(_ connection: GuestConnection) async throws -> GuestFrame {
        try await withThrowingTaskGroup(of: GuestFrame.self) { group in
            group.addTask {
                try await connection.request(method: "ping", payload: .object([:]))
            }
            group.addTask {
                try await Task.sleep(for: .milliseconds(250))
                throw GuestReadinessAttemptTimedOut()
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// Verifies the guest agent speaks the expected control-protocol version.
    /// A stale guest agent previously booted silently and then failed at
    /// runtime with `unknown_method`; this check fails the connection up front
    /// with a loud, actionable error instead.
    private static func verifyProtocolVersion(_ connection: GuestConnection) async throws {
        let response: GuestFrame
        do {
            response = try await connection.request(method: "version", payload: .object([:]))
        } catch {
            await connection.close()
            throw PersistentEngineError.invalidMachineSnapshot(
                """
                guest agent did not answer the version handshake \
                (protocol \(Self.expectedGuestProtocolVersion) required): \(error)
                """
            )
        }
        guard case .object(let fields)? = response.payload,
            case .string(let protocolVersion)? = fields["protocol"]
        else {
            await connection.close()
            throw PersistentEngineError.invalidMachineSnapshot(
                "guest version handshake returned no protocol field"
            )
        }
        guard protocolVersion == Self.expectedGuestProtocolVersion else {
            await connection.close()
            throw PersistentEngineError.invalidMachineSnapshot(
                """
                guest agent protocol mismatch: guest speaks \(protocolVersion), \
                host requires \(Self.expectedGuestProtocolVersion); \
                rebuild the guest image (cd Guest && make image)
                """
            )
        }
    }

    func invalidateConnection() async {
        await connection?.close()
        connection = nil
        requiresMachineRestart = true
        currentMemoryTarget = nil
        reclaimTask?.cancel()
        reclaimTask = nil
        activeWork = 0
        readiness?.task.cancel()
        readiness = nil
    }

    func invalidateConnection(_ expected: GuestConnection) async {
        guard connection === expected else { return }
        await expected.close()
        connection = nil
        requiresMachineRestart = true
        currentMemoryTarget = nil
    }

    func shutdown() async {
        reclaimTask?.cancel()
        reclaimTask = nil
        activeWork = 0
        retainedMemoryTargets.removeAll()
        currentMemoryTarget = nil
        socketRelay?.stop()
        if let connection {
            _ = try? await connection.request(method: "engine.sync", payload: .object([:]))
            await connection.close()
        }
        connection = nil
        readyMachine = nil
        do {
            try await machine.stop()
        } catch {
            logger.error("failed to stop persistent engine", metadata: ["error": "\(error)"])
        }
    }

    func prepareForWork(memoryTarget: UInt64? = nil) async throws {
        reclaimTask?.cancel()
        reclaimTask = nil
        let shouldExpand = activeWork == 0
        activeWork += 1
        guard shouldExpand else { return }
        do {
            let target = min(memoryTarget ?? activeMemoryTarget, configuredMemoryTarget)
            try await setMemoryTarget(max(target, effectiveIdleMemoryTarget))
        } catch {
            activeWork = max(0, activeWork - 1)
            throw error
        }
    }

    func finishedWork() {
        activeWork = max(0, activeWork - 1)
        guard activeWork == 0 else { return }
        scheduleIdleReclaim()
    }

    func retainMemoryTarget(id: String, bytes: UInt64) async throws {
        let target = min(bytes, configuredMemoryTarget)
        let previousTarget = retainedMemoryTargets[id]
        retainedMemoryTargets[id] = target
        reclaimTask?.cancel()
        reclaimTask = nil
        guard activeWork == 0 else { return }
        do {
            try await setMemoryTarget(effectiveIdleMemoryTarget)
        } catch {
            if let previousTarget {
                retainedMemoryTargets[id] = previousTarget
            } else {
                retainedMemoryTargets.removeValue(forKey: id)
            }
            throw error
        }
    }

    func releaseMemoryTarget(id: String) {
        guard retainedMemoryTargets.removeValue(forKey: id) != nil else { return }
        guard activeWork == 0 else { return }
        scheduleIdleReclaim()
    }

    private var idleMemoryTarget: UInt64 {
        min(Self.idleMemoryBytes, configuredMemoryTarget)
    }

    private var activeMemoryTarget: UInt64 {
        min(Self.activeMemoryBytes, configuredMemoryTarget)
    }

    private var effectiveIdleMemoryTarget: UInt64 {
        max(idleMemoryTarget, retainedMemoryTargets.values.max() ?? idleMemoryTarget)
    }

    private func reclaimIdleMemory() async throws {
        guard activeWork == 0 else { return }
        try await setMemoryTarget(effectiveIdleMemoryTarget)
    }

    private func scheduleIdleReclaim() {
        reclaimTask?.cancel()
        reclaimTask = Task { [weak self] in
            try? await Task.sleep(for: Self.idleReclaimDelay)
            guard !Task.isCancelled else { return }
            try? await self?.reclaimIdleMemory()
        }
    }

    private func setMemoryTarget(_ target: UInt64, waitForTarget: Bool = false) async throws {
        guard currentMemoryTarget != target else { return }
        let previousTarget = currentMemoryTarget
        currentMemoryTarget = target
        do {
            try await machine.setMemoryTarget(target, waitForTarget: waitForTarget)
        } catch {
            currentMemoryTarget = previousTarget
            throw error
        }
    }

    func address() -> String? {
        readyMachine?.guestIPv4
    }

    func hostGatewayAddress() -> String? {
        readyMachine?.hostGatewayIPv4
    }

}
