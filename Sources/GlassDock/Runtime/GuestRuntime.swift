import Foundation
import Vapor

private final class GuestStreamCollector: @unchecked Sendable {
    private static let maximumBytes = 16 * 1024 * 1024
    private let lock = NSLock()
    private let collectStdout: Bool
    private let collectStderr: Bool
    private var stdout = Data()
    private var stderr = Data()
    private var overflowed = false

    init(stdout: Bool, stderr: Bool) {
        self.collectStdout = stdout
        self.collectStderr = stderr
    }

    func append(_ frame: GuestFrame) {
        guard let data = frame.data else { return }
        lock.lock()
        defer { lock.unlock() }
        guard stdout.count + stderr.count + data.count <= Self.maximumBytes else {
            overflowed = true
            return
        }
        switch frame.stream {
        case .stdin: break
        case .stdout where collectStdout: stdout.append(data)
        case .stderr where collectStderr: stderr.append(data)
        case .stdout, .stderr: break
        case nil: break
        }
    }

    func output(exitCode: Int32) throws -> DockerRuntimeProcessOutput {
        lock.lock()
        defer { lock.unlock() }
        if overflowed {
            throw DockerRuntimeRouteError.invalidRequest(
                "exec output exceeded the 16 MiB buffered-output limit"
            )
        }
        return DockerRuntimeProcessOutput(stdout: stdout, stderr: stderr, exitCode: exitCode)
    }
}

private final class GuestStreamRequestControl: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func set(_ task: Task<Void, Never>) { lock.withLock { self.task = task } }
    func cancel() { lock.withLock { task?.cancel() } }
}

final class GuestInputRelay: @unchecked Sendable {
    private static let maximumChunkSize = 256 * 1024
    private let lock = NSLock()
    private var connection: GuestConnection?
    private var requestID: UInt64?
    private var buffered: [Data] = []
    private var lastSend: Task<Void, Never>?

    func set(connection: GuestConnection, requestID: UInt64) {
        lock.lock()
        self.connection = connection
        self.requestID = requestID
        let pending = buffered
        buffered.removeAll()
        lock.unlock()
        for data in pending { sendNow(data, connection: connection, requestID: requestID) }
    }

    func send(_ data: Data) {
        lock.lock()
        guard let connection, let requestID else {
            buffered.append(data)
            lock.unlock()
            return
        }
        lock.unlock()
        sendNow(data, connection: connection, requestID: requestID)
    }

    private func sendNow(_ data: Data, connection: GuestConnection, requestID: UInt64) {
        lock.lock()
        let previous = lastSend
        let current = Task { [previous] in
            _ = await previous?.value
            if data.isEmpty {
                try? await connection.sendStream(id: requestID, stream: .stdin, data: data)
                return
            }
            var offset = 0
            while offset < data.count {
                let end = min(offset + Self.maximumChunkSize, data.count)
                try? await connection.sendStream(
                    id: requestID,
                    stream: .stdin,
                    data: data.subdata(in: offset..<end)
                )
                offset = end
            }
        }
        lastSend = current
        lock.unlock()
    }
}

struct GuestContainerPayload: Decodable {
    let container: GuestContainer
}

struct GuestContainerListPayload: Decodable {
    let containers: [GuestContainer]

    enum CodingKeys: String, CodingKey {
        case containers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        containers = try container.decodeLenientArray(forKey: .containers)
    }
}

struct GuestContainer: Decodable {
    let id: String
    let image: String
    let status: String
    let exitCode: UInt32?
    let createdAt: Date
    let sizeRw: Int64?
    let sizeRootFs: Int64?
    let publishedPorts: [GuestPublishedPort]?
    let metadata: GuestContainerMetadata?
    let health: GuestHealth?
}

struct GuestContainerMetadata: Decodable {
    let name: String?
    let args: [String]?
    let lifecycleState: String?
    let entrypoint: [String]?
    let cmd: [String]?
    let env: [String]?
    let cwd: String?
    let user: String?
    let hostname: String?
    let labels: [String: String]?
    let terminal: Bool?
    let attachStdin: Bool?
    let openStdin: Bool?
    let stdinOnce: Bool?
    let autoRemove: Bool?
    let stopTimeout: Int?
    let mounts: [DockerRuntimeMount]?
    let readonlyRootfs: Bool?
    let dns: [String]?
    let dnsSearch: [String]?
    let extraHosts: [String]?
    let portBindings: [DockerRuntimePortBinding]?
    let publishedPorts: [GuestPublishedPort]?
    let healthcheck: GuestHealthcheck?
    let restartPolicy: DockerRuntimeRestartPolicy?
    let restartCount: Int?
    let resources: DockerRuntimeResources?
    let networkMode: String?
    let stopSignal: String?
}

/// The guest serializes health checks with `omitempty`; absent and null
/// fields decode as zero values instead of failing the decode.
struct GuestHealthcheck: Decodable {
    let test: [String]
    let interval: Int64
    let timeout: Int64
    let retries: Int
    let startPeriod: Int64
    let startInterval: Int64

    enum CodingKeys: String, CodingKey {
        case test, interval, timeout, retries, startPeriod, startInterval
    }

    init(
        test: [String] = [], interval: Int64 = 0, timeout: Int64 = 0, retries: Int = 0,
        startPeriod: Int64 = 0, startInterval: Int64 = 0
    ) {
        self.test = test
        self.interval = interval
        self.timeout = timeout
        self.retries = retries
        self.startPeriod = startPeriod
        self.startInterval = startInterval
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        test = try container.decodeLenientArray(forKey: .test)
        interval = try container.decodeLenient(forKey: .interval)
        timeout = try container.decodeLenient(forKey: .timeout)
        retries = try container.decodeLenient(forKey: .retries)
        startPeriod = try container.decodeLenient(forKey: .startPeriod)
        startInterval = try container.decodeLenient(forKey: .startInterval)
    }
}

struct GuestHealth: Decodable {
    let status: String
    let failingStreak: Int
    let log: [DockerRuntimeHealth.HealthcheckResult]

    enum CodingKeys: String, CodingKey {
        case status, failingStreak, log
    }

    init(status: String, failingStreak: Int = 0, log: [DockerRuntimeHealth.HealthcheckResult] = []) {
        self.status = status
        self.failingStreak = failingStreak
        self.log = log
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(String.self, forKey: .status)
        failingStreak = try container.decodeLenient(forKey: .failingStreak)
        log = try container.decodeLenientArray(forKey: .log)
    }
}

struct GuestContainerUpdatePayload: Decodable {
    let warnings: [String]?
}

/// Lenient view of the guest's container.top response; the guest's nil Go
/// slices arrive as JSON null.
struct GuestTopPayload: Decodable {
    let titles: [String]
    let processes: [[String]]

    enum CodingKeys: String, CodingKey {
        case titles, processes
    }

    init(titles: [String] = [], processes: [[String]] = []) {
        self.titles = titles
        self.processes = processes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        titles = try container.decodeLenientArray(forKey: .titles)
        processes = try container.decodeLenientArray(forKey: .processes)
    }
}

/// Lenient view of the guest's container.stats response. The guest omits
/// zero-valued memory, blkio, pids, and network fields with `omitempty`, and
/// nil slices and maps arrive as JSON null.
struct GuestStatsPayload: Decodable {
    struct CPUUsage: Decodable {
        let totalUsage: UInt64
        let inKernelMode: UInt64
        let inUserMode: UInt64

        enum CodingKeys: String, CodingKey {
            case totalUsage = "total_usage"
            case inKernelMode = "usage_in_kernelmode"
            case inUserMode = "usage_in_usermode"
        }

        init(totalUsage: UInt64 = 0, inKernelMode: UInt64 = 0, inUserMode: UInt64 = 0) {
            self.totalUsage = totalUsage
            self.inKernelMode = inKernelMode
            self.inUserMode = inUserMode
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            totalUsage = try container.decodeLenient(forKey: .totalUsage)
            inKernelMode = try container.decodeLenient(forKey: .inKernelMode)
            inUserMode = try container.decodeLenient(forKey: .inUserMode)
        }
    }

    struct ThrottlingData: Decodable {
        let throttledPeriods: UInt64
        let throttledTime: UInt64
        let throttlingPeriods: UInt64

        enum CodingKeys: String, CodingKey {
            case throttledPeriods = "throttled_periods"
            case throttledTime = "throttled_time"
            case throttlingPeriods = "throttling_periods"
        }

        init(
            throttledPeriods: UInt64 = 0, throttledTime: UInt64 = 0,
            throttlingPeriods: UInt64 = 0
        ) {
            self.throttledPeriods = throttledPeriods
            self.throttledTime = throttledTime
            self.throttlingPeriods = throttlingPeriods
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            throttledPeriods = try container.decodeLenient(forKey: .throttledPeriods)
            throttledTime = try container.decodeLenient(forKey: .throttledTime)
            throttlingPeriods = try container.decodeLenient(forKey: .throttlingPeriods)
        }
    }

    struct CPUStats: Decodable {
        let cpuUsage: CPUUsage
        let systemCPUUsage: UInt64
        let onlineCPUs: Int
        let throttlingData: ThrottlingData

        enum CodingKeys: String, CodingKey {
            case cpuUsage = "cpu_usage"
            case systemCPUUsage = "system_cpu_usage"
            case onlineCPUs = "online_cpus"
            case throttlingData = "throttling_data"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            cpuUsage = try container.decode(CPUUsage.self, forKey: .cpuUsage)
            systemCPUUsage = try container.decodeLenient(forKey: .systemCPUUsage)
            onlineCPUs = try container.decodeLenient(forKey: .onlineCPUs)
            throttlingData = try container.decode(ThrottlingData.self, forKey: .throttlingData)
        }
    }

    struct MemoryStats: Decodable {
        let usage: UInt64
        let limit: UInt64
        let stats: [String: UInt64]

        enum CodingKeys: String, CodingKey {
            case usage, limit, stats
        }

        init(usage: UInt64 = 0, limit: UInt64 = 0, stats: [String: UInt64] = [:]) {
            self.usage = usage
            self.limit = limit
            self.stats = stats
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            usage = try container.decodeLenient(forKey: .usage)
            limit = try container.decodeLenient(forKey: .limit)
            stats = try container.decodeLenientMap(forKey: .stats)
        }
    }

    struct BlkioEntry: Decodable {
        let major: UInt64
        let minor: UInt64
        let op: String
        let value: UInt64

        enum CodingKeys: String, CodingKey {
            case major, minor, op, value
        }

        init(major: UInt64, minor: UInt64, op: String, value: UInt64) {
            self.major = major
            self.minor = minor
            self.op = op
            self.value = value
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            major = try container.decodeLenient(forKey: .major)
            minor = try container.decodeLenient(forKey: .minor)
            op = try container.decode(String.self, forKey: .op)
            value = try container.decodeLenient(forKey: .value)
        }
    }

    private enum FieldKeys: String, CodingKey {
        case id, read, preread, networks
        case cpuStats = "cpu_stats"
        case precpuStats = "precpu_stats"
        case memoryStats = "memory_stats"
        case blkioStats = "blkio_stats"
        case entries = "io_service_bytes_recursive"
        case pidsStats = "pids_stats"
        case current
    }

    let id: String
    let read: String
    let preread: String
    let cpuStats: CPUStats
    let precpuStats: CPUStats
    let memoryStats: MemoryStats
    let networks: [String: JSONValue]?
    let blkioEntries: [BlkioEntry]
    let pidsCurrent: UInt64?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: FieldKeys.self)
        id = try container.decode(String.self, forKey: .id)
        read = try container.decode(String.self, forKey: .read)
        preread = try container.decode(String.self, forKey: .preread)
        cpuStats = try container.decode(CPUStats.self, forKey: .cpuStats)
        precpuStats = try container.decode(CPUStats.self, forKey: .precpuStats)
        memoryStats = try container.decode(MemoryStats.self, forKey: .memoryStats)
        networks = try container.decodeIfPresent([String: JSONValue].self, forKey: .networks)
        if container.contains(.blkioStats) {
            let blkio = try container.nestedContainer(keyedBy: FieldKeys.self, forKey: .blkioStats)
            blkioEntries =
                blkio.contains(.entries)
                ? try blkio.decode([BlkioEntry].self, forKey: .entries) : []
        } else {
            blkioEntries = []
        }
        if container.contains(.pidsStats) {
            let pids = try container.nestedContainer(keyedBy: FieldKeys.self, forKey: .pidsStats)
            pidsCurrent = try pids.decodeIfPresent(UInt64.self, forKey: .current)
        } else {
            pidsCurrent = nil
        }
    }
}

struct GuestPublishedPort: Decodable {
    let containerPort: Int
    let guestPort: Int
    let `protocol`: String?
}

struct GuestImagePayload: Decodable {
    let name: String
    let digest: String
    let needsSync: Bool?
}

struct GuestImageDetailPayload: Decodable {
    let id: String
    let digest: String
    let references: [String]
    let createdAt: Date
    let size: Int64
    let labels: [String: String]?
    let author: String?
    let architecture: String?
    let os: String?
    let osVersion: String?
    let variant: String?
    let config: GuestImageConfigPayload?
    let rootFSLayers: [String]
    let history: [GuestImageHistoryPayload]

    enum CodingKeys: String, CodingKey {
        case id, digest, references, createdAt, size, labels, author
        case architecture, os, osVersion, variant, config
        case rootFSLayers = "rootfsLayers"
        case history
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        digest = try container.decode(String.self, forKey: .digest)
        references = try container.decodeLenientArray(forKey: .references)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        size = try container.decode(Int64.self, forKey: .size)
        labels = try container.decodeIfPresent([String: String].self, forKey: .labels)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        architecture = try container.decodeIfPresent(String.self, forKey: .architecture)
        os = try container.decodeIfPresent(String.self, forKey: .os)
        osVersion = try container.decodeIfPresent(String.self, forKey: .osVersion)
        variant = try container.decodeIfPresent(String.self, forKey: .variant)
        config = try container.decodeIfPresent(GuestImageConfigPayload.self, forKey: .config)
        rootFSLayers = try container.decodeLenientArray(forKey: .rootFSLayers)
        history = try container.decodeLenientArray(forKey: .history)
    }
}

struct GuestImageConfigPayload: Decodable {
    let user: String?
    let exposedPorts: [String: GuestEmptyObject]?
    let env: [String]?
    let entrypoint: [String]?
    let cmd: [String]?
    let volumes: [String: GuestEmptyObject]?
    let workingDir: String?
    let labels: [String: String]?
    let stopSignal: String?
    let healthcheck: GuestHealthcheck?
    let onBuild: [String]?
    let shell: [String]?
}

struct GuestEmptyObject: Decodable {}

struct GuestImageHistoryPayload: Decodable {
    let created: Date
    let createdBy: String?
    let tags: [String]?
    let size: Int64
    let comment: String?
    let emptyLayer: Bool?
}

struct GuestImageListPayload: Decodable {
    let images: [GuestImageDetailPayload]

    enum CodingKeys: String, CodingKey {
        case images
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        images = try container.decodeLenientArray(forKey: .images)
    }
}

struct GuestImageDeletePayload: Decodable {
    let deleted: [String]?
    let untagged: [String]?
    let reclaimed: Int64?
}

struct GuestImageImportPayload: Decodable {
    let images: [GuestImagePayload]

    enum CodingKeys: String, CodingKey {
        case images
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        images = try container.decodeLenientArray(forKey: .images)
    }
}

struct GuestImageBuildPayload: Decodable {
    let image: GuestImagePayload
}

struct GuestExitPayload: Decodable {
    let id: String
    let exitCode: UInt32
}

struct GuestLogsPayload: Decodable {
    let stdout: Data?
    let stderr: Data?
}

struct GuestArchivePathPayload: Decodable {
    let name: String
    let size: Int64
    let mode: Int64
    let modifiedAt: Date
    let linkTarget: String?
}

struct GuestContainerChangePayload: Decodable {
    let path: String
    let kind: Int
}

struct GuestContainerChangesPayload: Decodable {
    let changes: [GuestContainerChangePayload]

    enum CodingKeys: String, CodingKey {
        case changes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        changes = try container.decodeLenientArray(forKey: .changes)
    }
}

struct GuestNetworkListPayload: Decodable {
    let networks: [GuestNetworkPayload]

    enum CodingKeys: String, CodingKey {
        case networks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        networks = try container.decodeLenientArray(forKey: .networks)
    }
}

/// Matches the guest's `NetworkCreateResponse`, which wraps the resource.
struct GuestNetworkCreatePayload: Decodable {
    let network: GuestNetworkPayload
}

struct GuestNetworkPayload: Decodable {
    let id: String
    let name: String
    let createdAt: Date
    let scope: String
    let driver: String
    let enableIPv4: Bool
    let enableIPv6: Bool
    let internalNetwork: Bool
    let attachable: Bool
    let ingress: Bool
    let ipam: NetworkIPAMPayload
    let options: [String: String]
    let containers: [String: GuestNetworkContainerPayload]
    let labels: [String: String]

    enum CodingKeys: String, CodingKey {
        case id, name, createdAt, scope, driver, enableIPv4, enableIPv6
        case internalNetwork = "internal"
        case attachable, ingress, ipam, options, containers, labels
    }

    /// The guest sends nil maps as JSON null; they decode as empty maps.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        scope = try container.decode(String.self, forKey: .scope)
        driver = try container.decode(String.self, forKey: .driver)
        enableIPv4 = try container.decode(Bool.self, forKey: .enableIPv4)
        enableIPv6 = try container.decode(Bool.self, forKey: .enableIPv6)
        internalNetwork = try container.decode(Bool.self, forKey: .internalNetwork)
        attachable = try container.decode(Bool.self, forKey: .attachable)
        ingress = try container.decode(Bool.self, forKey: .ingress)
        ipam = try container.decode(NetworkIPAMPayload.self, forKey: .ipam)
        options = try container.decodeLenientMap(forKey: .options)
        containers = try container.decodeLenientMap(forKey: .containers)
        labels = try container.decodeLenientMap(forKey: .labels)
    }
}

struct NetworkIPAMPayload: Decodable {
    let driver: String
    let config: [NetworkIPAMConfigPayload]

    enum CodingKeys: String, CodingKey {
        case driver, config
    }

    init(driver: String, config: [NetworkIPAMConfigPayload]) {
        self.driver = driver
        self.config = config
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        driver = try container.decode(String.self, forKey: .driver)
        config = try container.decodeLenientArray(forKey: .config)
    }
}

struct NetworkIPAMConfigPayload: Decodable {
    let subnet: String?
    let ipRange: String?
    let gateway: String?
    let auxiliaryAddresses: [String: String]?
}

struct GuestNetworkContainerPayload: Decodable {
    let name: String
    let endpointID: String?
    let macAddress: String?
    let ipv4Address: String
    let ipv6Address: String?

    enum CodingKeys: String, CodingKey {
        case name
        case endpointID = "endpointId"
        case macAddress, ipv4Address, ipv6Address
    }
}

protocol GuestRuntimeEventConnecting: Sendable {
    func connect() async throws -> AsyncStream<GuestFrame>
}

actor PersistentEngineGuestRuntimeEventConnector: GuestRuntimeEventConnecting {
    private let engine: PersistentEngine

    init(engine: PersistentEngine) {
        self.engine = engine
    }

    func connect() async throws -> AsyncStream<GuestFrame> {
        let connection = try await engine.readyConnection()
        return await connection.events()
    }
}

actor GuestRuntimeEventMonitor {
    typealias Handler = @Sendable (GuestFrame) async -> Void
    typealias ReconnectHandler = @Sendable () async -> Void

    private let connector: any GuestRuntimeEventConnecting
    private let handler: Handler
    private let onReconnect: ReconnectHandler
    private var task: Task<Void, Never>?

    init(
        connector: any GuestRuntimeEventConnecting,
        handler: @escaping Handler,
        onReconnect: @escaping ReconnectHandler = {}
    ) {
        self.connector = connector
        self.handler = handler
        self.onReconnect = onReconnect
    }

    func start() async throws {
        guard task == nil else { return }
        let initialEvents = try await connector.connect()
        task = Task { [weak self] in
            await self?.monitor(initialEvents)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func monitor(_ initialEvents: AsyncStream<GuestFrame>) async {
        var stream = initialEvents
        while !Task.isCancelled {
            for await event in stream {
                await handler(event)
            }
            guard !Task.isCancelled else { return }
            do {
                stream = try await connector.connect()
                await onReconnect()
            } catch {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }
}

struct GuestExitCodeIndex: Sendable {
    static let maximumEntries = 4_096

    private var codes: [String: Int32] = [:]
    private var order: [String] = []

    mutating func record(id: String, code: Int32) {
        if codes.updateValue(code, forKey: id) == nil {
            order.append(id)
        }
        while order.count > Self.maximumEntries {
            codes.removeValue(forKey: order.removeFirst())
        }
    }

    func code(for id: String) -> Int32? { codes[id] }

    mutating func remove(id: String) {
        codes.removeValue(forKey: id)
        order.removeAll { $0 == id }
    }

    func recoverNotFound(id: String, error: DockerRuntimeRouteError) throws -> Int32 {
        guard case .notFound = error, let code = code(for: id) else { throw error }
        return code
    }
}

actor GuestWaitSingleFlight {
    private struct Entry {
        var continuations: [UUID: CheckedContinuation<Int32, Error>] = [:]
    }

    private var pending: [String: Entry] = [:]

    /// Deduplicates concurrent waits for one container. The first caller runs
    /// the operation inline so cancellation of its task (a stop timeout, for
    /// example) unwinds the whole chain; spawning it detached here would make
    /// every waiter ignore cancellation because `Task.value` cannot be
    /// interrupted. Late joiners suspend on their own continuation, which each
    /// can cancel independently without disturbing the shared wait.
    func run(
        id: String, operation: @escaping @Sendable () async throws -> Int32
    ) async throws -> Int32 {
        if pending[id] != nil {
            let waiter = UUID()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    pending[id]?.continuations[waiter] = continuation
                }
            } onCancel: {
                Task { await self.cancelWaiter(id: id, token: waiter) }
            }
        }
        pending[id] = Entry()
        do {
            let result = try await operation()
            finish(id: id, result: result)
            return result
        } catch {
            finish(id: id, error: error)
            throw error
        }
    }

    private func cancelWaiter(id: String, token: UUID) {
        guard let continuation = pending[id]?.continuations.removeValue(forKey: token) else { return }
        continuation.resume(throwing: CancellationError())
    }

    private func finish(id: String, result: Int32) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        for continuation in entry.continuations.values {
            continuation.resume(returning: result)
        }
    }

    private func finish(id: String, error: Error) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        for continuation in entry.continuations.values {
            continuation.resume(throwing: error)
        }
    }
}

actor GuestStartGate {
    private var waiters: [String: [UUID: CheckedContinuation<Void, Error>]] = [:]
    private var openTokens: Set<UUID> = []

    func wait(id: String) async throws {
        let token = UUID()
        openTokens.insert(token)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id, default: [:]][token] = continuation
            }
        } onCancel: {
            Task { await self.cancel(id: id, token: token) }
        }
    }

    func finish(id: String, result: Result<Void, Error>) {
        let entries = waiters.removeValue(forKey: id) ?? [:]
        for (token, continuation) in entries {
            openTokens.remove(token)
            continuation.resume(with: result)
        }
    }

    func waiterCount(id: String) -> Int { waiters[id]?.count ?? 0 }

    private func cancel(id: String, token: UUID) {
        guard openTokens.remove(token) != nil,
            let continuation = waiters[id]?.removeValue(forKey: token)
        else { return }
        if waiters[id]?.isEmpty == true { waiters.removeValue(forKey: id) }
        continuation.resume(throwing: CancellationError())
    }
}

actor GuestRemovalGate {
    private static let maximumCompletedEntries = 4_096

    private var waiters: [String: [UUID: CheckedContinuation<Int32, Error>]] = [:]
    private var openTokens: Set<UUID> = []
    private var completed: [String: Int32] = [:]
    private var completedOrder: [String] = []

    func wait(id: String) async throws -> Int32 {
        if let exitCode = completed[id] { return exitCode }
        let token = UUID()
        openTokens.insert(token)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id, default: [:]][token] = continuation
            }
        } onCancel: {
            Task { await self.cancel(id: id, token: token) }
        }
    }

    func signal(id: String, exitCode: Int32) {
        if completed[id] == nil {
            completedOrder.append(id)
        }
        completed[id] = exitCode
        while completedOrder.count > Self.maximumCompletedEntries {
            completed.removeValue(forKey: completedOrder.removeFirst())
        }
        let entries = waiters.removeValue(forKey: id) ?? [:]
        for (token, continuation) in entries {
            openTokens.remove(token)
            continuation.resume(returning: exitCode)
        }
    }

    func waiterCount(id: String) -> Int { waiters[id]?.count ?? 0 }

    private func cancel(id: String, token: UUID) {
        guard openTokens.remove(token) != nil,
            let continuation = waiters[id]?.removeValue(forKey: token)
        else { return }
        if waiters[id]?.isEmpty == true { waiters.removeValue(forKey: id) }
        continuation.resume(throwing: CancellationError())
    }
}

/// Keeps an auto-removed container alive until all attach streams have
/// consumed the exit and log frames. Docker clients can issue attach and
/// start on separate connections, so the exit event needs a small grace
/// window before it decides that no attach is coming.
actor GuestAttachmentGate {
    enum RemovalDecision: Equatable, Sendable {
        case waitForAttachment
        case waitForGrace
        case removeNow
    }

    private var active: [String: Set<UUID>] = [:]
    private var pendingRemoval: Set<String> = []

    func begin(id: String) -> UUID {
        let token = UUID()
        active[id, default: []].insert(token)
        return token
    }

    func requestRemoval(id: String) -> RemovalDecision {
        if let tokens = active[id], !tokens.isEmpty {
            pendingRemoval.insert(id)
            return .waitForAttachment
        }
        if pendingRemoval.insert(id).inserted {
            return .waitForGrace
        }
        return .removeNow
    }

    func end(id: String, token: UUID) -> Bool {
        guard var tokens = active[id], tokens.remove(token) != nil else { return false }
        guard tokens.isEmpty else {
            active[id] = tokens
            return false
        }
        active.removeValue(forKey: id)
        return pendingRemoval.remove(id) != nil
    }

    func cancel(id: String) {
        active.removeValue(forKey: id)
        pendingRemoval.remove(id)
    }

    func activeCount(id: String) -> Int { active[id]?.count ?? 0 }
}

/// Maps Docker operations to the one multiplexed guest connection. The host
/// keeps Docker-only metadata; containerd remains the authority for processes,
/// snapshots, and lifecycle state.
actor GuestRuntime: DockerRuntimeRouteBackend, DockerRuntimeLogOptionsBackend,
    DockerRuntimeImageImportBackend, DockerRuntimeImagePruneBackend,
    DockerRuntimeImageBuildOptionsBackend, DockerRuntimeInteractiveBackend,
    DockerRuntimeBuildCacheBackend
{
    private struct Metadata: Sendable {
        var name: String
        let command: [String]
        let entrypoint: [String]?
        let cmd: [String]?
        let environment: [String]
        let workingDirectory: String
        let user: String
        let hostname: String
        let labels: [String: String]
        let tty: Bool
        let attachStdin: Bool
        let openStdin: Bool
        let stdinOnce: Bool
        let autoRemove: Bool
        let stopTimeout: Int?
        let mounts: [DockerRuntimeMount]
        let readonlyRootfs: Bool
        let dns: [String]
        let dnsSearch: [String]
        let extraHosts: [String]
        let image: String
        let createdAt: Date
        var ports: [DockerRuntimePortBinding]
        var guestPorts: [Int]
        var state: EngineContainerState
        var exitCode: Int32?
        var health: DockerRuntimeHealth
        let healthcheck: DockerRuntimeHealthcheck?
        var restartPolicy: DockerRuntimeRestartPolicy
        var restartCount: Int
        var resources: DockerRuntimeResources
        let stopSignal: String
        let networkMode: String
    }

    private let engine: PersistentEngine
    private let portPublisher: GuestPortPublicationManager
    private let broadcaster: EventBroadcaster?
    private var metadata: [String: Metadata] = [:]
    private var manuallyStopped: Set<String> = []
    private var execs: [String: DockerRuntimeExecCreate] = [:]
    private var starting: Set<String> = []
    private let starts = GuestStartGate()
    private var pendingPublications: Set<String> = []
    private var eventMonitor: GuestRuntimeEventMonitor?
    private var reservedGuestPorts: Set<Int> = []
    private var exitCodes = GuestExitCodeIndex()
    private let waits = GuestWaitSingleFlight()
    private let removals = GuestRemovalGate()
    private let attachments = GuestAttachmentGate()

    init(
        engine: PersistentEngine,
        portPublisher: GuestPortPublicationManager,
        broadcaster: EventBroadcaster? = nil
    ) {
        self.engine = engine
        self.portPublisher = portPublisher
        self.broadcaster = broadcaster
    }

    func startEventMonitor() async throws {
        guard eventMonitor == nil else { return }
        try await restoreRuntimeState()
        let monitor = GuestRuntimeEventMonitor(
            connector: PersistentEngineGuestRuntimeEventConnector(engine: engine)
        ) { [weak self] event in
            await self?.handle(event: event)
        } onReconnect: { [weak self] in
            try? await self?.restoreRuntimeState()
        }
        try await monitor.start()
        eventMonitor = monitor
        try await restoreRuntimeState()
    }

    func stopEventMonitor() async {
        await eventMonitor?.stop()
        eventMonitor = nil
    }

    func pullImage(
        reference: String, platform: String?, auth: DockerRegistryAuth?
    ) async throws -> DockerRuntimeImage {
        let guestReference = Self.normalizedRegistryReference(reference)
        var requestPayload: [String: JSONValue] = [
            "reference": .string(guestReference), "snapshotter": .string("overlayfs"),
        ]
        if let platform, !platform.isEmpty { requestPayload["platform"] = .string(platform) }
        if let username = auth?.username, !username.isEmpty {
            requestPayload["username"] = .string(username)
            if let secret = auth?.password ?? auth?.identitytoken, !secret.isEmpty {
                requestPayload["secret"] = .string(secret)
            }
        }
        let response = try await request("image.pull", requestPayload)
        let payload: GuestImagePayload = try decode(response)
        await broadcaster?.broadcast(
            DockerEvent.make(
                type: "image", action: "pull", actorID: payload.digest,
                attributes: ["name": payload.name]
            )
        )
        return DockerRuntimeImage(reference: payload.name, digest: payload.digest)
    }

    func listImages() async throws -> [DockerRuntimeImage] {
        let payload: GuestImageListPayload = try decode(try await request("image.list", [:]))
        return payload.images.map(Self.dockerImage)
    }

    func systemDataUsage() async throws -> (layersSize: Int64, buildCache: [GuestBuildCacheRecord]) {
        let payload: GuestSystemDfPayload = try decode(try await request("system.df", [:]))
        return (payload.layersSize, payload.buildCache ?? [])
    }

    func pruneBuildCache(all: Bool) async throws -> GuestBuilderPrunePayload {
        try decode(try await request("builder.prune", ["all": .bool(all)]))
    }

    func inspectImage(reference: String) async throws -> DockerRuntimeImage {
        let response = try await request(
            "image.inspect", ["reference": .string(Self.normalizedRegistryReference(reference))]
        )
        return Self.dockerImage(try decode(response, as: GuestImageDetailPayload.self))
    }

    func deleteImage(reference: String, force: Bool) async throws -> DockerRuntimeImageDelete {
        let response = try await request(
            "image.delete",
            ["reference": .string(Self.normalizedRegistryReference(reference)), "force": .bool(force)]
        )
        return Self.dockerImageDelete(try decode(response, as: GuestImageDeletePayload.self))
    }

    func pruneImages(all: Bool) async throws -> DockerRuntimeImageDelete {
        try await pruneImages(all: all, filters: [:])
    }

    func pruneImages(all: Bool, filters: [String: [String]]) async throws -> DockerRuntimeImageDelete {
        var payload: [String: JSONValue] = ["all": .bool(all)]
        if !filters.isEmpty {
            payload["filters"] = .object(
                filters.mapValues { .array($0.map(JSONValue.string)) }
            )
        }
        let response = try await request("image.prune", payload)
        return Self.dockerImageDelete(try decode(response, as: GuestImageDeletePayload.self))
    }

    func tagImage(source: String, target: String) async throws {
        _ = try await request(
            "image.tag",
            [
                "source": .string(Self.normalizedRegistryReference(source)),
                "target": .string(Self.normalizedRegistryReference(target)),
            ]
        )
    }

    func pushImage(
        source: String, target: String, platform: String?, auth: DockerRegistryAuth?
    ) async throws -> DockerRuntimeImage {
        var payload: [String: JSONValue] = [
            "source": .string(Self.normalizedRegistryReference(source)),
            "target": .string(Self.normalizedRegistryReference(target)),
        ]
        if let platform, !platform.isEmpty { payload["platform"] = .string(platform) }
        if let username = auth?.username, !username.isEmpty {
            payload["username"] = .string(username)
            if let secret = auth?.password ?? auth?.identitytoken, !secret.isEmpty {
                payload["secret"] = .string(secret)
            }
        }
        let response = try await request("image.push", payload)
        let result: GuestImagePayload = try decode(response)
        return DockerRuntimeImage(reference: result.name, digest: result.digest)
    }

    func exportImages(
        references: [String]
    ) async throws -> (firstChunk: Data, remaining: AsyncThrowingStream<Data, Error>) {
        try await streamRequestWithFirstChunk(
            method: "image.export",
            payload: ["references": .array(references.map { .string(Self.normalizedRegistryReference($0)) })]
        )
    }

    func importImages(data: Data) async throws -> [DockerRuntimeImage] {
        try await importImages(data: data, reference: nil)
    }

    func importImages(data: Data, reference: String?) async throws -> [DockerRuntimeImage] {
        var requestPayload: [String: JSONValue] = [:]
        if let reference, !reference.isEmpty {
            requestPayload["reference"] = .string(Self.normalizedRegistryReference(reference))
        }
        let response = try await requestWithInput(
            "image.import",
            requestPayload,
            data: data
        )
        let responsePayload: GuestImageImportPayload = try decode(response)
        return responsePayload.images.map { DockerRuntimeImage(reference: $0.name, digest: $0.digest) }
    }

    func buildImage(context: Data, dockerfile: String, tags: [String]) async throws -> DockerRuntimeImage {
        try await buildImage(context: context, dockerfile: dockerfile, tags: tags, buildArgs: [:])
    }

    func buildImage(
        context: Data, dockerfile: String, tags: [String], buildArgs: [String: String]
    ) async throws -> DockerRuntimeImage {
        var payload: [String: JSONValue] = [
            "dockerfile": .string(dockerfile),
            "tags": .array(tags.map(JSONValue.string)),
        ]
        if !buildArgs.isEmpty {
            payload["buildArgs"] = .object(buildArgs.mapValues(JSONValue.string))
        }
        let response = try await requestWithInput(
            "image.build",
            payload,
            data: context
        )
        let result: GuestImageBuildPayload = try decode(response)
        return DockerRuntimeImage(reference: result.image.name, digest: result.image.digest)
    }

    func commitImage(
        container: String,
        repository: String?,
        tag: String?,
        comment: String?,
        author: String?,
        pause: Bool,
        changes: String?
    ) async throws -> DockerRuntimeImage {
        let resolved = try await resolve(container)
        var payload: [String: JSONValue] = [
            "container": .string(resolved),
            "pause": .bool(pause),
        ]
        if let repository, !repository.isEmpty {
            payload["repository"] = .string(Self.normalizedRegistryReference(repository))
        }
        if let tag, !tag.isEmpty { payload["tag"] = .string(tag) }
        if let comment, !comment.isEmpty { payload["comment"] = .string(comment) }
        if let author, !author.isEmpty { payload["author"] = .string(author) }
        if let changes, !changes.isEmpty { payload["changes"] = .string(changes) }
        let response = try await request("image.commit", payload)
        let result: GuestImagePayload = try decode(response)
        return DockerRuntimeImage(reference: result.name, digest: result.digest)
    }

    func createContainer(_ request: DockerRuntimeContainerCreate) async throws -> DockerRuntimeContainer {
        let id = Self.makeID()
        let containerName = request.name.map(Self.normalizedContainerName) ?? id
        if let name = request.name, !name.isEmpty {
            try ensureNameAvailable(name)
        }
        guard
            let allocatedGuestPorts = Self.lowestAvailableGuestPorts(
                count: request.ports.count,
                range: PublishedPortProxyRange.ports,
                excluding: reservedGuestPorts
            )
        else {
            throw DockerRuntimeRouteError.conflict("published guest port range is exhausted")
        }
        reservedGuestPorts.formUnion(allocatedGuestPorts)
        var committedReservation = false
        defer {
            if !committedReservation {
                reservedGuestPorts.subtract(allocatedGuestPorts)
            }
        }
        let hostSource = try await vmnetHostSource(required: !request.ports.isEmpty)
        let requestedPorts = zip(request.ports, allocatedGuestPorts).map { port, guestPort in
            JSONValue.object([
                "containerPort": .number(Double(port.containerPort)),
                "guestPort": .number(Double(guestPort)),
                "protocol": .string(port.proto),
                "hostSource": .string(hostSource),
            ])
        }
        var payload: [String: JSONValue] = [
            "id": .string(id),
            "image": .string(Self.normalizedRegistryReference(request.image)),
            "args": .array(request.command.map(JSONValue.string)),
            "env": .array(request.environment.map(JSONValue.string)),
            "labels": .object(request.labels.mapValues(JSONValue.string)),
            "hostname": request.hostname.map(JSONValue.string) ?? .string(id.prefix(12).description),
            "readonlyRootfs": .bool(request.readonlyRootfs),
            "attachStdin": .bool(request.attachStdin),
            "openStdin": .bool(request.openStdin),
            "stdinOnce": .bool(request.stdinOnce),
            "autoRemove": .bool(request.autoRemove),
            "snapshotter": .string("overlayfs"),
            "runtime": .string("io.containerd.runc.v2"),
            "runtimeBinary": .string("/usr/bin/crun"),
            "network": .object(["mode": .string(request.networkMode)]),
            "publishedPorts": .array(requestedPorts),
            "mounts": .array(
                request.mounts.map {
                    .object([
                        "source": .string($0.source), "target": .string($0.target),
                        "type": .string($0.type), "readonly": .bool($0.readOnly),
                        "options": .array($0.options.map(JSONValue.string)),
                    ])
                }
            ),
            "metadata": .object([
                "name": .string(containerName),
                "args": .array(request.command.map(JSONValue.string)),
                "entrypoint": request.entrypoint.map { .array($0.map(JSONValue.string)) } ?? .null,
                "cmd": request.cmd.map { .array($0.map(JSONValue.string)) } ?? .null,
                "env": .array(request.environment.map(JSONValue.string)),
                "cwd": .string(request.workingDirectory ?? ""),
                "user": .string(request.user ?? ""),
                "hostname": .string(request.hostname ?? ""),
                "labels": .object(request.labels.mapValues(JSONValue.string)),
                "terminal": .bool(request.tty),
                "attachStdin": .bool(request.attachStdin),
                "openStdin": .bool(request.openStdin),
                "stdinOnce": .bool(request.stdinOnce),
                "autoRemove": .bool(request.autoRemove),
                "mounts": .array(
                    request.mounts.map {
                        .object([
                            "source": .string($0.source), "target": .string($0.target),
                            "type": .string($0.type), "readonly": .bool($0.readOnly),
                            "options": .array($0.options.map(JSONValue.string)),
                        ])
                    }
                ),
                "readonlyRootfs": .bool(request.readonlyRootfs),
                "dns": .array(request.dns.map(JSONValue.string)),
                "dnsSearch": .array(request.dnsSearch.map(JSONValue.string)),
                "extraHosts": .array(request.extraHosts.map(JSONValue.string)),
                "stopTimeout": request.stopTimeout.map { .number(Double($0)) } ?? .null,
                "portBindings": .array(request.ports.map(Self.portBindingJSON)),
                "healthcheck": request.healthcheck.map(Self.healthcheckJSON) ?? .null,
                "restartPolicy": .object([
                    "name": .string(request.restartPolicy.name),
                    "maximumRetryCount": .number(Double(request.restartPolicy.maximumRetryCount)),
                ]),
                "restartCount": .number(Double(request.restartCount)),
                "resources": Self.resourcesJSON(request.resources),
                "networkMode": .string(request.networkMode),
            ]),
        ]
        if let entrypoint = request.entrypoint {
            payload["entrypoint"] = .array(entrypoint.map(JSONValue.string))
        }
        if let cmd = request.cmd {
            payload["cmd"] = .array(cmd.map(JSONValue.string))
        }
        if let cwd = request.workingDirectory, !cwd.isEmpty { payload["cwd"] = .string(cwd) }
        if let user = request.user, !user.isEmpty { payload["user"] = .string(user) }
        if let signal = request.stopSignal, !signal.isEmpty { payload["stopSignal"] = .string(signal) }
        if !request.dns.isEmpty { payload["dns"] = .array(request.dns.map(JSONValue.string)) }
        if !request.dnsSearch.isEmpty {
            payload["dnsSearch"] = .array(request.dnsSearch.map(JSONValue.string))
        }
        if !request.extraHosts.isEmpty {
            payload["extraHosts"] = .array(request.extraHosts.map(JSONValue.string))
        }
        payload["healthcheck"] = request.healthcheck.map(Self.healthcheckJSON) ?? .null
        payload["restartPolicy"] = .object([
            "name": .string(request.restartPolicy.name),
            "maximumRetryCount": .number(Double(request.restartPolicy.maximumRetryCount)),
        ])
        payload["restartCount"] = .number(Double(request.restartCount))
        payload["resources"] = Self.resourcesJSON(request.resources)
        let response = try await self.request(
            "container.create",
            payload,
            memoryTarget: request.ports.isEmpty
                ? nil
                : PersistentEngine.publishedNetworkMemoryBytes
        )
        let guest: GuestContainerPayload = try decode(response)
        metadata[id] = Metadata(
            name: containerName,
            command: request.command,
            entrypoint: request.entrypoint,
            cmd: request.cmd,
            environment: request.environment,
            workingDirectory: request.workingDirectory ?? "",
            user: request.user ?? "",
            hostname: request.hostname ?? "",
            labels: request.labels,
            tty: request.tty,
            attachStdin: request.attachStdin,
            openStdin: request.openStdin,
            stdinOnce: request.stdinOnce,
            autoRemove: request.autoRemove,
            stopTimeout: request.stopTimeout,
            mounts: request.mounts,
            readonlyRootfs: request.readonlyRootfs,
            dns: request.dns,
            dnsSearch: request.dnsSearch,
            extraHosts: request.extraHosts,
            image: guest.container.image,
            createdAt: guest.container.createdAt,
            ports: request.ports,
            guestPorts: allocatedGuestPorts,
            state: .created,
            exitCode: nil,
            health: Self.dockerHealth(guest.container.health) ?? .init(),
            healthcheck: request.healthcheck,
            restartPolicy: request.restartPolicy,
            restartCount: request.restartCount,
            resources: request.resources,
            stopSignal: request.stopSignal ?? "",
            networkMode: request.networkMode
        )
        manuallyStopped.remove(id)
        committedReservation = true
        await broadcastContainer("create", id: id)
        if !request.ports.isEmpty {
            // Keep the published-container reserve across Docker's separate
            // create and start calls. Without this reservation, the idle
            // reclaim timer can run between them and make start pay the
            // memory-restore cost on the readiness path.
            try? await engine.retainMemoryTarget(
                id: id, bytes: PersistentEngine.publishedNetworkMemoryBytes
            )
        }
        return dockerContainer(guest.container)
    }

    func updateContainer(id: String, update: DockerRuntimeContainerUpdate) async throws -> [String] {
        let resolved = try await resolve(id)
        var payload: [String: JSONValue] = ["id": .string(resolved)]
        if let value = update.nanoCPUs {
            payload["nanoCPUs"] = .number(Double(value))
        }
        if let value = update.cpuShares {
            payload["cpuShares"] = .number(Double(value))
        }
        if let value = update.memory {
            payload["memory"] = .number(Double(value))
        }
        if let value = update.memorySwap {
            payload["memorySwap"] = .number(Double(value))
        }
        if let value = update.memoryReservation {
            payload["memoryReservation"] = .number(Double(value))
        }
        if let value = update.cpuPeriod {
            payload["cpuPeriod"] = .number(Double(value))
        }
        if let value = update.cpuQuota {
            payload["cpuQuota"] = .number(Double(value))
        }
        if let value = update.cpusetCpus {
            payload["cpusetCpus"] = .string(value)
        }
        if let value = update.cpusetMems {
            payload["cpusetMems"] = .string(value)
        }
        if let value = update.pidsLimit {
            payload["pidsLimit"] = .number(Double(value))
        }
        if let policy = update.restartPolicy {
            payload["restartPolicy"] = .object([
                "name": .string(policy.name),
                "maximumRetryCount": .number(Double(policy.maximumRetryCount)),
            ])
        }
        let response = try await request("container.update", payload)
        if var resources = metadata[resolved]?.resources {
            resources = DockerRuntimeResources(
                memory: update.memory ?? resources.memory,
                memorySwap: update.memorySwap ?? resources.memorySwap,
                memoryReservation: update.memoryReservation ?? resources.memoryReservation,
                nanoCPUs: update.nanoCPUs ?? resources.nanoCPUs,
                cpuShares: update.cpuShares ?? resources.cpuShares,
                cpuPeriod: update.cpuPeriod ?? resources.cpuPeriod,
                cpuQuota: update.cpuQuota ?? resources.cpuQuota,
                cpusetCpus: update.cpusetCpus ?? resources.cpusetCpus,
                cpusetMems: update.cpusetMems ?? resources.cpusetMems,
                pidsLimit: update.pidsLimit ?? resources.pidsLimit
            )
            metadata[resolved]?.resources = resources
        }
        if let policy = update.restartPolicy {
            metadata[resolved]?.restartPolicy = policy
        }
        return (try? decode(response, as: GuestContainerUpdatePayload.self).warnings) ?? []
    }

    static func lowestAvailableGuestPorts(
        count: Int,
        range: ClosedRange<Int>,
        excluding reserved: Set<Int>
    ) -> [Int]? {
        guard count >= 0 else { return nil }
        let available = range.lazy.filter { !reserved.contains($0) }.prefix(count)
        guard available.count == count else { return nil }
        return Array(available)
    }

    func startContainer(id: String) async throws {
        let resolved = try await resolve(id)
        manuallyStopped.remove(resolved)
        if starting.contains(resolved) {
            try await starts.wait(id: resolved)
            return
        }
        starting.insert(resolved)
        defer { starting.remove(resolved) }
        let meta = metadata[resolved]
        if let state = meta?.state, !Self.requiresStart(state) {
            guard
                Self.requiresPortPublicationRetry(
                    state: state, publicationPending: pendingPublications.contains(resolved)
                ), let meta
            else { return }
            do {
                try await publishPorts(id: resolved, metadata: meta, guestPorts: meta.guestPorts)
            } catch {
                await starts.finish(id: resolved, result: .failure(error))
                throw error
            }
            await starts.finish(id: resolved, result: .success(()))
            try? await engine.retainMemoryTarget(
                id: resolved, bytes: PersistentEngine.publishedNetworkMemoryBytes
            )
            return
        }
        let hostSource = try await vmnetHostSource(required: meta?.ports.isEmpty == false)
        let confirmedPorts = zip(meta?.ports ?? [], meta?.guestPorts ?? []).map { binding, guestPort in
            JSONValue.object([
                "containerPort": .number(Double(binding.containerPort)),
                "guestPort": .number(Double(guestPort)),
                "protocol": .string(binding.proto),
                "hostSource": .string(hostSource),
            ])
        }
        var reservedBindings: [DockerRuntimePortBinding]?
        do {
            if let meta, !meta.ports.isEmpty {
                let published = try await portPublisher.publish(
                    containerID: resolved,
                    bindings: meta.ports,
                    guestPorts: meta.guestPorts
                )
                metadata[resolved]?.ports = published
                pendingPublications.insert(resolved)
                reservedBindings = published
            }
            exitCodes.remove(id: resolved)
            metadata[resolved]?.state = .created
            metadata[resolved]?.exitCode = nil
            var startPayload: [String: JSONValue] = [
                "id": .string(resolved), "publishedPorts": .array(confirmedPorts),
            ]
            if let reservedBindings, !reservedBindings.isEmpty {
                startPayload["portBindings"] = .array(
                    reservedBindings.map(Self.portBindingJSON)
                )
            }
            let response = try await request(
                "container.start",
                startPayload,
                memoryTarget: meta?.ports.isEmpty == false
                    ? PersistentEngine.publishedNetworkMemoryBytes
                    : nil
            )
            _ = try decode(response, as: GuestContainerPayload.self).container
            if metadata[resolved]?.state != .exited {
                metadata[resolved]?.state = .running
            }
            if reservedBindings != nil, metadata[resolved]?.state == .running {
                pendingPublications.remove(resolved)
            }
            if meta?.ports.isEmpty == false, metadata[resolved]?.state == .running {
                try? await engine.retainMemoryTarget(
                    id: resolved, bytes: PersistentEngine.publishedNetworkMemoryBytes
                )
            }
        } catch {
            if reservedBindings != nil {
                try? await portPublisher.remove(containerID: resolved)
                pendingPublications.remove(resolved)
            }
            await starts.finish(id: resolved, result: .failure(error))
            throw error
        }
        await starts.finish(id: resolved, result: .success(()))
        await broadcastContainer("start", id: resolved)
    }

    func pauseContainer(id: String) async throws {
        let resolved = try await resolve(id)
        _ = try await request("container.pause", ["id": .string(resolved)])
        metadata[resolved]?.state = .paused
        await broadcastContainer("pause", id: resolved)
    }

    func resumeContainer(id: String) async throws {
        let resolved = try await resolve(id)
        _ = try await request("container.resume", ["id": .string(resolved)])
        metadata[resolved]?.state = .running
        await broadcastContainer("unpause", id: resolved)
    }

    func resizeContainer(id: String, width: UInt32, height: UInt32) async throws {
        let resolved = try await resolve(id)
        _ = try await request(
            "container.resize",
            [
                "id": .string(resolved),
                "width": .number(Double(width)),
                "height": .number(Double(height)),
            ]
        )
    }

    func renameContainer(id: String, name: String) async throws {
        let resolved = try await resolve(id)
        guard metadata.values.filter({ $0.name == name }).isEmpty else {
            throw DockerRuntimeRouteError.conflict(
                "Conflict. The container name /\(name) is already in use."
            )
        }
        _ = try await request(
            "container.metadata.update",
            ["id": .string(resolved), "name": .string(name)]
        )
        metadata[resolved]?.name = name
        await broadcastContainer("rename", id: resolved, extra: ["name": name])
    }

    static func requiresPortPublicationRetry(
        state: EngineContainerState, publicationPending: Bool
    ) -> Bool {
        state == .running && publicationPending
    }

    private func publishPorts(id: String, metadata: Metadata, guestPorts: [Int]) async throws {
        let published = try await portPublisher.publish(
            containerID: id,
            bindings: metadata.ports,
            guestPorts: guestPorts
        )
        self.metadata[id]?.ports = published
        pendingPublications.remove(id)
        do {
            try await persistPortBindings(containerID: id, bindings: published)
        } catch {
            try await portPublisher.remove(containerID: id)
            pendingPublications.insert(id)
            throw error
        }
    }

    func killContainer(id: String, signal: UInt32) async throws {
        let resolved = try await resolve(id)
        _ = try await request(
            "container.kill", ["id": .string(resolved), "signal": .number(Double(signal))]
        )
        manuallyStopped.insert(resolved)
        await broadcastContainer(
            "kill", id: resolved, extra: ["signal": String(signal)]
        )
    }

    func waitContainer(id: String, condition: ContainerWaitCondition) async throws -> Int32 {
        if condition == .nextExit {
            exitCodes.remove(id: id)
        } else if condition != .removed, let code = exitCodes.code(for: id) {
            return code
        }
        let resolved: String
        do {
            resolved = try await resolve(id)
        } catch let error as DockerRuntimeRouteError {
            guard condition != .removed else { throw error }
            return try exitCodes.recoverNotFound(id: id, error: error)
        }
        if condition == .removed {
            return try await removals.wait(id: resolved)
        }
        if condition != .removed, let code = exitCodes.code(for: resolved) { return code }
        if let code = Self.cachedWaitExitCode(
            state: metadata[resolved]?.state,
            exitCode: metadata[resolved]?.exitCode,
            condition: condition
        ) {
            exitCodes.record(id: resolved, code: code)
            return code
        }
        if metadata[resolved]?.state == .created {
            try await starts.wait(id: resolved)
        }
        let exitCode = try await waits.run(id: resolved) { [self] in
            try await performGuestWait(id: resolved, condition: condition)
        }
        if metadata[resolved]?.autoRemove == true {
            try await portPublisher.remove(containerID: resolved)
        }
        return exitCode
    }

    func cachedWaitContainer(id: String, condition: ContainerWaitCondition) async throws -> Int32? {
        guard condition == .notRunning else { return nil }
        if let code = exitCodes.code(for: id) {
            return code
        }
        let resolved = try await resolve(id)
        if let code = exitCodes.code(for: resolved) {
            return code
        }
        guard
            let code = Self.cachedWaitExitCode(
                state: metadata[resolved]?.state,
                exitCode: metadata[resolved]?.exitCode,
                condition: condition
            )
        else {
            return nil
        }
        exitCodes.record(id: resolved, code: code)
        return code
    }

    // The wait route must validate existence before committing streaming
    // headers, but a full inspect would resolve the container and issue an
    // unnecessary guest inspect request before wait resolves it again.
    func validateContainer(id: String) async throws {
        _ = try await resolve(id)
    }

    private func performGuestWait(id: String, condition: ContainerWaitCondition) async throws -> Int32 {
        let response: GuestFrame
        do {
            response = try await request(
                "container.wait",
                [
                    "id": .string(id),
                    "condition": .string(condition.rawValue),
                ]
            )
        } catch let error as DockerRuntimeRouteError {
            return try exitCodes.recoverNotFound(id: id, error: error)
        }
        let exitCode: Int32
        if let code = response.exitCode {
            exitCode = code
        } else {
            exitCode = Int32(try decode(response, as: GuestExitPayload.self).exitCode)
        }
        // The guest wait response is sent after its log copier drains. Publish
        // the result before the single-flight task completes and is removed.
        exitCodes.record(id: id, code: exitCode)
        metadata[id]?.state = .exited
        metadata[id]?.exitCode = exitCode
        await engine.releaseMemoryTarget(id: id)
        return exitCode
    }

    func containerAutoRemove(id: String) async throws -> Bool {
        let resolved = try await resolve(id)
        return metadata[resolved]?.autoRemove == true
    }

    func deleteContainer(id: String, force: Bool, removeVolumes: Bool) async throws {
        let resolved = try await resolve(id)
        await attachments.cancel(id: resolved)
        let hasPublishedPorts = metadata[resolved]?.ports.isEmpty == false
        let exitCode = metadata[resolved]?.exitCode ?? exitCodes.code(for: resolved) ?? 0
        _ = try await request(
            "container.delete",
            ["id": .string(resolved), "force": .bool(force), "snapshot": .bool(true)]
        )
        await starts.finish(
            id: resolved,
            result: .failure(DockerRuntimeRouteError.notFound("container \(resolved)"))
        )
        await engine.releaseMemoryTarget(id: resolved)
        if hasPublishedPorts {
            try await portPublisher.remove(containerID: resolved)
        }
        releaseGuestPorts(containerID: resolved)
        pendingPublications.remove(resolved)
        manuallyStopped.remove(resolved)
        metadata.removeValue(forKey: resolved)
        await removals.signal(id: resolved, exitCode: exitCode)
        await broadcaster?.broadcast(
            DockerEvent.simpleEvent(
                id: resolved, type: "container", status: "destroy",
                image: "", name: resolved
            )
        )
    }

    func inspectContainer(id: String) async throws -> DockerRuntimeContainer {
        try await inspectContainer(id: id, includeSize: false)
    }

    func inspectContainer(
        id: String, includeSize: Bool
    ) async throws -> DockerRuntimeContainer {
        let resolved = try await resolve(id)
        // The runtime owns complete Docker metadata for containers created in
        // this process. A normal inspect does not need guest filesystem usage,
        // so use that metadata without paying for a guest RPC. Recovery and
        // ?size=1 still use the guest as the source of truth.
        if !includeSize, let cached = cachedContainer(id: resolved) {
            return cached
        }
        var payload: [String: JSONValue] = ["id": .string(resolved)]
        if includeSize { payload["size"] = .bool(true) }
        let response = try await request("container.inspect", payload)
        return dockerContainer(try decode(response, as: GuestContainerPayload.self).container)
    }

    static func requiresStart(_ state: EngineContainerState) -> Bool {
        state != .running
    }

    static func cachedWaitExitCode(
        state: EngineContainerState?, exitCode: Int32?, condition: ContainerWaitCondition
    ) -> Int32? {
        guard condition == .notRunning, state == .exited else { return nil }
        return exitCode
    }

    func listContainers(showAll: Bool) async throws -> [DockerRuntimeContainer] {
        let response = try await request("container.list", [:])
        let payload: GuestContainerListPayload = try decode(response)
        return payload.containers.compactMap { container in
            guard showAll || container.status == "running" else { return nil }
            return dockerContainer(container)
        }
    }

    func listNetworks() async throws -> [DockerRuntimeNetwork] {
        let response = try await request("network.list", [:])
        let payload: GuestNetworkListPayload = try decode(response)
        return payload.networks.map(Self.dockerNetwork)
    }

    func inspectNetwork(id: String) async throws -> DockerRuntimeNetwork {
        let networks = try await listNetworks()
        guard let network = networks.first(where: { $0.id == id || $0.name == id }) else {
            throw DockerRuntimeRouteError.notFound("No such network: \(id)")
        }
        return network
    }

    func deleteNetwork(id: String) async throws {
        _ = try await request("network.delete", ["id": .string(id)])
    }

    func createNetwork(
        name: String,
        driver: String?,
        scope: String?,
        enableIPv4: Bool?,
        enableIPv6: Bool?,
        internalNetwork: Bool?,
        attachable: Bool?,
        ingress: Bool?,
        ipam: DockerRuntimeNetworkIPAM?,
        options: [String: String]?,
        labels: [String: String]?
    ) async throws -> DockerRuntimeNetwork {
        var payload: [String: JSONValue] = ["name": .string(name)]
        if let driver { payload["driver"] = .string(driver) }
        if let scope { payload["scope"] = .string(scope) }
        if let enableIPv4 { payload["enableIPv4"] = .bool(enableIPv4) }
        if let enableIPv6 { payload["enableIPv6"] = .bool(enableIPv6) }
        if let internalNetwork { payload["internal"] = .bool(internalNetwork) }
        if let attachable { payload["attachable"] = .bool(attachable) }
        if let ingress { payload["ingress"] = .bool(ingress) }
        if let options { payload["options"] = .object(options.mapValues(JSONValue.string)) }
        if let labels { payload["labels"] = .object(labels.mapValues(JSONValue.string)) }
        if let ipam {
            payload["ipam"] = .object([
                "driver": ipam.driver.map(JSONValue.string) ?? .string("default"),
                "config": .array(
                    ipam.config.map { config in
                        .object([
                            "subnet": config.subnet.map(JSONValue.string) ?? .null,
                            "ipRange": config.ipRange.map(JSONValue.string) ?? .null,
                            "gateway": config.gateway.map(JSONValue.string) ?? .null,
                            "auxiliaryAddresses": config.auxiliaryAddresses.map {
                                .object($0.mapValues(JSONValue.string))
                            } ?? .null,
                        ])
                    }),
            ])
        }
        let response = try await request("network.create", payload)
        return Self.dockerNetwork(try decode(response, as: GuestNetworkCreatePayload.self).network)
    }

    func connectNetwork(
        id: String,
        containerID: String,
        ipv4Address: String?,
        ipv6Address: String?
    ) async throws {
        try await connectNetwork(
            id: id,
            containerID: containerID,
            aliases: nil,
            ipv4Address: ipv4Address,
            ipv6Address: ipv6Address
        )
    }

    func connectNetwork(
        id: String,
        containerID: String,
        aliases: [String]?,
        ipv4Address: String?,
        ipv6Address: String?
    ) async throws {
        let resolved = try await resolve(containerID)
        var payload: [String: JSONValue] = [
            "networkId": .string(id),
            "containerId": .string(resolved),
        ]
        if let aliases, !aliases.isEmpty {
            payload["aliases"] = .array(aliases.map(JSONValue.string))
        }
        if let ipv4Address { payload["ipv4Address"] = .string(ipv4Address) }
        if let ipv6Address { payload["ipv6Address"] = .string(ipv6Address) }
        _ = try await request("network.connect", payload)
    }

    func disconnectNetwork(id: String, containerID: String, force: Bool) async throws {
        let resolved = try await resolve(containerID)
        _ = try await request(
            "network.disconnect",
            [
                "networkId": .string(id),
                "containerId": .string(resolved),
                "force": .bool(force),
            ]
        )
    }

    func topContainer(id: String, psArguments: [String]) async throws -> DockerRuntimeTop {
        let resolved = try await resolve(id)
        let response = try await request(
            "container.top",
            ["id": .string(resolved), "args": .array(psArguments.map(JSONValue.string))]
        )
        let payload = try decode(response, as: GuestTopPayload.self)
        return DockerRuntimeTop(Titles: payload.titles, Processes: payload.processes)
    }

    func statsContainer(id: String) async throws -> DockerRuntimeStats {
        let resolved = try await resolve(id)
        let response = try await request("container.stats", ["id": .string(resolved)])
        let payload = try decode(response, as: GuestStatsPayload.self)
        let cpuUsage = DockerRuntimeStats.CPUUsage(
            total_usage: payload.cpuStats.cpuUsage.totalUsage,
            usage_in_kernelmode: payload.cpuStats.cpuUsage.inKernelMode,
            usage_in_usermode: payload.cpuStats.cpuUsage.inUserMode
        )
        let throttling = DockerRuntimeStats.ThrottlingData(
            throttled_periods: payload.cpuStats.throttlingData.throttledPeriods,
            throttled_time: payload.cpuStats.throttlingData.throttledTime,
            throttling_periods: payload.cpuStats.throttlingData.throttlingPeriods
        )
        func cpu(_ stats: GuestStatsPayload.CPUStats) -> DockerRuntimeStats.CPUStats {
            DockerRuntimeStats.CPUStats(
                cpu_usage: cpuUsage,
                system_cpu_usage: stats.systemCPUUsage,
                online_cpus: stats.onlineCPUs,
                throttling_data: throttling
            )
        }
        var networks: [String: DockerRuntimeStats.NetworkStats]?
        if let raw = payload.networks {
            networks = raw.mapValues { value in
                guard case .object(let fields) = value else {
                    return DockerRuntimeStats.NetworkStats(
                        rx_bytes: 0, rx_packets: 0, rx_errors: 0, rx_dropped: 0,
                        tx_bytes: 0, tx_packets: 0, tx_errors: 0, tx_dropped: 0
                    )
                }
                func number(_ key: String) -> UInt64 {
                    guard case .number(let n) = fields[key] else { return 0 }
                    return UInt64(n)
                }
                return DockerRuntimeStats.NetworkStats(
                    rx_bytes: number("rx_bytes"),
                    rx_packets: number("rx_packets"),
                    rx_errors: number("rx_errors"),
                    rx_dropped: number("rx_dropped"),
                    tx_bytes: number("tx_bytes"),
                    tx_packets: number("tx_packets"),
                    tx_errors: number("tx_errors"),
                    tx_dropped: number("tx_dropped")
                )
            }
        }
        return DockerRuntimeStats(
            id: payload.id,
            read: payload.read,
            preread: payload.preread,
            cpu_stats: cpu(payload.cpuStats),
            precpu_stats: cpu(payload.precpuStats),
            memory_stats: DockerRuntimeStats.MemoryStats(
                usage: payload.memoryStats.usage,
                limit: payload.memoryStats.limit,
                stats: payload.memoryStats.stats.isEmpty ? nil : payload.memoryStats.stats
            ),
            networks: networks,
            blkio_stats: DockerRuntimeStats.BlkioStats(
                io_service_bytes_recursive: payload.blkioEntries.map {
                    .init(major: $0.major, minor: $0.minor, op: $0.op, value: $0.value)
                }
            ),
            pids_stats: DockerRuntimeStats.PidsStats(current: payload.pidsCurrent)
        )
    }

    func exportContainer(id: String) async throws -> AsyncThrowingStream<Data, Error> {
        let resolved = try await resolve(id)
        return try await streamRequest(method: "container.export", payload: ["id": .string(resolved)])
    }

    func archiveContainer(id: String, path: String) async throws -> AsyncThrowingStream<Data, Error> {
        let resolved = try await resolve(id)
        return try await streamRequest(
            method: "container.archive",
            payload: ["id": .string(resolved), "path": .string(path)]
        )
    }

    func archiveContainerInfo(id: String, path: String) async throws -> DockerRuntimeArchivePath {
        let resolved = try await resolve(id)
        let response = try await request(
            "container.archive.info",
            ["id": .string(resolved), "path": .string(path)]
        )
        let payload = try decode(response, as: GuestArchivePathPayload.self)
        return DockerRuntimeArchivePath(
            name: payload.name,
            size: payload.size,
            mode: payload.mode,
            modifiedAt: payload.modifiedAt,
            linkTarget: payload.linkTarget ?? ""
        )
    }

    func putContainerArchive(
        id: String, path: String, data: Data, noOverwriteDirNonDir: Bool
    ) async throws {
        let resolved = try await resolve(id)
        _ = try await requestWithInput(
            "container.archive.put",
            [
                "id": .string(resolved),
                "path": .string(path),
                "noOverwriteDirNonDir": .bool(noOverwriteDirNonDir),
            ],
            data: data
        )
    }

    func containerChanges(id: String) async throws -> [DockerRuntimeContainerChange] {
        let resolved = try await resolve(id)
        let response = try await request("container.changes", ["id": .string(resolved)])
        let payload = try decode(response, as: GuestContainerChangesPayload.self)
        return payload.changes.map { DockerRuntimeContainerChange(path: $0.path, kind: $0.kind) }
    }

    func createExec(_ request: DockerRuntimeExecCreate) async throws -> String {
        _ = try await resolve(request.containerID)
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        execs[id] = request
        return id
    }

    func resizeExec(id: String, width: UInt32, height: UInt32) async throws {
        guard execs[id] != nil else { throw DockerRuntimeRouteError.notFound("exec (id)") }
        _ = try await request(
            "exec.resize",
            [
                "id": .string(id),
                "width": .number(Double(width)),
                "height": .number(Double(height)),
            ]
        )
    }

    private func ensureNameAvailable(_ requestedName: String) throws {
        let normalized = Self.normalizedContainerName(requestedName)
        if let existing = metadata.first(where: { $0.value.name == normalized }) {
            throw DockerRuntimeRouteError.conflict(
                "Conflict. The container name /\(normalized) is already in use by container \(existing.key)."
            )
        }
    }

    func startExec(id: String, detach: Bool, tty: Bool) async throws -> DockerRuntimeProcessOutput {
        guard let exec = execs[id] else { throw DockerRuntimeRouteError.notFound("exec \(id)") }
        let containerID = try await resolve(exec.containerID)
        var payload: [String: JSONValue] = [
            "id": .string(containerID), "execId": .string(id),
            "args": .array(exec.command.map(JSONValue.string)),
            "env": .array(exec.environment.map(JSONValue.string)), "terminal": .bool(tty),
            "attachStdin": .bool(exec.attachStdin),
        ]
        if let cwd = exec.workingDirectory, !cwd.isEmpty { payload["cwd"] = .string(cwd) }
        if let user = exec.user, !user.isEmpty { payload["user"] = .string(user) }
        let collector = GuestStreamCollector(
            stdout: detach ? false : exec.attachStdout,
            stderr: detach ? false : exec.attachStderr
        )
        let connection = try await engine.readyConnection()
        try await engine.prepareForWork()
        do {
            let response = try await connection.request(
                method: "container.exec", payload: .object(payload), onStream: collector.append
            )
            let output = try collector.output(exitCode: response.exitCode ?? -1)
            await engine.finishedWork()
            await broadcastContainer(
                "exec_die", id: containerID,
                extra: ["execID": id, "exitCode": String(output.exitCode)]
            )
            return output
        } catch {
            await engine.finishedWork()
            throw error
        }
    }

    func streamExec(
        id: String, tty: Bool
    ) async throws -> AsyncThrowingStream<DockerRuntimeProcessFrame, Error> {
        try await streamExec(id: id, tty: tty, onInput: nil)
    }

    func streamExec(
        id: String, tty: Bool, onInput: GuestInputRelay?
    ) async throws -> AsyncThrowingStream<DockerRuntimeProcessFrame, Error> {
        guard let exec = execs[id] else { throw DockerRuntimeRouteError.notFound("exec \(id)") }
        let containerID = try await resolve(exec.containerID)
        var payload: [String: JSONValue] = [
            "id": .string(containerID), "execId": .string(id),
            "args": .array(exec.command.map(JSONValue.string)),
            "env": .array(exec.environment.map(JSONValue.string)), "terminal": .bool(tty),
            "attachStdin": .bool(exec.attachStdin),
        ]
        if let cwd = exec.workingDirectory, !cwd.isEmpty { payload["cwd"] = .string(cwd) }
        if let user = exec.user, !user.isEmpty { payload["user"] = .string(user) }
        let connection = try await engine.readyConnection()
        try await engine.prepareForWork()
        let requestPayload: JSONValue = .object(payload)
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(64)) { continuation in
            let control = GuestStreamRequestControl()
            let relay = onInput
            let request = Task {
                do {
                    let response = try await connection.request(
                        method: "container.exec", payload: requestPayload,
                        onStream: { frame in
                            guard let data = frame.data else { return }
                            let result = continuation.yield(
                                .init(stream: frame.stream, data: data, exitCode: nil)
                            )
                            if case .dropped = result {
                                continuation.finish(
                                    throwing: DockerRuntimeRouteError.invalidRequest(
                                        "exec client is too slow for the bounded stream buffer"
                                    )
                                )
                                control.cancel()
                            }
                        },
                        onRequestID: { requestID in
                            relay?.set(connection: connection, requestID: requestID)
                        })
                    continuation.yield(
                        .init(stream: nil, data: Data(), exitCode: response.exitCode ?? -1)
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                await engine.finishedWork()
            }
            control.set(request)
            continuation.onTermination = { _ in
                control.cancel()
                relay?.send(Data())
            }
        }
    }

    func attachContainer(
        id: String, stdout: Bool, stderr: Bool
    ) async throws -> AsyncThrowingStream<DockerRuntimeProcessFrame, Error> {
        try await attachContainer(
            id: id,
            stdout: stdout,
            stderr: stderr,
            options: DockerRuntimeLogOptions(
                timestamps: false, details: false, since: nil, until: nil, tail: nil
            )
        )
    }

    func attachContainer(
        id: String,
        stdout: Bool,
        stderr: Bool,
        options: DockerRuntimeLogOptions
    ) async throws -> AsyncThrowingStream<DockerRuntimeProcessFrame, Error> {
        try await attachContainer(
            id: id, stdout: stdout, stderr: stderr, options: options, onInput: nil
        )
    }

    func attachContainer(
        id: String,
        stdout: Bool,
        stderr: Bool,
        options: DockerRuntimeLogOptions,
        onInput: GuestInputRelay?
    ) async throws -> AsyncThrowingStream<DockerRuntimeProcessFrame, Error> {
        try await attachContainer(
            id: id, stdout: stdout, stderr: stderr, options: options,
            onInput: onInput, attachment: nil
        )
    }

    func beginAttachment(id: String) async throws -> DockerRuntimeAttachmentLease {
        let resolved = try await resolve(id)
        let token = await attachments.begin(id: resolved)
        return DockerRuntimeAttachmentLease(id: resolved, token: token)
    }

    func releaseAttachment(_ lease: DockerRuntimeAttachmentLease) async {
        await finishAttachment(id: lease.id, token: lease.token)
    }

    func attachContainer(
        id: String,
        stdout: Bool,
        stderr: Bool,
        options: DockerRuntimeLogOptions,
        onInput: GuestInputRelay?,
        attachment: DockerRuntimeAttachmentLease?
    ) async throws -> AsyncThrowingStream<DockerRuntimeProcessFrame, Error> {
        let resolved: String
        do {
            resolved = try await resolve(id)
        } catch {
            if let attachment {
                await finishAttachment(id: attachment.id, token: attachment.token)
            }
            throw error
        }
        let attachmentToken: UUID
        if let attachment {
            guard attachment.id == resolved else {
                await finishAttachment(id: attachment.id, token: attachment.token)
                throw DockerRuntimeRouteError.notFound(Self.missingContainerMessage(id))
            }
            attachmentToken = attachment.token
        } else {
            attachmentToken = await attachments.begin(id: resolved)
        }
        do {
            let runtimeEngine = engine
            let connection = try await runtimeEngine.readyConnection()
            try await runtimeEngine.prepareForWork()
            var payload: [String: JSONValue] = [
                "id": .string(resolved), "stdout": .bool(stdout), "stderr": .bool(stderr),

                // Attach uses tail=0 when only live output is requested. A nil
                // tail means Docker requested the existing log replay as well.
                "logs": .bool(options.tail == nil),
            ]
            Self.addLogOptions(options, to: &payload)
            let requestPayload = JSONValue.object(payload)
            return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(64)) { continuation in
                let control = GuestStreamRequestControl()
                let relay = onInput
                let request = Task { [weak self] in
                    do {
                        let response = try await connection.request(
                            method: "container.attach", payload: requestPayload,
                            onStream: { frame in
                                guard let data = frame.data else { return }
                                let result = continuation.yield(
                                    .init(stream: frame.stream, data: data, exitCode: nil)
                                )
                                if case .dropped = result {
                                    continuation.finish(
                                        throwing: DockerRuntimeRouteError.invalidRequest(
                                            "attach client is too slow for the bounded stream buffer"
                                        )
                                    )
                                    control.cancel()
                                }
                            },
                            onRequestID: { requestID in
                                relay?.set(connection: connection, requestID: requestID)
                            })
                        continuation.yield(
                            .init(stream: nil, data: Data(), exitCode: response.exitCode ?? -1)
                        )
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                    await runtimeEngine.finishedWork()
                    await self?.finishAttachment(id: resolved, token: attachmentToken)
                }
                control.set(request)
                continuation.onTermination = { [weak self] _ in
                    control.cancel()
                    relay?.send(Data())
                    Task { [weak self] in
                        await self?.finishAttachment(id: resolved, token: attachmentToken)
                    }
                }
            }
        } catch {
            await finishAttachment(id: resolved, token: attachmentToken)
            throw error
        }
    }

    private func finishAttachment(id: String, token: UUID) async {
        let ended = await attachments.end(id: id, token: token)
        guard ended else { return }
        let autoRemove = metadata[id]?.autoRemove == true
        guard autoRemove else { return }
        // Attach is owned by the HTTP request task. Docker closes that task
        // as soon as it has consumed the final frame, so cleanup must not
        // inherit its cancellation before the removal waiter is signalled.
        _ = Task.detached { [weak self] in
            guard let self else { return }
            do {
                try await self.deleteContainer(id: id, force: true, removeVolumes: true)
            } catch {
                return
            }
        }
    }

    /// Like `streamRequest`, but suspends until the guest either delivers its
    /// first data frame (returned as `firstChunk`) or fails. Callers can then
    /// commit HTTP response headers only once the guest accepted the request,
    /// so setup failures become real HTTP errors instead of dropped streams.
    private func streamRequestWithFirstChunk(
        method: String, payload: [String: JSONValue]
    ) async throws -> (Data, AsyncThrowingStream<Data, Error>) {
        let connection = try await engine.readyConnection()
        try await engine.prepareForWork()
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let gate = GuestFirstChunkGate()
        let control = GuestStreamRequestControl()
        let request = Task {
            do {
                _ = try await connection.request(method: method, payload: .object(payload)) { frame in
                    guard let data = frame.data else { return }
                    gate.deliver(data)
                    continuation.yield(data)
                }
                if !gate.closeWithoutData() {
                    continuation.finish(
                        throwing: DockerRuntimeRouteError.invalidRequest(
                            "guest produced an empty export stream"
                        ))
                } else {
                    continuation.finish()
                }
            } catch {
                continuation.finish(throwing: error)
                gate.fail(error)
            }
            await engine.finishedWork()
        }
        control.set(request)
        continuation.onTermination = { _ in control.cancel() }
        let first = try await gate.wait()
        return (first, stream)
    }

    private func streamRequest(
        method: String, payload: [String: JSONValue]
    ) async throws -> AsyncThrowingStream<Data, Error> {
        let connection = try await engine.readyConnection()
        try await engine.prepareForWork()
        // Unbounded buffering: dropping frames here silently truncated large
        // exports whenever the HTTP side drained slower than the guest wrote.
        // The consumer is always an active response body or file sink, so the
        // buffer only absorbs vsock/HTTP throughput jitter.
        return AsyncThrowingStream { continuation in
            let control = GuestStreamRequestControl()
            let request = Task {
                do {
                    _ = try await connection.request(method: method, payload: .object(payload)) { frame in
                        guard let data = frame.data else { return }
                        let result = continuation.yield(data)
                        if case .dropped = result {
                            continuation.finish(
                                throwing: DockerRuntimeRouteError.invalidRequest(
                                    "guest export client is too slow for the bounded stream buffer"
                                )
                            )
                            control.cancel()
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                await engine.finishedWork()
            }
            control.set(request)
            continuation.onTermination = { _ in control.cancel() }
        }
    }

    func logs(id: String, stdout: Bool, stderr: Bool) async throws -> DockerRuntimeProcessOutput {
        try await logs(
            id: id,
            stdout: stdout,
            stderr: stderr,
            options: DockerRuntimeLogOptions(
                timestamps: false, details: false, since: nil, until: nil, tail: nil
            )
        )
    }

    func logs(
        id: String,
        stdout: Bool,
        stderr: Bool,
        options: DockerRuntimeLogOptions
    ) async throws -> DockerRuntimeProcessOutput {
        let resolved = try await resolve(id)
        var requestPayload: [String: JSONValue] = [
            "id": .string(resolved), "stdout": .bool(stdout), "stderr": .bool(stderr),
        ]
        Self.addLogOptions(options, to: &requestPayload)
        let response = try await request(
            "container.logs", requestPayload
        )
        let payload: GuestLogsPayload = try decode(response)
        return DockerRuntimeProcessOutput(
            stdout: payload.stdout ?? Data(), stderr: payload.stderr ?? Data(), exitCode: 0
        )
    }

    private static func addLogOptions(
        _ options: DockerRuntimeLogOptions, to payload: inout [String: JSONValue]
    ) {
        if options.timestamps { payload["timestamps"] = .bool(true) }
        if options.details { payload["details"] = .bool(true) }
        if let since = options.since { payload["since"] = .number(Double(since)) }
        if let until = options.until { payload["until"] = .number(Double(until)) }
        if let tail = options.tail { payload["tail"] = .number(Double(tail)) }
    }

    private func resolve(_ reference: String) async throws -> String {
        if metadata[reference] != nil { return reference }
        let normalized = reference.hasPrefix("/") ? String(reference.dropFirst()) : reference
        let matches = metadata.filter {
            $0.key.hasPrefix(reference) || $0.value.name == normalized
        }.map(\.key)
        if matches.count == 1, let id = matches.first { return id }
        let response = try await request("container.list", [:])
        let guest: GuestContainerListPayload = try decode(response)
        guest.containers.forEach { hydrateMetadata(from: $0) }
        let guestMatches = guest.containers.filter {
            let name = metadata[$0.id]?.name
            return $0.id == reference || $0.id.hasPrefix(reference) || name == normalized
        }.map(\.id)
        guard guestMatches.count == 1, let id = guestMatches.first else {
            throw DockerRuntimeRouteError.notFound(Self.missingContainerMessage(reference))
        }
        return id
    }

    static func missingContainerMessage(_ reference: String) -> String {
        "No such container: \(reference)"
    }

    private func request(
        _ method: String,
        _ payload: [String: JSONValue],
        memoryTarget: UInt64? = nil
    ) async throws -> GuestFrame {
        do {
            let connection = try await engine.readyConnection()
            try await engine.prepareForWork(memoryTarget: memoryTarget)
            let response: GuestFrame
            do {
                response = try await connection.request(method: method, payload: .object(payload))
            } catch {
                await engine.finishedWork()
                throw error
            }
            await engine.finishedWork()
            return response
        } catch let error as GuestProtocolError {
            throw Self.routeError(for: error) ?? error
        }
    }

    private func requestWithInput(
        _ method: String,
        _ payload: [String: JSONValue],
        data: Data
    ) async throws -> GuestFrame {
        do {
            let connection = try await engine.readyConnection()
            try await engine.prepareForWork()
            let response: GuestFrame
            do {
                response = try await connection.request(
                    method: method,
                    payload: .object(payload),
                    onStream: { _ in },
                    onRequestID: { requestID in
                        Task {
                            do {
                                let chunkSize = 256 * 1024
                                var offset = 0
                                while offset < data.count {
                                    let end = min(offset + chunkSize, data.count)
                                    try await connection.sendStream(
                                        id: requestID,
                                        stream: .stdin,
                                        data: data.subdata(in: offset..<end)
                                    )
                                    offset = end
                                }
                                // An empty stdin frame is the upload EOF marker.
                                try await connection.sendStream(
                                    id: requestID, stream: .stdin, data: Data()
                                )
                            } catch {
                                await connection.close()
                            }
                        }
                    }
                )
            } catch {
                await engine.finishedWork()
                throw error
            }
            await engine.finishedWork()
            return response
        } catch let error as GuestProtocolError {
            throw Self.routeError(for: error) ?? error
        }
    }

    private static func routeError(for error: GuestProtocolError) -> DockerRuntimeRouteError? {
        let message = error.message
        let lowercased = message.lowercased()
        if error.code.contains("not_found") || lowercased.contains("not found") {
            return .notFound(message)
        }
        if lowercased.contains("image must already exist") {
            return .notFound(message)
        }
        if error.code == "invalid_argument"
            || lowercased.contains("invalid ")
            || lowercased.contains("requires ")
            || lowercased.contains("must be ")
            || lowercased.contains("unsupported ")
            || lowercased.contains("outside ")
            || lowercased.contains("exceeds ")
            || lowercased.contains("is empty")
            || lowercased.contains("no healthcheck")
            || lowercased.contains("healthcheck command")
            || lowercased.contains("source and target")
        {
            return .invalidRequest(message)
        }
        if lowercased.contains("used by container") || lowercased.contains("multiple tags")
            || lowercased.contains("already exists") || lowercased.contains("already in use")
            || lowercased.contains("running container")
            || lowercased.contains("container is not running")
            || lowercased.contains("hot attach")
            || lowercased.contains("network is in use")
            || lowercased.contains("cannot be removed")
        {
            return .conflict(message)
        }
        return nil
    }

    /// Removes a container's publications shortly after its exit event. The
    /// delay is deliberate: a restart's start side may be racing this event,
    /// and immediate removal would tear down the new run's freshly published
    /// listeners. At fire time the container must still be idle both locally
    /// and (as ground truth) in the guest.
    private func schedulePortTeardown(_ id: String) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            await self?.teardownPortsIfIdle(id: id)
        }
    }

    private func scheduleAutoRemoval(_ id: String) {
        Task { [weak self] in
            guard let self else { return }
            let autoRemove = await self.isAutoRemoveContainer(id: id)
            guard autoRemove else { return }
            let decision = await self.attachments.requestRemoval(id: id)
            switch decision {
            case .waitForAttachment:
                return
            case .waitForGrace:
                // Yield once when no attach is active so a just-arriving
                // attach request can claim the pending removal. The normal
                // docker run --rm path remains free of a fixed delay.
                try? await Task.sleep(for: .milliseconds(1))
                let retry = await self.attachments.requestRemoval(id: id)
                guard retry == .removeNow else {
                    return
                }
            case .removeNow:
                break
            }
            do {
                try await self.deleteContainer(id: id, force: true, removeVolumes: true)
            } catch {
            }
        }
    }

    private func isAutoRemoveContainer(id: String) -> Bool {
        metadata[id]?.autoRemove == true
    }

    private func teardownPortsIfIdle(id: String) async {
        guard metadata[id]?.state != .running else { return }
        let current = try? await inspectContainer(id: id)
        if current?.state == .running || current?.state == .paused { return }
        try? await portPublisher.remove(containerID: id)
    }

    private func handle(event: GuestFrame) async {
        guard event.method == "container.exit",
            let exit = try? decode(event, as: GuestExitPayload.self)
        else { return }
        metadata[exit.id]?.state = .exited
        metadata[exit.id]?.exitCode = Int32(exit.exitCode)
        await engine.releaseMemoryTarget(id: exit.id)
        pendingPublications.remove(exit.id)
        schedulePortTeardown(exit.id)
        exitCodes.record(id: exit.id, code: Int32(exit.exitCode))
        await broadcastContainer(
            "die", id: exit.id, extra: ["exitCode": String(exit.exitCode)]
        )
        let policy = metadata[exit.id]?.restartPolicy ?? .init()
        let restartCount = metadata[exit.id]?.restartCount ?? 0
        let shouldRestart =
            !manuallyStopped.contains(exit.id)
            && !((policy.name.lowercased() == "on-failure") && exit.exitCode == 0)
            && ["always", "unless-stopped", "on-failure"].contains(policy.name.lowercased())
            && (policy.name.lowercased() != "on-failure"
                || policy.maximumRetryCount == 0
                || restartCount < policy.maximumRetryCount)
        if metadata[exit.id]?.autoRemove == true {
            scheduleAutoRemoval(exit.id)
        } else if shouldRestart {
            metadata[exit.id]?.state = .restarting
            metadata[exit.id]?.restartCount = restartCount + 1
            try? await persistRestartCount(
                containerID: exit.id, count: restartCount + 1
            )
            let containerID = exit.id
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                try? await self.startContainer(id: containerID)
            }
        }
    }

    private func dockerContainer(_ guest: GuestContainer) -> DockerRuntimeContainer {
        hydrateMetadata(from: guest)
        let meta = metadata[guest.id]
        let health = Self.dockerHealth(guest.health) ?? meta?.health ?? .init()
        metadata[guest.id]?.health = health
        let restartPolicy = meta?.restartPolicy ?? guest.metadata?.restartPolicy ?? .init()
        let resources = meta?.resources ?? guest.metadata?.resources ?? .init()
        let stopSignal = meta?.stopSignal ?? guest.metadata?.stopSignal ?? ""
        let state: EngineContainerState
        switch guest.status {
        case "running": state = .running
        case "paused": state = .paused
        case "restarting": state = .restarting
        case "stopped", "exited": state = .exited
        default: state = .created
        }
        metadata[guest.id]?.state = state
        let networkMode = meta?.networkMode ?? guest.metadata?.networkMode ?? "default"
        let dockerNetworkMode = networkMode == "private" ? "default" : networkMode
        return DockerRuntimeContainer(
            id: guest.id, name: meta?.name ?? guest.id, image: guest.image,
            command: meta?.command ?? [], createdAt: guest.createdAt, state: state,
            exitCode: guest.exitCode.map(Int32.init), labels: meta?.labels ?? [:],
            tty: meta?.tty ?? false, ports: meta?.ports ?? [],
            sizeRw: guest.sizeRw ?? -1, sizeRootFs: guest.sizeRootFs ?? -1,
            stopTimeout: meta?.stopTimeout, health: health,
            healthcheck: meta?.healthcheck ?? guest.metadata?.healthcheck.map(Self.healthcheck),
            restartPolicy: restartPolicy, restartCount: meta?.restartCount ?? 0,
            resources: resources, stopSignal: stopSignal,
            networkMode: dockerNetworkMode,
            autoRemove: meta?.autoRemove ?? guest.metadata?.autoRemove ?? false,
            entrypoint: meta?.entrypoint ?? guest.metadata?.entrypoint,
            cmd: meta?.cmd ?? guest.metadata?.cmd,
            environment: meta?.environment ?? guest.metadata?.env ?? [],
            workingDirectory: meta?.workingDirectory ?? guest.metadata?.cwd ?? "",
            user: meta?.user ?? guest.metadata?.user ?? "",
            hostname: meta?.hostname ?? guest.metadata?.hostname ?? "",
            attachStdin: meta?.attachStdin ?? guest.metadata?.attachStdin ?? false,
            openStdin: meta?.openStdin ?? guest.metadata?.openStdin ?? false,
            stdinOnce: meta?.stdinOnce ?? guest.metadata?.stdinOnce ?? false,
            mounts: meta?.mounts ?? guest.metadata?.mounts ?? [],
            readonlyRootfs: meta?.readonlyRootfs ?? guest.metadata?.readonlyRootfs ?? false,
            dns: meta?.dns ?? guest.metadata?.dns ?? [],
            dnsSearch: meta?.dnsSearch ?? guest.metadata?.dnsSearch ?? [],
            extraHosts: meta?.extraHosts ?? guest.metadata?.extraHosts ?? []
        )
    }

    private static func dockerNetwork(_ guest: GuestNetworkPayload) -> DockerRuntimeNetwork {
        DockerRuntimeNetwork(
            id: guest.id,
            name: guest.name,
            createdAt: guest.createdAt,
            scope: guest.scope,
            driver: guest.driver,
            enableIPv4: guest.enableIPv4,
            enableIPv6: guest.enableIPv6,
            internalNetwork: guest.internalNetwork,
            attachable: guest.attachable,
            ingress: guest.ingress,
            ipam: NetworkIPAM(
                Driver: guest.ipam.driver,
                Config: guest.ipam.config.map {
                    NetworkIPAMConfig(
                        Subnet: $0.subnet,
                        IPRange: $0.ipRange,
                        Gateway: $0.gateway,
                        AuxiliaryAddresses: $0.auxiliaryAddresses
                    )
                }
            ),
            options: guest.options,
            containers: guest.containers.mapValues {
                DockerRuntimeNetworkContainer(
                    name: $0.name,
                    endpointID: $0.endpointID,
                    macAddress: $0.macAddress,
                    ipv4Address: $0.ipv4Address,
                    ipv6Address: $0.ipv6Address
                )
            },
            labels: guest.labels
        )
    }

    private func hydrateMetadata(from guest: GuestContainer) {
        guard metadata[guest.id] == nil, let stored = guest.metadata else { return }
        metadata[guest.id] = Metadata(
            name: stored.name ?? guest.id,
            command: stored.args ?? [],
            entrypoint: stored.entrypoint,
            cmd: stored.cmd,
            environment: stored.env ?? [],
            workingDirectory: stored.cwd ?? "",
            user: stored.user ?? "",
            hostname: stored.hostname ?? "",
            labels: stored.labels ?? [:],
            tty: stored.terminal ?? false,
            attachStdin: stored.attachStdin ?? false,
            openStdin: stored.openStdin ?? false,
            stdinOnce: stored.stdinOnce ?? false,
            autoRemove: stored.autoRemove ?? false,
            stopTimeout: stored.stopTimeout,
            mounts: stored.mounts ?? [],
            readonlyRootfs: stored.readonlyRootfs ?? false,
            dns: stored.dns ?? [],
            dnsSearch: stored.dnsSearch ?? [],
            extraHosts: stored.extraHosts ?? [],
            image: guest.image,
            createdAt: guest.createdAt,
            ports: stored.portBindings ?? [],
            guestPorts: (stored.publishedPorts ?? guest.publishedPorts ?? []).map(\.guestPort),
            state: Self.state(for: guest.status),
            exitCode: guest.exitCode.map(Int32.init),
            health: Self.dockerHealth(guest.health) ?? .init(),
            healthcheck: guest.metadata?.healthcheck.map(Self.healthcheck),
            restartPolicy: guest.metadata?.restartPolicy ?? .init(),
            restartCount: stored.restartCount ?? guest.metadata?.restartCount ?? 0,
            resources: guest.metadata?.resources ?? .init(),
            stopSignal: guest.metadata?.stopSignal ?? "",
            networkMode: stored.networkMode ?? "default"
        )
    }

    private func cachedContainer(id: String) -> DockerRuntimeContainer? {
        guard let meta = metadata[id] else { return nil }
        let dockerNetworkMode = meta.networkMode == "private" ? "default" : meta.networkMode
        return DockerRuntimeContainer(
            id: id,
            name: meta.name,
            image: meta.image,
            command: meta.command,
            createdAt: meta.createdAt,
            state: meta.state,
            exitCode: meta.exitCode,
            labels: meta.labels,
            tty: meta.tty,
            ports: meta.ports,
            sizeRw: -1,
            sizeRootFs: -1,
            stopTimeout: meta.stopTimeout, health: meta.health,
            healthcheck: meta.healthcheck, restartPolicy: meta.restartPolicy,
            restartCount: meta.restartCount,
            resources: meta.resources, stopSignal: meta.stopSignal,
            networkMode: dockerNetworkMode, autoRemove: meta.autoRemove,
            entrypoint: meta.entrypoint, cmd: meta.cmd, environment: meta.environment,
            workingDirectory: meta.workingDirectory, user: meta.user, hostname: meta.hostname,
            attachStdin: meta.attachStdin, openStdin: meta.openStdin, stdinOnce: meta.stdinOnce,
            mounts: meta.mounts, readonlyRootfs: meta.readonlyRootfs,
            dns: meta.dns, dnsSearch: meta.dnsSearch, extraHosts: meta.extraHosts
        )
    }

    private func restoreRuntimeState() async throws {
        let response = try await request("container.list", [:])
        let payload: GuestContainerListPayload = try decode(response)
        payload.containers.forEach { hydrateMetadata(from: $0) }
        for container in payload.containers
        where container.status == "stopped" || container.status == "exited" {
            if metadata[container.id]?.autoRemove == true {
                try await deleteContainer(id: container.id, force: true, removeVolumes: true)
            }
        }
        // Containers that were running when the daemon (and with it the VM)
        // went away come back as stopped tasks; restart them so `docker ps`
        // shows the same workload after a daemon restart. The exit event of
        // the VM teardown never reaches this runtime, so lifecycle state is
        // the only signal.
        for container in payload.containers
        where container.metadata?.lifecycleState == "running"
            && container.status != "running"
            && container.status != "paused"
        {
            try? await startContainer(id: container.id)
        }
        reservedGuestPorts.removeAll()
        for container in payload.containers.sorted(by: { $0.id < $1.id }) {
            guard var meta = metadata[container.id] else { continue }
            let reusable =
                meta.guestPorts.count == meta.ports.count
                && meta.guestPorts.allSatisfy(PublishedPortProxyRange.ports.contains)
                && Set(meta.guestPorts).isDisjoint(with: reservedGuestPorts)
            if !reusable {
                guard
                    let replacement = Self.lowestAvailableGuestPorts(
                        count: meta.ports.count,
                        range: PublishedPortProxyRange.ports,
                        excluding: reservedGuestPorts
                    )
                else {
                    throw DockerRuntimeRouteError.conflict(
                        "published guest port range is exhausted during recovery"
                    )
                }
                meta.guestPorts = replacement
                metadata[container.id] = meta
            }
            reservedGuestPorts.formUnion(meta.guestPorts)
        }
        for container in payload.containers where container.status == "running" {
            guard let bindings = metadata[container.id]?.ports, !bindings.isEmpty else { continue }
            let guestPorts = container.metadata?.publishedPorts ?? container.publishedPorts ?? []
            guard guestPorts.count == bindings.count else { continue }
            let published = try await portPublisher.publish(
                containerID: container.id,
                bindings: bindings,
                guestPorts: guestPorts.map(\.guestPort)
            )
            metadata[container.id]?.ports = published
            try await persistPortBindings(containerID: container.id, bindings: published)
            try? await engine.retainMemoryTarget(
                id: container.id, bytes: PersistentEngine.publishedNetworkMemoryBytes
            )
        }
    }

    private func persistPortBindings(
        containerID: String, bindings: [DockerRuntimePortBinding]
    ) async throws {
        _ = try await request(
            "container.metadata.update",
            [
                "id": .string(containerID),
                "portBindings": .array(bindings.map(Self.portBindingJSON)),
            ]
        )
    }

    private func persistRestartCount(containerID: String, count: Int) async throws {
        _ = try await request(
            "container.metadata.update",
            [
                "id": .string(containerID),
                "restartCount": .number(Double(count)),
            ]
        )
    }

    private func vmnetHostSource(required: Bool) async throws -> String {
        guard required else { return "" }
        guard let address = await engine.hostGatewayAddress() else {
            throw PersistentEngineError.invalidMachineSnapshot("engine IP address is unavailable")
        }
        return address
    }

    private static func portBindingJSON(_ binding: DockerRuntimePortBinding) -> JSONValue {
        var object: [String: JSONValue] = [
            "containerPort": .number(Double(binding.containerPort)),
            "protocol": .string(binding.proto),
            "hostIP": .string(binding.hostIP),
        ]
        if let hostPort = binding.hostPort { object["hostPort"] = .number(Double(hostPort)) }
        return .object(object)
    }

    private static func healthcheckJSON(_ healthcheck: DockerRuntimeHealthcheck) -> JSONValue {
        .object([
            "test": .array(healthcheck.test.map(JSONValue.string)),
            "interval": .number(Double(healthcheck.interval)),
            "timeout": .number(Double(healthcheck.timeout)),
            "retries": .number(Double(healthcheck.retries)),
            "startPeriod": .number(Double(healthcheck.startPeriod)),
            "startInterval": .number(Double(healthcheck.startInterval)),
        ])
    }

    private static func resourcesJSON(_ resources: DockerRuntimeResources) -> JSONValue {
        .object([
            "memory": .number(Double(resources.memory)),
            "memorySwap": .number(Double(resources.memorySwap)),
            "memoryReservation": .number(Double(resources.memoryReservation)),
            "nanoCPUs": .number(Double(resources.nanoCPUs)),
            "cpuShares": .number(Double(resources.cpuShares)),
            "cpuPeriod": .number(Double(resources.cpuPeriod)),
            "cpuQuota": .number(Double(resources.cpuQuota)),
            "cpusetCpus": .string(resources.cpusetCpus),
            "cpusetMems": .string(resources.cpusetMems),
            "pidsLimit": .number(Double(resources.pidsLimit)),
        ])
    }

    private static func healthcheck(_ value: GuestHealthcheck) -> DockerRuntimeHealthcheck {
        DockerRuntimeHealthcheck(
            test: value.test, interval: value.interval, timeout: value.timeout,
            retries: value.retries, startPeriod: value.startPeriod,
            startInterval: value.startInterval
        )
    }

    private static func dockerHealth(_ value: GuestHealth?) -> DockerRuntimeHealth? {
        guard let value else { return nil }
        return DockerRuntimeHealth(
            status: value.status, failingStreak: value.failingStreak,
            log: value.log
        )
    }

    private func releaseGuestPorts(containerID: String) {
        guard let ports = metadata[containerID]?.guestPorts else { return }
        reservedGuestPorts.subtract(ports)
    }

    private static func state(for status: String) -> EngineContainerState {
        switch status {
        case "running": .running
        case "paused": .paused
        case "restarting": .restarting
        case "stopped", "exited": .exited
        default: .created
        }
    }

    private static func normalizedContainerName(_ name: String) -> String {
        name.hasPrefix("/") ? String(name.dropFirst()) : name
    }

    private func decode<T: Decodable>(_ frame: GuestFrame, as type: T.Type = T.self) throws -> T {
        guard let payload = frame.payload else { throw GuestProtocolError(code: "invalid_response", message: "missing payload") }
        let data = try JSONEncoder().encode(payload)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    private static func makeID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func dockerImage(_ image: GuestImageDetailPayload) -> DockerRuntimeImage {
        DockerRuntimeImage(
            reference: image.references.first ?? image.digest,
            digest: image.id,
            references: image.references,
            createdAt: image.createdAt,
            size: image.size,
            labels: image.labels ?? [:],
            author: image.author ?? "",
            architecture: image.architecture ?? "",
            os: image.os ?? "",
            osVersion: image.osVersion ?? "",
            variant: image.variant ?? "",
            config: DockerRuntimeImageConfig(
                user: image.config?.user ?? "",
                exposedPorts: Set(image.config?.exposedPorts?.keys.map { String($0) } ?? []),
                environment: image.config?.env ?? [],
                entrypoint: image.config?.entrypoint ?? [],
                cmd: image.config?.cmd ?? [],
                volumes: Set(image.config?.volumes?.keys.map { String($0) } ?? []),
                workingDirectory: image.config?.workingDir ?? "",
                labels: image.config?.labels ?? [:],
                stopSignal: image.config?.stopSignal ?? "",
                healthcheck: image.config?.healthcheck.map(Self.healthcheck),
                onBuild: image.config?.onBuild ?? [],
                shell: image.config?.shell ?? []
            ),
            rootFSLayers: image.rootFSLayers,
            history: image.history.map {
                DockerRuntimeImageHistory(
                    created: $0.created,
                    createdBy: $0.createdBy ?? "",
                    tags: $0.tags ?? [],
                    size: $0.size,
                    comment: $0.comment ?? "",
                    emptyLayer: $0.emptyLayer ?? false
                )
            }
        )
    }

    private static func dockerImageDelete(_ result: GuestImageDeletePayload) -> DockerRuntimeImageDelete {
        DockerRuntimeImageDelete(
            deleted: result.deleted ?? [],
            untagged: result.untagged ?? [],
            reclaimed: result.reclaimed ?? 0
        )
    }

    private static func normalizedRegistryReference(_ reference: String) -> String {
        if reference.hasPrefix("sha256:") { return reference }
        if reference.count >= 4, reference.allSatisfy({ $0.isHexDigit }) { return reference }
        let first = reference.split(separator: "/", maxSplits: 1).first.map(String.init) ?? reference
        var normalized: String
        if reference.contains("/"), first.contains(".") || first.contains(":") || first == "localhost" {
            normalized = reference
        } else {
            normalized = reference.contains("/") ? "docker.io/\(reference)" : "docker.io/library/\(reference)"
        }
        let last = normalized.split(separator: "/").last.map(String.init) ?? normalized
        if !normalized.contains("@"), !last.contains(":") { normalized += ":latest" }
        return normalized
    }

    private func broadcastContainer(
        _ action: String,
        id: String,
        extra: [String: String] = [:]
    ) async {
        guard let broadcaster, let meta = metadata[id] else { return }
        await broadcaster.broadcast(
            DockerEvent.simpleEvent(
                id: id, type: "container", status: action,
                image: meta.image, name: meta.name, labels: meta.labels,
                extraAttributes: extra
            )
        )
    }

}

struct GuestRuntimeLifecycle: LifecycleHandler {
    let runtime: GuestRuntime

    func shutdownAsync(_ application: Application) async {
        await runtime.stopEventMonitor()
    }
}

/// Hands the first guest stream chunk to a suspended caller exactly once so a
/// route can validate the request before committing HTTP response headers.
private final class GuestFirstChunkGate: @unchecked Sendable {
    private enum Outcome {
        case delivered(Data)
        case failed(Error)
        case empty
    }

    private struct EmptyExportError: Error {}

    private let lock = NSLock()
    private var outcome: Outcome?
    private var waiting: [CheckedContinuation<Data, Error>] = []

    func deliver(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard outcome == nil else { return }
        outcome = .delivered(data)
        waiting.forEach { $0.resume(returning: data) }
        waiting = []
    }

    /// Returns true when at least one chunk had been delivered.
    func closeWithoutData() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if outcome == nil { outcome = .empty }
        waiting.forEach { $0.resume(throwing: EmptyExportError()) }
        waiting = []
        if case .delivered = outcome { return true }
        return false
    }

    func fail(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        if outcome == nil { outcome = .failed(error) }
        waiting.forEach { $0.resume(throwing: error) }
        waiting = []
    }

    func wait() async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                defer { lock.unlock() }
                switch outcome {
                case .some(.delivered(let data)): continuation.resume(returning: data)
                case .some(.failed(let error)): continuation.resume(throwing: error)
                case .some(.empty): continuation.resume(throwing: EmptyExportError())
                case nil: waiting.append(continuation)
                }
            }
        } onCancel: {
            // Cancellation propagates through the guest request failing, which
            // calls fail(_:); nothing extra to resume here.
        }
    }
}

extension GuestRuntime: DockerRuntimeImageImportStreamingBackend {
    func openImportSession(reference: String?) async throws -> GuestImportSession {
        let connection = try await engine.readyConnection()
        try await engine.prepareForWork()
        let engine = self.engine
        return GuestImportSession(
            connection: connection,
            reference: reference.map { Self.normalizedRegistryReference($0) },
            decodeResponse: { frame in
                guard let payload = frame.payload else {
                    throw GuestProtocolError(code: "invalid_response", message: "missing payload")
                }
                let data = try JSONEncoder().encode(payload)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let imported = try decoder.decode(GuestImageImportPayload.self, from: data)
                return imported.images.map {
                    DockerRuntimeImage(reference: $0.name, digest: $0.digest)
                }
            },
            onFinish: { await engine.finishedWork() }
        )
    }
}

struct GuestSystemDfPayload: Decodable {
    let layersSize: Int64
    let buildCache: [GuestBuildCacheRecord]?
}

struct GuestBuildCacheRecord: Decodable {
    let id: String
    let type: String?
    let description: String?
    let inUse: Bool?
    let shared: Bool?
    let size: Int64?
    let createdAt: Date?
    let lastUsedAt: Date?
    let usageCount: Int?
}

struct GuestBuilderPrunePayload: Decodable {
    struct Deleted: Decodable {
        let id: String
        let spaceReclaimed: Int64
    }

    let cachesDeleted: [Deleted]?
    let spaceReclaimed: Int64?
}
