import Foundation
import NIOCore
import Vapor

enum EngineContainerState: String, Sendable, Equatable {
    case created
    case running
    case paused
    case exited
}

enum DockerRuntimeGuestLimits {
    // Base64 encoding and the JSON envelope leave headroom below the guest's
    // 16 MiB frame limit. Larger archives need a streaming upload protocol.
    static let maximumImportArchiveBytes = 10 * 1024 * 1024
}

/// The Docker-facing operations needed by the runtime benchmark and its live
/// lifecycle test. GuestRuntime implements this protocol; the route layer owns
/// only Docker request and response semantics.
protocol DockerRuntimeRouteBackend: Sendable {
    func pullImage(
        reference: String, platform: String?, auth: DockerRegistryAuth?
    ) async throws -> DockerRuntimeImage
    func listImages() async throws -> [DockerRuntimeImage]
    func inspectImage(reference: String) async throws -> DockerRuntimeImage
    func deleteImage(reference: String, force: Bool) async throws -> DockerRuntimeImageDelete
    func pruneImages(all: Bool) async throws -> DockerRuntimeImageDelete
    func tagImage(source: String, target: String) async throws
    func pushImage(source: String, target: String, platform: String?, auth: DockerRegistryAuth?) async throws -> DockerRuntimeImage
    func exportImages(references: [String]) async throws -> AsyncThrowingStream<Data, Error>
    func importImages(data: Data) async throws -> [DockerRuntimeImage]
    func commitImage(
        container: String,
        repository: String?,
        tag: String?,
        comment: String?,
        author: String?,
        pause: Bool,
        changes: String?
    ) async throws -> DockerRuntimeImage
    func updateContainer(id: String, update: DockerRuntimeContainerUpdate) async throws -> [String]
    func createContainer(_ request: DockerRuntimeContainerCreate) async throws -> DockerRuntimeContainer
    func startContainer(id: String) async throws
    func pauseContainer(id: String) async throws
    func resumeContainer(id: String) async throws
    func resizeContainer(id: String, width: UInt32, height: UInt32) async throws
    func renameContainer(id: String, name: String) async throws
    func killContainer(id: String, signal: UInt32) async throws
    func waitContainer(id: String, condition: ContainerWaitCondition) async throws -> Int32
    func deleteContainer(id: String, force: Bool, removeVolumes: Bool) async throws
    func inspectContainer(id: String) async throws -> DockerRuntimeContainer
    func listContainers(showAll: Bool) async throws -> [DockerRuntimeContainer]
    func listNetworks() async throws -> [DockerRuntimeNetwork]
    func inspectNetwork(id: String) async throws -> DockerRuntimeNetwork
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
    ) async throws -> DockerRuntimeNetwork
    func connectNetwork(
        id: String,
        containerID: String,
        ipv4Address: String?,
        ipv6Address: String?
    ) async throws
    func disconnectNetwork(id: String, containerID: String, force: Bool) async throws
    func topContainer(id: String, psArguments: [String]) async throws -> DockerRuntimeTop
    func statsContainer(id: String) async throws -> DockerRuntimeStats
    func exportContainer(id: String) async throws -> AsyncThrowingStream<Data, Error>
    func archiveContainer(id: String, path: String) async throws -> AsyncThrowingStream<Data, Error>
    func archiveContainerInfo(id: String, path: String) async throws -> DockerRuntimeArchivePath
    func putContainerArchive(id: String, path: String, data: Data, noOverwriteDirNonDir: Bool) async throws
    func containerChanges(id: String) async throws -> [DockerRuntimeContainerChange]
    func createExec(_ request: DockerRuntimeExecCreate) async throws -> String
    func resizeExec(id: String, width: UInt32, height: UInt32) async throws
    func startExec(id: String, detach: Bool, tty: Bool) async throws -> DockerRuntimeProcessOutput
    func streamExec(id: String, tty: Bool) async throws -> AsyncThrowingStream<DockerRuntimeProcessFrame, Error>
    func logs(id: String, stdout: Bool, stderr: Bool) async throws -> DockerRuntimeProcessOutput
    func containerAutoRemove(id: String) async throws -> Bool
    func attachContainer(
        id: String, stdout: Bool, stderr: Bool
    ) async throws -> AsyncThrowingStream<DockerRuntimeProcessFrame, Error>
}

struct DockerRuntimeLogOptions: Sendable, Equatable {
    let timestamps: Bool
    let details: Bool
    let since: Int64?
    let until: Int64?

    var requiresGuestFiltering: Bool {
        timestamps || details || since != nil || until != nil
    }
}

protocol DockerRuntimeLogOptionsBackend: DockerRuntimeRouteBackend {
    func logs(
        id: String, stdout: Bool, stderr: Bool, options: DockerRuntimeLogOptions
    ) async throws -> DockerRuntimeProcessOutput
    func attachContainer(
        id: String, stdout: Bool, stderr: Bool, options: DockerRuntimeLogOptions
    ) async throws -> AsyncThrowingStream<DockerRuntimeProcessFrame, Error>
}

struct DockerRuntimeProcessFrame: Sendable {
    let stream: GuestStream?
    let data: Data
    let exitCode: Int32?
}

struct DockerRegistryAuth: Codable, Sendable, Equatable {
    let username: String?
    let password: String?
    let identitytoken: String?
    let serveraddress: String?
}

extension DockerRuntimeRouteBackend {
    func pushImage(source: String, target: String, platform: String?, auth: DockerRegistryAuth?) async throws -> DockerRuntimeImage {
        throw DockerRuntimeRouteError.invalidRequest("image push is not supported")
    }
    func exportImages(references: [String]) async throws -> AsyncThrowingStream<Data, Error> {
        throw DockerRuntimeRouteError.invalidRequest("image export is not supported")
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
        throw DockerRuntimeRouteError.invalidRequest("image commit is not supported")
    }
    func importImages(data: Data) async throws -> [DockerRuntimeImage] {
        throw DockerRuntimeRouteError.invalidRequest("image import is not supported")
    }
    func updateContainer(id: String, update: DockerRuntimeContainerUpdate) async throws -> [String] {
        throw DockerRuntimeRouteError.invalidRequest("container resource updates are not supported")
    }
    func topContainer(id: String, psArguments: [String]) async throws -> DockerRuntimeTop {
        throw DockerRuntimeRouteError.invalidRequest("container top is not supported")
    }
    func statsContainer(id: String) async throws -> DockerRuntimeStats {
        throw DockerRuntimeRouteError.invalidRequest("container stats are not supported")
    }
    func exportContainer(id: String) async throws -> AsyncThrowingStream<Data, Error> {
        throw DockerRuntimeRouteError.invalidRequest("container export is not supported")
    }
    func archiveContainer(id: String, path: String) async throws -> AsyncThrowingStream<Data, Error> {
        throw DockerRuntimeRouteError.invalidRequest("container archive is not supported")
    }
    func archiveContainerInfo(id: String, path: String) async throws -> DockerRuntimeArchivePath {
        throw DockerRuntimeRouteError.invalidRequest("container archive inspection is not supported")
    }
    func putContainerArchive(id: String, path: String, data: Data, noOverwriteDirNonDir: Bool) async throws {
        throw DockerRuntimeRouteError.invalidRequest("container archive upload is not supported")
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
        throw DockerRuntimeRouteError.invalidRequest("network creation is not supported")
    }
    func connectNetwork(
        id: String,
        containerID: String,
        ipv4Address: String?,
        ipv6Address: String?
    ) async throws {
        throw DockerRuntimeRouteError.invalidRequest("network connection is not supported")
    }
    func disconnectNetwork(id: String, containerID: String, force: Bool) async throws {
        throw DockerRuntimeRouteError.invalidRequest("network disconnection is not supported")
    }
    func containerChanges(id: String) async throws -> [DockerRuntimeContainerChange] {
        throw DockerRuntimeRouteError.invalidRequest("container changes are not supported")
    }
    func resizeExec(id: String, width: UInt32, height: UInt32) async throws {
        throw DockerRuntimeRouteError.invalidRequest("exec resize is not supported")
    }

    func containerAutoRemove(id: String) async throws -> Bool { false }
    func pauseContainer(id: String) async throws {
        throw DockerRuntimeRouteError.invalidRequest("container pause is not supported")
    }
    func resumeContainer(id: String) async throws {
        throw DockerRuntimeRouteError.invalidRequest("container resume is not supported")
    }
    func resizeContainer(id: String, width: UInt32, height: UInt32) async throws {
        throw DockerRuntimeRouteError.invalidRequest("container resize is not supported")
    }
    func renameContainer(id: String, name: String) async throws {
        throw DockerRuntimeRouteError.invalidRequest("container rename is not supported")
    }
    func killContainer(id: String, signal: UInt32) async throws {
        throw DockerRuntimeRouteError.invalidRequest("container signals are not supported")
    }

    func streamExec(
        id: String, tty: Bool
    ) async throws -> AsyncThrowingStream<DockerRuntimeProcessFrame, Error> {
        let output = try await startExec(id: id, detach: false, tty: tty)
        return AsyncThrowingStream { continuation in
            if !output.stdout.isEmpty {
                continuation.yield(.init(stream: .stdout, data: output.stdout, exitCode: nil))
            }
            if !output.stderr.isEmpty {
                continuation.yield(.init(stream: .stderr, data: output.stderr, exitCode: nil))
            }
            continuation.yield(.init(stream: nil, data: Data(), exitCode: output.exitCode))
            continuation.finish()
        }
    }

    func attachContainer(
        id: String, stdout: Bool, stderr: Bool
    ) async throws -> AsyncThrowingStream<DockerRuntimeProcessFrame, Error> {
        let output = try await logs(id: id, stdout: stdout, stderr: stderr)
        return AsyncThrowingStream { continuation in
            if !output.stdout.isEmpty {
                continuation.yield(.init(stream: .stdout, data: output.stdout, exitCode: nil))
            }
            if !output.stderr.isEmpty {
                continuation.yield(.init(stream: .stderr, data: output.stderr, exitCode: nil))
            }
            continuation.yield(.init(stream: nil, data: Data(), exitCode: output.exitCode))
            continuation.finish()
        }
    }
}

struct DockerRuntimeImage: Sendable, Equatable {
    let reference: String
    let digest: String
    let references: [String]
    let createdAt: Date
    let size: Int64
    let labels: [String: String]
    let rootFSLayers: [String]
    let history: [DockerRuntimeImageHistory]

    init(
        reference: String, digest: String, references: [String] = [],
        createdAt: Date = Date(timeIntervalSince1970: 0), size: Int64 = 0,
        labels: [String: String] = [:], rootFSLayers: [String] = [],
        history: [DockerRuntimeImageHistory] = []
    ) {
        self.reference = reference
        self.digest = digest
        self.references = references.isEmpty ? [reference] : references
        self.createdAt = createdAt
        self.size = size
        self.labels = labels
        self.rootFSLayers = rootFSLayers
        self.history = history
    }
}

struct DockerRuntimeImageHistory: Sendable, Equatable {
    let created: Date
    let createdBy: String
    let tags: [String]
    let size: Int64
    let comment: String
    let emptyLayer: Bool
}

struct DockerRuntimeTop: Sendable, Equatable, Codable {
    let Titles: [String]
    let Processes: [[String]]
}

struct DockerRuntimeStats: Sendable, Equatable, Codable {
    struct CPUUsage: Sendable, Equatable, Codable {
        let total_usage: UInt64
        let usage_in_kernelmode: UInt64
        let usage_in_usermode: UInt64
    }
    struct ThrottlingData: Sendable, Equatable, Codable {
        let throttled_periods: UInt64
        let throttled_time: UInt64
        let throttling_periods: UInt64
    }
    struct CPUStats: Sendable, Equatable, Codable {
        let cpu_usage: CPUUsage
        let system_cpu_usage: UInt64
        let online_cpus: Int
        let throttling_data: ThrottlingData
    }
    struct MemoryStats: Sendable, Equatable, Codable {
        let usage: UInt64
        let limit: UInt64
        let stats: [String: UInt64]?
    }
    struct NetworkStats: Sendable, Equatable, Codable {
        let rx_bytes: UInt64
        let rx_packets: UInt64
        let rx_errors: UInt64
        let rx_dropped: UInt64
        let tx_bytes: UInt64
        let tx_packets: UInt64
        let tx_errors: UInt64
        let tx_dropped: UInt64
    }
    struct BlkioStats: Sendable, Equatable, Codable {
        struct Entry: Sendable, Equatable, Codable {
            let major: UInt64
            let minor: UInt64
            let op: String
            let value: UInt64
        }
        let io_service_bytes_recursive: [Entry]?
    }
    struct PidsStats: Sendable, Equatable, Codable {
        let current: UInt64?
    }

    let id: String
    let read: String
    let preread: String
    let cpu_stats: CPUStats
    let precpu_stats: CPUStats
    let memory_stats: MemoryStats
    let networks: [String: NetworkStats]?
    let blkio_stats: BlkioStats
    let pids_stats: PidsStats
}

struct DockerRuntimeArchivePath: Sendable, Equatable {
    let name: String
    let size: Int64
    let mode: Int64
    let modifiedAt: Date
    let linkTarget: String
}

struct DockerRuntimeContainerChange: Sendable, Equatable {
    let path: String
    let kind: Int
}

struct DockerRuntimeImageDelete: Sendable, Equatable {
    let deleted: [String]
    let untagged: [String]
    let reclaimed: Int64
}

private struct DockerRuntimeNetworkPruneResponse: Encodable {
    let NetworksDeleted: [String]
    let Errors: [String: String]
}

private struct DockerRuntimeContainerUpdateResponse: Encodable {
    let Warnings: [String]
}

struct DockerRuntimeMount: Codable, Sendable, Equatable {
    let source: String
    let target: String
    let readOnly: Bool
    var volumeName: String? = nil
}

struct DockerRuntimePortBinding: Codable, Sendable, Equatable {
    let containerPort: Int
    let proto: String
    let hostIP: String
    let hostPort: Int?

    enum CodingKeys: String, CodingKey {
        case containerPort
        case proto = "protocol"
        case hostIP
        case hostPort
    }

    init(containerPort: Int, proto: String, hostIP: String, hostPort: Int?) {
        self.containerPort = containerPort
        self.proto = proto
        self.hostIP = hostIP
        self.hostPort = hostPort
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        containerPort = try values.decode(Int.self, forKey: .containerPort)
        proto = try values.decodeIfPresent(String.self, forKey: .proto) ?? "tcp"
        hostIP = try values.decodeIfPresent(String.self, forKey: .hostIP) ?? "0.0.0.0"
        hostPort = try values.decodeIfPresent(Int.self, forKey: .hostPort)
    }
}

struct DockerRuntimeContainerCreate: Sendable, Equatable {
    let name: String?
    let image: String
    let command: [String]
    let entrypoint: [String]?
    let cmd: [String]?
    let environment: [String]
    let workingDirectory: String?
    let user: String?
    let hostname: String?
    let labels: [String: String]
    let tty: Bool
    let autoRemove: Bool
    let mounts: [DockerRuntimeMount]
    let ports: [DockerRuntimePortBinding]
}

struct DockerRuntimeContainer: Sendable, Equatable {
    let id: String
    let name: String
    let image: String
    let command: [String]
    let createdAt: Date
    let state: EngineContainerState
    let exitCode: Int32?
    let labels: [String: String]
    let tty: Bool
    let ports: [DockerRuntimePortBinding]
}

struct DockerRuntimeContainerUpdate: Decodable, Sendable, Equatable {
    let cpuShares: Int64?
    let memory: Int64?
    let memorySwap: Int64?
    let memoryReservation: Int64?
    let cpuPeriod: Int64?
    let cpuQuota: Int64?
    let cpusetCpus: String?
    let cpusetMems: String?
    let pidsLimit: Int64?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case cpuShares = "CpuShares"
        case memory = "Memory"
        case memorySwap = "MemorySwap"
        case memoryReservation = "MemoryReservation"
        case cpuPeriod = "CpuPeriod"
        case cpuQuota = "CpuQuota"
        case cpusetCpus = "CpusetCpus"
        case cpusetMems = "CpusetMems"
        case pidsLimit = "PidsLimit"
    }

    static let supportedDockerFields = Set(CodingKeys.allCases.map(\.stringValue))

    func validate() throws {
        if let cpuShares, cpuShares < 0 {
            throw DockerRuntimeRouteError.invalidRequest("CpuShares must be non-negative")
        }
        if let memory, memory < 0 {
            throw DockerRuntimeRouteError.invalidRequest("Memory must be non-negative")
        }
        if let memorySwap, memorySwap < -1 {
            throw DockerRuntimeRouteError.invalidRequest("MemorySwap must be -1 or non-negative")
        }
        if let memoryReservation, memoryReservation < 0 {
            throw DockerRuntimeRouteError.invalidRequest("MemoryReservation must be non-negative")
        }
        if let cpuPeriod, cpuPeriod < 0 {
            throw DockerRuntimeRouteError.invalidRequest("CpuPeriod must be non-negative")
        }
        if let cpuQuota, cpuQuota < -1 {
            throw DockerRuntimeRouteError.invalidRequest("CpuQuota must be -1 or non-negative")
        }
        if let pidsLimit, pidsLimit < -1 {
            throw DockerRuntimeRouteError.invalidRequest("PidsLimit must be -1 or non-negative")
        }
    }
}

struct DockerRuntimeNetworkContainer: Sendable {
    let name: String
    let endpointID: String?
    let macAddress: String?
    let ipv4Address: String
    let ipv6Address: String?
}

struct DockerRuntimeNetwork: Sendable {
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
    let ipam: NetworkIPAM
    let options: [String: String]
    let containers: [String: DockerRuntimeNetworkContainer]
    let labels: [String: String]
}

struct DockerRuntimeNetworkIPAM: Sendable, Equatable {
    let driver: String?
    let config: [DockerRuntimeNetworkIPAMConfig]
}

struct DockerRuntimeNetworkIPAMConfig: Sendable, Equatable {
    let subnet: String?
    let ipRange: String?
    let gateway: String?
    let auxiliaryAddresses: [String: String]?
}

struct DockerRuntimeExecCreate: Sendable, Equatable {
    let containerID: String
    let command: [String]
    let environment: [String]
    let workingDirectory: String?
    let user: String?
    let tty: Bool
    let attachStdout: Bool
    let attachStderr: Bool
}

struct DockerRuntimeProcessOutput: Sendable, Equatable {
    let stdout: Data
    let stderr: Data
    let exitCode: Int32

    init(stdout: Data = Data(), stderr: Data = Data(), exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

enum DockerRuntimeRouteError: Error, Equatable {
    case notFound(String)
    case conflict(String)
    case invalidRequest(String)
}

private struct DockerStopTimeout: Error {}

private final class DockerRuntimeExecState: @unchecked Sendable {
    struct Entry: Sendable {
        let request: DockerRuntimeExecCreate
        var running = false
        var exitCode: Int32?
    }

    private var entries: [String: Entry] = [:]
    private let lock = NSLock()

    func insert(id: String, request: DockerRuntimeExecCreate) {
        lock.withLock { entries[id] = Entry(request: request) }
    }

    func entry(id: String) -> Entry? { lock.withLock { entries[id] } }

    func markRunning(id: String) throws {
        try lock.withLock {
            guard var entry = entries[id] else {
                throw DockerRuntimeRouteError.notFound("Exec instance (id)")
            }
            guard !entry.running, entry.exitCode == nil else {
                throw DockerRuntimeRouteError.conflict("Exec instance (id) has already been started")
            }
            entry.running = true
            entries[id] = entry
        }
    }

    func finish(id: String, exitCode: Int32) {
        lock.withLock {
            guard var entry = entries[id] else { return }
            entry.running = false
            entry.exitCode = exitCode
            entries[id] = entry
        }
    }
}

struct DockerRuntimeRoutes: RouteCollection {
    let backend: any DockerRuntimeRouteBackend
    let volumeClient: (any ClientVolumeProtocol)?
    private let execState = DockerRuntimeExecState()

    init(
        backend: any DockerRuntimeRouteBackend,
        volumeClient: (any ClientVolumeProtocol)? = nil
    ) {
        self.backend = backend
        self.volumeClient = volumeClient
    }

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/images/load", use: importImages)
        try routes.registerVersionedRoute(.POST, pattern: "/images/create", use: pullImage)
        try routes.registerVersionedRoute(.GET, pattern: "/images/json", use: listImages)
        try routes.registerVersionedRoute(.GET, pattern: "/images/{name:.*}/json", use: inspectImage)
        try routes.registerVersionedRoute(.DELETE, pattern: "/images/{name:.*}", use: deleteImage)
        try routes.registerVersionedRoute(.POST, pattern: "/images/prune", use: pruneImages)
        try routes.registerVersionedRoute(.POST, pattern: "/images/{name:.*}/tag", use: tagImage)
        try routes.registerVersionedRoute(.GET, pattern: "/images/get", use: exportImages)
        try routes.registerVersionedRoute(.GET, pattern: "/images/{name:.*}/get", use: exportNamedImage)
        try routes.registerVersionedRoute(.GET, pattern: "/images/{name:.*}/history", use: imageHistory)
        try routes.registerVersionedRoute(.POST, pattern: "/images/{name:.*}/push", use: pushImage)
        try routes.registerVersionedRoute(.POST, pattern: "/commit", use: commitImage)
        try routes.registerVersionedRoute(.GET, pattern: "/info", use: info)
        try routes.registerVersionedRoute(.GET, pattern: "/system/df", use: systemDataUsage)
        try routes.registerVersionedRoute(.POST, pattern: "/networks/create", use: createNetwork)
        try routes.registerVersionedRoute(.POST, pattern: "/networks/{id:.*}/connect", use: connectNetwork)
        try routes.registerVersionedRoute(.POST, pattern: "/networks/{id:.*}/disconnect", use: disconnectNetwork)
        try routes.registerVersionedRoute(.GET, pattern: "/networks", use: listNetworks)
        try routes.registerVersionedRoute(.GET, pattern: "/networks/{id:.*}", use: inspectNetwork)
        try routes.registerVersionedRoute(.POST, pattern: "/networks/prune", use: pruneNetworks)
        try routes.registerVersionedRoute(.DELETE, pattern: "/networks/{id:.*}", use: deleteNetwork)
        try routes.registerVersionedRoute(.POST, pattern: "/containers/create", use: createContainer)
        try routes.registerVersionedRoute(.POST, pattern: "/containers/{id:.*}/update", use: updateContainer)
        try routes.registerVersionedRoute(.POST, pattern: "/containers/prune", use: pruneContainers)
        try routes.registerVersionedRoute(.POST, pattern: "/containers/{id:.*}/start", use: startContainer)
        try routes.registerVersionedRoute(.POST, pattern: "/containers/{id:.*}/pause", use: pauseContainer)
        try routes.registerVersionedRoute(.POST, pattern: "/containers/{id:.*}/unpause", use: unpauseContainer)
        try routes.registerVersionedRoute(.POST, pattern: "/containers/{id:.*}/rename", use: renameContainer)
        try routes.registerVersionedRoute(.POST, pattern: "/containers/{id:.*}/resize", use: resizeContainer)
        try routes.registerVersionedRoute(.POST, pattern: "/containers/{id:.*}/restart", use: restartContainer)
        try routes.registerVersionedRoute(.POST, pattern: "/containers/{id:.*}/stop", use: stopContainer)
        try routes.registerVersionedRoute(.POST, pattern: "/containers/{id:.*}/kill", use: killContainer)
        try routes.registerVersionedRoute(.POST, pattern: "/containers/{id:.*}/wait", use: waitContainer)
        try routes.registerVersionedRoute(.DELETE, pattern: "/containers/{id:.*}", use: deleteContainer)
        try routes.registerVersionedRoute(.GET, pattern: "/containers/{id:.*}/json", use: inspectContainer)
        try routes.registerVersionedRoute(.GET, pattern: "/containers/json", use: listContainers)
        try routes.registerVersionedRoute(.GET, pattern: "/containers/{id:.*}/top", use: topContainer)
        try routes.registerVersionedRoute(.GET, pattern: "/containers/{id:.*}/stats", use: statsContainer)
        try routes.registerVersionedRoute(.GET, pattern: "/containers/{id:.*}/export", use: exportContainer)
        try routes.registerVersionedRoute(.GET, pattern: "/containers/{id:.*}/archive", use: archiveContainer)
        try routes.registerVersionedRoute(.HEAD, pattern: "/containers/{id:.*}/archive", use: archiveInfo)
        try routes.registerVersionedRoute(.PUT, pattern: "/containers/{id:.*}/archive", use: putArchive)
        try routes.registerVersionedRoute(.GET, pattern: "/containers/{id:.*}/changes", use: containerChanges)
        try routes.registerVersionedRoute(.POST, pattern: "/containers/{id:.*}/exec", use: createExec)
        try routes.registerVersionedRoute(.POST, pattern: "/exec/{id:.*}/resize", use: resizeExec)
        try routes.registerVersionedRoute(.POST, pattern: "/exec/{id:.*}/start", use: startExec)
        try routes.registerVersionedRoute(.GET, pattern: "/exec/{id:.*}/json", use: inspectExec)
        try routes.registerVersionedRoute(.GET, pattern: "/containers/{id:.*}/logs", use: logs)
        try routes.registerVersionedRoute(.POST, pattern: "/containers/{id:.*}/attach", use: attach)
        try routes.registerVersionedRoute(.GET, pattern: "/containers/{id:.*}/attach/ws", use: attachWebSocket)
    }

    private func pullImage(_ req: Request) async throws -> Response {
        if req.query[String.self, at: "fromSrc"] != nil {
            return try await importImage(req)
        }
        let fromImage = try requiredQuery("fromImage", request: req)
        let tag = req.query[String.self, at: "tag"]
        let reference = Self.imageReference(fromImage: fromImage, tag: tag)
        let auth = try Self.registryAuth(req.headers.first(name: "X-Registry-Auth"))
        let image = try await call {
            try await backend.pullImage(
                reference: reference,
                platform: req.query[String.self, at: "platform"],
                auth: auth
            )
        }
        struct PullProgress: Encodable {
            let status: String
            let id: String
        }
        var body = try JSONEncoder().encode(
            PullProgress(status: "Status: Downloaded newer image for \(image.reference)", id: image.digest)
        )
        body.append(0x0A)
        let response = Response(status: .ok, body: .init(data: body))
        response.headers.contentType = .json
        return response
    }

    private func importImages(_ req: Request) async throws -> Response {
        try await importImage(req)
    }

    private func importImage(_ req: Request) async throws -> Response {
        guard
            let buffer = try await req.body.collect(max: DockerRuntimeGuestLimits.maximumImportArchiveBytes).get(),
            let data = buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes),
            !data.isEmpty
        else {
            throw Abort(.badRequest, reason: "Image archive request body is required")
        }
        let images = try await call { try await backend.importImages(data: data) }
        var body = Data()
        for image in images {
            body.append(
                try JSONEncoder().encode(
                    ImageImportProgress(stream: "Loaded image: \(image.reference)\n")
                )
            )
            body.append(0x0A)
        }
        let response = Response(status: .ok, body: .init(data: body))
        response.headers.contentType = .json
        return response
    }

    private func info(_ req: Request) async throws -> Response {
        let containers = try await call { try await backend.listContainers(showAll: true) }
        let images = try await call { try await backend.listImages() }
        let running = containers.filter { $0.state == .running }.count
        let paused = containers.filter { $0.state == .paused }.count
        let stopped = containers.count - running - paused
        let environment = ProcessInfo.processInfo.environment
        let info = SystemInfo(
            Containers: containers.count,
            ContainersRunning: running,
            ContainersPaused: paused,
            ContainersStopped: stopped,
            Images: images.count,
            DockerRootDir: GlassDockDirectories.engineStateDirectory.path,
            Debug: false,
            KernelVersion: getKernel(),
            OSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            OSType: "linux",
            Architecture: "arm64",
            NCPU: ProcessInfo.processInfo.activeProcessorCount,
            MemTotal: Int64(min(ProcessInfo.processInfo.physicalMemory, UInt64(Int64.max))),
            HttpProxy: environment["HTTP_PROXY"] ?? environment["http_proxy"],
            HttpsProxy: environment["HTTPS_PROXY"] ?? environment["https_proxy"],
            NoProxy: environment["NO_PROXY"] ?? environment["no_proxy"],
            Name: ProcessInfo.processInfo.hostName,
            Labels: [],
            ExperimentalBuild: false,
            ServerVersion: getBuildVersion(),
            ProductLicense: "Apache-2.0",
            SystemTime: ISO8601DateFormatter().string(from: Date()),
            Warnings: [
                "Some Docker Engine capabilities are unavailable because Glass Dock uses a persistent containerd guest runtime."
            ]
        )
        return try jsonResponse(.ok, info)
    }

    private func listImages(_ req: Request) async throws -> Response {
        let filters = try Self.imageFilters(req.query[String.self, at: "filters"])
        try Self.validateImageFilters(filters)
        let images = try await call { try await backend.listImages() }
        let filtered = try Self.applyImageFilters(images, filters: filters)
        return try jsonResponse(.ok, filtered.map(ImageSummary.init))
    }

    private func inspectImage(_ req: Request) async throws -> Response {
        let reference = try requiredParameter("name", request: req)
        let image = try await call { try await backend.inspectImage(reference: reference) }
        return try jsonResponse(.ok, ImageInspectResponse(image))
    }

    private func deleteImage(_ req: Request) async throws -> Response {
        let reference = try requiredParameter("name", request: req)
        let result = try await call {
            try await backend.deleteImage(
                reference: reference,
                force: Self.mobyBool(req.query[String.self, at: "force"])
            )
        }
        return try jsonResponse(.ok, Self.imageDeleteItems(result))
    }

    private func pruneImages(_ req: Request) async throws -> Response {
        let all = Self.pruneAll(req.query[String.self, at: "filters"])
        let result = try await call { try await backend.pruneImages(all: all) }
        return try jsonResponse(
            .ok,
            ImagePruneResponse(
                ImagesDeleted: Self.imageDeleteItems(result),
                SpaceReclaimed: result.reclaimed
            )
        )
    }

    private func pruneContainers(_ req: Request) async throws -> Response {
        let filters = try req.query[String.self, at: "filters"].map(Self.containerPruneFilters)
        let containers = try await call { try await backend.listContainers(showAll: true) }
        let candidates = containers.filter { container in
            container.state != .running
                && (filters.map { Self.matches(container, filters: $0) } ?? true)
        }
        var deleted: [String] = []
        for container in candidates {
            try await call {
                try await backend.deleteContainer(id: container.id, force: false, removeVolumes: false)
            }
            deleted.append(container.id)
        }
        return try jsonResponse(
            .ok,
            ContainerPruneResponse(ContainersDeleted: deleted, SpaceReclaimed: 0)
        )
    }

    private func tagImage(_ req: Request) async throws -> Response {
        let source = try requiredParameter("name", request: req)
        let repo = try requiredQuery("repo", request: req)
        let tag = req.query[String.self, at: "tag"]
        let target = Self.imageReference(fromImage: repo, tag: tag)
        try await call { try await backend.tagImage(source: source, target: target) }
        return Response(status: .created)
    }

    private func pushImage(_ req: Request) async throws -> Response {
        let source = try requiredParameter("name", request: req)
        let tag = req.query[String.self, at: "tag"]
        let target = Self.imageReference(fromImage: source, tag: tag)
        let auth = try Self.registryAuth(req.headers.first(name: "X-Registry-Auth"))
        let image = try await call {
            try await backend.pushImage(
                source: source,
                target: target,
                platform: req.query[String.self, at: "platform"],
                auth: auth
            )
        }
        struct PushProgress: Encodable {
            let status: String
            let id: String
        }
        var body = try JSONEncoder().encode(PushProgress(status: "Pushed (target)", id: image.digest))
        body.append(0x0A)
        let response = Response(status: .ok, body: .init(data: body))
        response.headers.contentType = .json
        return response
    }

    private func commitImage(_ req: Request) async throws -> Response {
        let container = try requiredQuery("container", request: req)
        let image = try await call {
            try await backend.commitImage(
                container: container,
                repository: req.query[String.self, at: "repo"],
                tag: req.query[String.self, at: "tag"],
                comment: req.query[String.self, at: "comment"],
                author: req.query[String.self, at: "author"],
                pause: req.query[String.self, at: "pause"].map(Self.mobyBool) ?? true,
                changes: req.query[String.self, at: "changes"]
            )
        }
        struct CommitResponse: Encodable {
            let Id: String
        }
        return try jsonResponse(.ok, CommitResponse(Id: image.digest))
    }

    private func imageHistory(_ req: Request) async throws -> Response {
        let reference = try requiredParameter("name", request: req)
        let image = try await call { try await backend.inspectImage(reference: reference) }
        let tags = image.references.filter { !$0.contains("@sha256:") }
        let history: [ImageHistoryResponseItem]
        if image.history.isEmpty {
            history = [
                ImageHistoryResponseItem(
                    Id: image.digest,
                    Created: Int64(image.createdAt.timeIntervalSince1970),
                    CreatedBy: "",
                    Tags: tags,
                    Size: image.size,
                    Comment: ""
                )
            ]
        } else {
            var layerIndex = 0
            history = image.history.reversed().map { entry in
                let id: String
                let size: Int64
                if entry.emptyLayer {
                    id = "<missing>"
                    size = 0
                } else if layerIndex < image.rootFSLayers.count {
                    id = image.rootFSLayers[image.rootFSLayers.count - layerIndex - 1]
                    size = entry.size
                    layerIndex += 1
                } else {
                    id = "<missing>"
                    size = entry.size
                }
                return ImageHistoryResponseItem(
                    Id: id,
                    Created: Int64(entry.created.timeIntervalSince1970),
                    CreatedBy: entry.createdBy,
                    Tags: layerIndex == 1 ? tags : entry.tags,
                    Size: size,
                    Comment: entry.comment
                )
            }
        }
        return try jsonResponse(.ok, history)
    }

    private func exportImages(_ req: Request) async throws -> Response {
        let references = try Self.imageExportReferences(req.query[String.self, at: "names"])
        return try await imageExportResponse(references: references)
    }

    private func exportNamedImage(_ req: Request) async throws -> Response {
        let reference = try requiredParameter("name", request: req)
        return try await imageExportResponse(references: [reference])
    }

    private func imageExportResponse(references: [String]) async throws -> Response {
        let stream = try await call { try await backend.exportImages(references: references) }
        var headers = HTTPHeaders()
        headers.contentType = HTTPMediaType(type: "application", subType: "x-tar")
        return Response(
            status: .ok,
            headers: headers,
            body: .init(managedAsyncStream: { writer in
                for try await data in stream {
                    try await writer.writeBuffer(ByteBuffer(data: data))
                }
            })
        )
    }

    private func createContainer(_ req: Request) async throws -> Response {
        let body: CreateRequest
        do {
            guard let buffer = try await req.body.collect(max: req.application.routes.defaultMaxBodySize.value).get(),
                let data = buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes)
            else {
                throw DockerRuntimeRouteError.invalidRequest("request body is required")
            }
            try Self.validateCreateOptions(data)
            body = try JSONDecoder().decode(CreateRequest.self, from: data)
        } catch let abort as Abort {
            throw abort
        } catch {
            throw Abort(.badRequest, reason: "Invalid container create request: \(error)")
        }
        guard !body.Image.isEmpty else { throw Abort(.badRequest, reason: "No image specified") }
        let mounts = try await mounts(from: body.HostConfig)
        let request = DockerRuntimeContainerCreate(
            name: req.query[String.self, at: "name"],
            image: body.Image,
            command: (body.Entrypoint ?? []) + (body.Cmd ?? []),
            entrypoint: body.Entrypoint,
            cmd: body.Cmd,
            environment: body.Env ?? [],
            workingDirectory: body.WorkingDir,
            user: body.User,
            hostname: body.Hostname,
            labels: body.Labels ?? [:],
            tty: body.Tty ?? false,
            autoRemove: body.HostConfig?.AutoRemove ?? false,
            mounts: mounts,
            ports: Self.ports(from: body.HostConfig)
        )
        let container = try await call { try await backend.createContainer(request) }
        if let volumes = volumeClient as? RuntimeVolumeService {
            do {
                try await volumes.retain(
                    names: Set(mounts.compactMap(\.volumeName)), containerID: container.id)
            } catch {
                try? await backend.deleteContainer(
                    id: container.id, force: true, removeVolumes: false)
                throw error
            }
        }
        return try jsonResponse(.created, RESTContainerCreate(Id: container.id, Warnings: []))
    }

    private func updateContainer(_ req: Request) async throws -> Response {
        let id = try requiredParameter("id", request: req)
        let update = try await decodeContainerUpdate(req)
        let warnings = try await call {
            try await backend.updateContainer(id: id, update: update)
        }
        return try jsonResponse(
            .ok,
            DockerRuntimeContainerUpdateResponse(Warnings: warnings)
        )
    }

    private func startContainer(_ req: Request) async throws -> Response {
        let id = try requiredParameter("id", request: req)
        try await call { try await backend.startContainer(id: id) }
        return Response(status: .noContent)
    }

    private func pauseContainer(_ req: Request) async throws -> Response {
        let id = try requiredParameter("id", request: req)
        try await call { try await backend.pauseContainer(id: id) }
        return Response(status: .noContent)
    }

    private func unpauseContainer(_ req: Request) async throws -> Response {
        let id = try requiredParameter("id", request: req)
        try await call { try await backend.resumeContainer(id: id) }
        return Response(status: .noContent)
    }

    private func renameContainer(_ req: Request) async throws -> Response {
        let id = try requiredParameter("id", request: req)
        let body = try req.content.decode(RenameRequest.self)
        let name = body.Name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !name.isEmpty else { throw Abort(.badRequest, reason: "Container name cannot be empty") }
        guard DockerContainerMetadataStore.isValid(name) else {
            throw Abort(.badRequest, reason: "Invalid container name: \(body.Name)")
        }
        try await call { try await backend.renameContainer(id: id, name: name) }
        return Response(status: .noContent)
    }

    private func resizeContainer(_ req: Request) async throws -> Response {
        let id = try requiredParameter("id", request: req)
        guard let width = req.query[UInt32.self, at: "w"],
            let height = req.query[UInt32.self, at: "h"], width > 0, height > 0
        else {
            throw Abort(.badRequest, reason: "Both w and h must be positive integers")
        }
        try await call { try await backend.resizeContainer(id: id, width: width, height: height) }
        return Response(status: .noContent)
    }

    private func restartContainer(_ req: Request) async throws -> Response {
        let id = try requiredParameter("id", request: req)
        let timeout = max(0, req.query[Int.self, at: "t"] ?? 10)
        let container = try await call { try await backend.inspectContainer(id: id) }
        if container.state == .running || container.state == .paused {
            if container.state == .paused {
                try await call { try await backend.resumeContainer(id: id) }
            }
            let signalText = req.query[String.self, at: "signal"] ?? "TERM"
            guard let signal = DockerSignal.number(signalText) else {
                throw Abort(.badRequest, reason: "Invalid restart signal: \(signalText)")
            }
            try await call { try await backend.killContainer(id: id, signal: signal) }
            let wait = Task { try await backend.waitContainer(id: id, condition: .notRunning) }
            do {
                _ = try await withThrowingTaskGroup(of: Int32.self) { group in
                    group.addTask { try await wait.value }
                    group.addTask {
                        try await Task.sleep(for: .seconds(timeout))
                        throw DockerStopTimeout()
                    }
                    defer { group.cancelAll() }
                    guard let result = try await group.next() else { throw DockerStopTimeout() }
                    return result
                }
            } catch is DockerStopTimeout {
                try await call { try await backend.killContainer(id: id, signal: 9) }
                _ = try await wait.value
            }
        }
        try await call { try await backend.startContainer(id: id) }
        return Response(status: .noContent)
    }

    private func waitContainer(_ req: Request) async throws -> Response {
        let id = try requiredParameter("id", request: req)
        let raw = req.query[String.self, at: "condition"]
        let condition: ContainerWaitCondition
        if let raw {
            guard let parsed = ContainerWaitCondition(rawValue: raw) else {
                throw Abort(.badRequest, reason: "Unsupported wait condition: \(raw)")
            }
            condition = parsed
        } else {
            condition = .default
        }
        if condition == .healthy {
            throw Abort(.notImplemented, reason: "healthy wait is not supported by the persistent runtime")
        }
        let backend = self.backend
        var headers = HTTPHeaders()
        headers.contentType = .json
        return Response(
            status: .ok,
            headers: headers,
            body: .init(managedAsyncStream: { writer in
                let exitCode = try await backend.waitContainer(id: id, condition: condition)
                let data = try JSONEncoder().encode(RESTContainerWait(statusCode: Int64(exitCode)))
                try await writer.writeBuffer(ByteBuffer(bytes: data))
            })
        )
    }

    private func stopContainer(_ req: Request) async throws -> Response {
        let id = try requiredParameter("id", request: req)
        let container = try await call { try await backend.inspectContainer(id: id) }
        guard container.state == .running else { return Response(status: .notModified) }
        let signalText = req.query[String.self, at: "signal"] ?? "TERM"
        guard let signal = DockerSignal.number(signalText) else {
            throw Abort(.badRequest, reason: "Invalid stop signal: \(signalText)")
        }
        let timeout = max(0, req.query[Int.self, at: "t"] ?? 10)
        try await call { try await backend.killContainer(id: id, signal: signal) }
        let wait = Task { try await backend.waitContainer(id: id, condition: .notRunning) }
        do {
            _ = try await withThrowingTaskGroup(of: Int32.self) { group in
                group.addTask { try await wait.value }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    throw DockerStopTimeout()
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else {
                    throw DockerStopTimeout()
                }
                return result
            }
        } catch is DockerStopTimeout {
            try await call { try await backend.killContainer(id: id, signal: 9) }
            _ = try await wait.value
        }
        return Response(status: .noContent)
    }

    private func killContainer(_ req: Request) async throws -> Response {
        let id = try requiredParameter("id", request: req)
        let signalText = req.query[String.self, at: "signal"] ?? "KILL"
        guard let signal = DockerSignal.number(signalText) else {
            throw Abort(.badRequest, reason: "Invalid signal: \(signalText)")
        }
        try await call { try await backend.killContainer(id: id, signal: signal) }
        return Response(status: .noContent)
    }

    private func deleteContainer(_ req: Request) async throws -> Response {
        let id = try requiredParameter("id", request: req)
        try await call {
            try await backend.deleteContainer(
                id: id,
                force: Self.mobyBool(req.query[String.self, at: "force"]),
                removeVolumes: Self.mobyBool(req.query[String.self, at: "v"])
            )
        }
        if let volumes = volumeClient as? RuntimeVolumeService {
            try await volumes.release(containerID: id)
        }
        return Response(status: .noContent)
    }

    private func inspectContainer(_ req: Request) async throws -> Response {
        let container = try await call { try await backend.inspectContainer(id: requiredParameter("id", request: req)) }
        return try jsonResponse(.ok, InspectResponse(container))
    }

    private func listContainers(_ req: Request) async throws -> Response {
        var containers = try await call {
            try await backend.listContainers(showAll: Self.mobyBool(req.query[String.self, at: "all"]))
        }
        if let raw = req.query[String.self, at: "filters"] {
            let filters = try Self.containerFilters(raw)
            containers = containers.filter { Self.matches($0, filters: filters) }
        }
        return try jsonResponse(.ok, containers.map(ListResponse.init))
    }

    private func createNetwork(_ req: Request) async throws -> Response {
        let body = try req.content.decode(DockerNetworkCreateRequest.self)
        guard !body.Name.isEmpty else {
            throw Abort(.badRequest, reason: "Network name is required")
        }
        let network = try await call {
            try await backend.createNetwork(
                name: body.Name,
                driver: body.Driver,
                scope: body.Scope,
                enableIPv4: body.EnableIPv4,
                enableIPv6: body.EnableIPv6,
                internalNetwork: body.Internal,
                attachable: body.Attachable,
                ingress: body.Ingress,
                ipam: body.IPAM.map { $0.runtimeIPAM },
                options: body.Options,
                labels: body.Labels
            )
        }
        return try jsonResponse(.created, RESTNetworkCreate(Id: network.id, Warning: ""))
    }

    private func connectNetwork(_ req: Request) async throws -> Response {
        let id = try requiredParameter("id", request: req)
        let body = try req.content.decode(DockerNetworkConnectRequest.self)
        guard !body.Container.isEmpty else {
            throw Abort(.badRequest, reason: "Container is required")
        }
        try await call {
            try await backend.connectNetwork(
                id: id,
                containerID: body.Container,
                ipv4Address: body.EndpointConfig?.IPAMConfig?.IPv4Address,
                ipv6Address: body.EndpointConfig?.IPAMConfig?.IPv6Address
            )
        }
        return Response(status: .ok)
    }

    private func disconnectNetwork(_ req: Request) async throws -> Response {
        let id = try requiredParameter("id", request: req)
        let body = try req.content.decode(DockerNetworkDisconnectRequest.self)
        guard !body.Container.isEmpty else {
            throw Abort(.badRequest, reason: "Container is required")
        }
        try await call {
            try await backend.disconnectNetwork(
                id: id,
                containerID: body.Container,
                force: body.Force ?? false
            )
        }
        return Response(status: .ok)
    }

    private func listNetworks(_ req: Request) async throws -> Response {
        let networks = try await call { try await backend.listNetworks() }
        let filters = try DockerNetworkFilterUtility.parseNetworkFilters(
            filtersParam: req.query[String.self, at: "filters"],
            defaultDangling: false,
            logger: req.logger
        )
        let filtersData = try JSONEncoder().encode(filters)
        let filtersJSON = String(data: filtersData, encoding: .utf8)
        let summaries = ClientNetworkService.applyFilters(
            networks.map(Self.networkSummary), filters: filtersJSON, logger: req.logger
        )
        return try jsonResponse(.ok, summaries)
    }

    private func inspectNetwork(_ req: Request) async throws -> Response {
        let id = try requiredParameter("id", request: req)
        let network = try await call { try await backend.inspectNetwork(id: id) }
        return try jsonResponse(.ok, Self.networkSummary(network))
    }

    private func pruneNetworks(_ req: Request) async throws -> Response {
        let filters = try DockerNetworkFilterUtility.parseNetworkFilters(
            filtersParam: req.query[String.self, at: "filters"],
            defaultDangling: true,
            logger: req.logger
        )
        let filtersData = try JSONEncoder().encode(filters)
        let filtersJSON = String(data: filtersData, encoding: .utf8)
        let networks = try await call { try await backend.listNetworks() }
        let candidates = ClientNetworkService.applyFilters(
            networks.map(Self.networkSummary), filters: filtersJSON, logger: req.logger
        )

        // The guest runtime currently exposes only its persistent bridge. Do
        // not report it as deleted, even when it matches a dangling filter.
        // If a future guest adds custom network summaries before deletion is
        // implemented, surface that limitation in Docker's Errors field.
        let errors = candidates.reduce(into: [String: String]()) { result, network in
            guard network.Id != "glassdock0", network.Name != "bridge" else { return }
            result[network.Id] = "custom guest network deletion is not supported"
        }
        if let broadcaster = req.application.storage[EventBroadcasterKey.self] {
            await broadcaster.broadcast(
                DockerEvent.make(
                    type: "network", action: "prune", actorID: "",
                    attributes: ["reclaimed": "0"]))
        }
        return try jsonResponse(
            .ok,
            DockerRuntimeNetworkPruneResponse(NetworksDeleted: [], Errors: errors)
        )
    }

    private func deleteNetwork(_ req: Request) async throws -> Response {
        let id = try requiredParameter("id", request: req)
        let network = try await call { try await backend.inspectNetwork(id: id) }
        guard Self.isProtectedGuestNetwork(network) else {
            throw Abort(.notImplemented, reason: "Custom guest network deletion is not supported")
        }
        throw Abort(.forbidden, reason: "error while removing network: \(network.name) is a protected guest network")
    }

    private func topContainer(_ req: Request) async throws -> Response {
        let id = try requiredParameter("id", request: req)
        let arguments =
            req.query[String.self, at: "ps_args"]?
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init) ?? []
        let top = try await call {
            try await backend.topContainer(id: id, psArguments: arguments)
        }
        return try jsonResponse(.ok, top)
    }

    private func statsContainer(_ req: Request) async throws -> Response {
        let id = try requiredParameter("id", request: req)
        let stream = req.query[String.self, at: "stream"].map(Self.mobyBool) ?? true
        let oneShot = req.query[String.self, at: "one-shot"].map(Self.mobyBool) ?? false
        let backend = self.backend
        var headers = HTTPHeaders()
        headers.contentType = .json
        return Response(
            status: .ok,
            headers: headers,
            body: .init(managedAsyncStream: { writer in
                repeat {
                    let stats = try await backend.statsContainer(id: id)
                    var data = try JSONEncoder().encode(stats)
                    if stream { data.append(0x0A) }
                    try await writer.writeBuffer(ByteBuffer(data: data))
                    if !stream || oneShot { break }
                    try await Task.sleep(for: .seconds(1))
                } while !Task.isCancelled
            })
        )
    }

    private func exportContainer(_ req: Request) async throws -> Response {
        let id = try requiredParameter("id", request: req)
        let stream = try await call { try await backend.exportContainer(id: id) }
        var headers = HTTPHeaders()
        headers.contentType = HTTPMediaType(type: "application", subType: "octet-stream")
        return Response(
            status: .ok,
            headers: headers,
            body: .init(managedAsyncStream: { writer in
                for try await data in stream {
                    try await writer.writeBuffer(ByteBuffer(data: data))
                }
            })
        )
    }

    private func archiveContainer(_ req: Request) async throws -> Response {
        let id = try requiredParameter("id", request: req)
        let path = try requiredQuery("path", request: req)
        let info = try await call { try await backend.archiveContainerInfo(id: id, path: path) }
        let stream = try await call { try await backend.archiveContainer(id: id, path: path) }
        var headers = HTTPHeaders()
        headers.contentType = HTTPMediaType(type: "application", subType: "x-tar")
        headers.replaceOrAdd(name: "X-Docker-Container-Path-Stat", value: try Self.archivePathStatHeader(info))
        return Response(
            status: .ok,
            headers: headers,
            body: .init(managedAsyncStream: { writer in
                for try await data in stream {
                    try await writer.writeBuffer(ByteBuffer(data: data))
                }
            })
        )
    }

    private func archiveInfo(_ req: Request) async throws -> Response {
        let id = try requiredParameter("id", request: req)
        let path = try requiredQuery("path", request: req)
        let info = try await call { try await backend.archiveContainerInfo(id: id, path: path) }
        let response = Response(status: .ok)
        response.headers.replaceOrAdd(name: "X-Docker-Container-Path-Stat", value: try Self.archivePathStatHeader(info))
        return response
    }

    private func putArchive(_ req: Request) async throws -> Response {
        let id = try requiredParameter("id", request: req)
        let path = try requiredQuery("path", request: req)
        guard let buffer = try await req.body.collect(max: req.application.routes.defaultMaxBodySize.value).get(),
            let data = buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes)
        else {
            throw Abort(.badRequest, reason: "archive request body is required")
        }
        try await call {
            try await backend.putContainerArchive(
                id: id,
                path: path,
                data: data,
                noOverwriteDirNonDir: Self.mobyBool(req.query[String.self, at: "noOverwriteDirNonDir"])
            )
        }
        return Response(status: .ok)
    }

    private func containerChanges(_ req: Request) async throws -> Response {
        let id = try requiredParameter("id", request: req)
        let changes = try await call { try await backend.containerChanges(id: id) }
        struct Change: Encodable {
            let Path: String
            let Kind: Int
        }
        return try jsonResponse(.ok, changes.map { Change(Path: $0.path, Kind: $0.kind) })
    }

    private func createExec(_ req: Request) async throws -> Response {
        let containerID = try requiredParameter("id", request: req)
        guard
            let buffer = try await req.body.collect(max: req.application.routes.defaultMaxBodySize.value).get(),
            let data = buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes),
            !data.isEmpty
        else {
            throw Abort(.badRequest, reason: "Request body is required")
        }
        let body: ExecCreateRequest
        do {
            body = try JSONDecoder().decode(ExecCreateRequest.self, from: data)
        } catch {
            throw Abort(.badRequest, reason: "Invalid exec create request: \(error)")
        }
        guard let command = body.Cmd, !command.isEmpty else {
            throw Abort(.badRequest, reason: "No exec command specified")
        }
        let request = DockerRuntimeExecCreate(
            containerID: containerID,
            command: command,
            environment: body.Env ?? [],
            workingDirectory: body.WorkingDir,
            user: body.User,
            tty: body.Tty ?? false,
            attachStdout: body.AttachStdout ?? true,
            attachStderr: body.AttachStderr ?? true
        )
        let id = try await call { try await backend.createExec(request) }
        execState.insert(id: id, request: request)
        return try jsonResponse(.created, CreateExecResponse(Id: id))
    }

    private func resizeExec(_ req: Request) async throws -> Response {
        let id = try requiredParameter("id", request: req)
        guard let width = req.query[UInt32.self, at: "w"],
            let height = req.query[UInt32.self, at: "h"], width > 0, height > 0
        else {
            throw Abort(.badRequest, reason: "Both w and h must be positive integers")
        }
        try await call { try await backend.resizeExec(id: id, width: width, height: height) }
        return Response(status: .noContent)
    }

    private func startExec(_ req: Request) async throws -> Response {
        let id = try requiredParameter("id", request: req)
        guard let entry = execState.entry(id: id) else {
            throw Abort(.notFound, reason: "Exec instance not found: \(id)")
        }
        let body = try req.content.decode(ExecStartRequest.self)
        let tty = body.Tty ?? entry.request.tty
        if body.Detach == true {
            try execState.markRunning(id: id)
            let backend = self.backend
            let state = execState
            Task {
                do {
                    let output = try await backend.startExec(id: id, detach: true, tty: tty)
                    state.finish(id: id, exitCode: output.exitCode)
                } catch {
                    state.finish(id: id, exitCode: -1)
                }
            }
            return Response(status: .noContent)
        }
        try execState.markRunning(id: id)
        let stream = try await call { try await backend.streamExec(id: id, tty: tty) }
        if req.headers.first(name: "Upgrade")?.lowercased() == "tcp",
            req.headers.first(name: "Connection")?.lowercased().split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).contains("upgrade") == true
        {
            let state = execState
            return .dockerTCPUpgrade(execId: id, ttyEnabled: tty) { channel, _ in
                do {
                    var exitCode: Int32 = -1
                    for try await frame in stream {
                        if let code = frame.exitCode {
                            exitCode = code
                            continue
                        }
                        let data = frame.data
                        let bytes =
                            tty
                            ? data
                            : Self.frame(data, stream: frame.stream == .stderr ? 2 : 1)
                        var buffer = channel.allocator.buffer(capacity: bytes.count)
                        buffer.writeBytes(bytes)
                        try await channel.writeAndFlush(buffer).get()
                    }
                    state.finish(id: id, exitCode: exitCode)
                    try await channel.close().get()
                } catch {
                    state.finish(id: id, exitCode: -1)
                    throw error
                }
            }
        }
        var headers = HTTPHeaders()
        headers.contentType = HTTPMediaType(type: "application", subType: "vnd.docker.raw-stream")
        let state = execState
        let response = Response(
            status: .ok,
            headers: headers,
            body: .init(managedAsyncStream: { writer in
                do {
                    var exitCode: Int32 = -1
                    for try await frame in stream {
                        if let code = frame.exitCode {
                            exitCode = code
                        } else if tty {
                            try await writer.writeBuffer(ByteBuffer(data: frame.data))
                        } else {
                            let streamID: UInt8 = frame.stream == .stderr ? 2 : 1
                            try await writer.writeBuffer(
                                ByteBuffer(data: Self.frame(frame.data, stream: streamID))
                            )
                        }
                    }
                    state.finish(id: id, exitCode: exitCode)
                } catch {
                    state.finish(id: id, exitCode: -1)
                    throw error
                }
            })
        )
        if req.headers.first(name: "Upgrade")?.lowercased() == "tcp" {
            response.status = .switchingProtocols
            response.headers.replaceOrAdd(name: "Connection", value: "Upgrade")
            response.headers.replaceOrAdd(name: "Upgrade", value: "tcp")
        }
        return response
    }

    private func inspectExec(_ req: Request) async throws -> Response {
        let id = try requiredParameter("id", request: req)
        guard let entry = execState.entry(id: id) else {
            throw Abort(.notFound, reason: "Exec instance not found: \(id)")
        }
        return try jsonResponse(.ok, ExecInspectResponse(id: id, entry: entry))
    }

    private func systemDataUsage(_ req: Request) async throws -> Response {
        let query = try req.query.decode(SystemDataUsageQuery.self)
        let types = query.type ?? []
        try Self.validateSystemDataUsageTypes(types)
        let includeAll = types.isEmpty
        let images =
            includeAll || types.contains("image")
            ? try await call { try await backend.listImages() }
            : []
        let containers =
            includeAll || types.contains("container")
            ? try await call { try await backend.listContainers(showAll: true) }
            : []
        let volumes: [Volume]
        if includeAll || types.contains("volume"), let volumeClient {
            volumes = try await call {
                try await volumeClient.list(filters: nil, logger: req.logger)
            }
        } else {
            volumes = []
        }
        return try jsonResponse(
            .ok,
            SystemDataUsageResponse(images: images, containers: containers, volumes: volumes)
        )
    }

    private func logs(_ req: Request) async throws -> Response {
        let id = try requiredParameter("id", request: req)
        let options = try Self.logOptions(req)
        let stdout = Self.mobyBool(req.query[String.self, at: "stdout"])
        let stderr = Self.mobyBool(req.query[String.self, at: "stderr"])
        guard stdout || stderr else {
            throw Abort(.badRequest, reason: "Bad parameters: you must choose at least one stream")
        }
        let backend = self.backend
        let container = try await call { try await backend.inspectContainer(id: id) }
        if Self.mobyBool(req.query[String.self, at: "follow"]) {
            let stream: AsyncThrowingStream<DockerRuntimeProcessFrame, Error>
            if let optionsBackend = backend as? any DockerRuntimeLogOptionsBackend {
                stream = try await call {
                    try await optionsBackend.attachContainer(
                        id: id, stdout: stdout, stderr: stderr, options: options
                    )
                }
            } else {
                stream = try await call {
                    try await backend.attachContainer(id: id, stdout: stdout, stderr: stderr)
                }
            }
            return Self.streamResponse(stream: stream, tty: container.tty, contentType: false)
        }
        var output: DockerRuntimeProcessOutput
        if let optionsBackend = backend as? any DockerRuntimeLogOptionsBackend {
            output = try await call {
                try await optionsBackend.logs(
                    id: id, stdout: stdout, stderr: stderr, options: options
                )
            }
        } else {
            output = try await call { try await backend.logs(id: id, stdout: stdout, stderr: stderr) }
        }
        if let tail = req.query[String.self, at: "tail"] {
            output = try Self.applyTail(output, value: tail)
        }
        return Self.streamResponse(output: output, tty: container.tty, contentType: false)
    }

    private func attach(_ req: Request) async throws -> Response {
        let id = try requiredParameter("id", request: req)
        if Self.mobyBool(req.query[String.self, at: "stdin"]) {
            throw Abort(.notImplemented, reason: "Interactive attach stdin is not implemented")
        }
        let tty = try await inspectContainer(id: id).tty
        let backend = self.backend
        let stdout = req.query[String.self, at: "stdout"].map(Self.mobyBool) ?? false
        let stderr = req.query[String.self, at: "stderr"].map(Self.mobyBool) ?? false
        guard stdout || stderr else {
            throw Abort(.badRequest, reason: "Bad parameters: you must choose at least one stream")
        }
        let upgraded =
            req.headers.first(name: "Upgrade")?.lowercased() == "tcp"
            && req.headers.first(name: "Connection")?.lowercased().split(separator: ",")
                .map({ $0.trimmingCharacters(in: .whitespaces) }).contains("upgrade") == true
        let stream = try await call {
            try await backend.attachContainer(id: id, stdout: stdout, stderr: stderr)
        }
        var headers = HTTPHeaders()
        headers.contentType = HTTPMediaType(type: "application", subType: "vnd.docker.raw-stream")
        if upgraded {
            headers.add(name: "Connection", value: "Upgrade")
            headers.add(name: "Upgrade", value: "tcp")
        }
        return Response(
            status: upgraded ? .switchingProtocols : .ok,
            headers: headers,
            body: .init(managedAsyncStream: { writer in
                if upgraded {
                    // Send the upgrade response before Docker issues the separate
                    // container-start request. Attach must not start the container.
                    try await writer.writeBuffer(ByteBuffer())
                }
                for try await frame in stream {
                    guard frame.exitCode == nil else { continue }
                    if tty {
                        try await writer.writeBuffer(ByteBuffer(data: frame.data))
                    } else {
                        let streamID: UInt8 = frame.stream == .stderr ? 2 : 1
                        try await writer.writeBuffer(
                            ByteBuffer(data: Self.frame(frame.data, stream: streamID))
                        )
                    }
                }
            })
        )
    }

    private func attachWebSocket(_ req: Request) async throws -> Response {
        let id = try requiredParameter("id", request: req)
        if Self.mobyBool(req.query[String.self, at: "stdin"]) {
            throw Abort(.notImplemented, reason: "Interactive attach stdin is not implemented")
        }
        let stdout = req.query[String.self, at: "stdout"].map(Self.mobyBool) ?? false
        let stderr = req.query[String.self, at: "stderr"].map(Self.mobyBool) ?? false
        guard stdout || stderr else {
            throw Abort(.badRequest, reason: "Bad parameters: you must choose at least one stream")
        }
        let tty = try await inspectContainer(id: id).tty
        let backend = self.backend
        return req.webSocket { _, socket in
            do {
                let stream = try await backend.attachContainer(
                    id: id, stdout: stdout, stderr: stderr
                )
                for try await frame in stream {
                    guard frame.exitCode == nil else { continue }
                    let data =
                        tty
                        ? frame.data
                        : Self.frame(frame.data, stream: frame.stream == .stderr ? 2 : 1)
                    try await socket.send([UInt8](data))
                }
                try await socket.close()
            } catch {
                try? await socket.close(code: .unexpectedServerError)
            }
        }
    }

    private func call<T: Sendable>(_ operation: () async throws -> T) async throws -> T {
        do { return try await operation() } catch let error as DockerRuntimeRouteError {
            switch error {
            case .notFound(let message): throw Abort(.notFound, reason: message)
            case .conflict(let message): throw Abort(.conflict, reason: message)
            case .invalidRequest(let message): throw Abort(.badRequest, reason: message)
            }
        }
    }

    private func inspectContainer(id: String) async throws -> DockerRuntimeContainer {
        // Keep generic error mapping outside the escaping response stream closure.
        // Swift 6.3.3 otherwise stalls in ClosureLifetimeFixup while compiling attach.
        try await call { try await backend.inspectContainer(id: id) }
    }

    private func requiredParameter(_ name: String, request: Request) throws -> String {
        guard let value = request.parameters.get(name), !value.isEmpty else {
            throw Abort(.badRequest, reason: "Missing \(name)")
        }
        return value
    }

    private func requiredQuery(_ name: String, request: Request) throws -> String {
        guard let value = request.query[String.self, at: name], !value.isEmpty else {
            throw Abort(.badRequest, reason: "Missing \(name)")
        }
        return value
    }

    private func decodeContainerUpdate(_ req: Request) async throws -> DockerRuntimeContainerUpdate {
        do {
            guard
                let buffer = try await req.body.collect(
                    max: req.application.routes.defaultMaxBodySize.value
                ).get(),
                let data = buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes),
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                throw Abort(.badRequest, reason: "Container update request body is required")
            }
            let unsupported = Set(object.keys).subtracting(
                DockerRuntimeContainerUpdate.supportedDockerFields
            )
            guard unsupported.isEmpty else {
                throw Abort(
                    .notImplemented,
                    reason: "Container update option(s) \(unsupported.sorted().joined(separator: ", ")) are not supported"
                )
            }
            let update = try JSONDecoder().decode(
                DockerRuntimeContainerUpdate.self, from: data
            )
            try update.validate()
            return update
        } catch let abort as Abort {
            throw abort
        } catch let error as DockerRuntimeRouteError {
            throw error
        } catch {
            throw Abort(.badRequest, reason: "Invalid container update request: \(error)")
        }
    }

    private func jsonResponse<T: Encodable>(_ status: HTTPResponseStatus, _ value: T) throws -> Response {
        let response = Response(status: status, body: .init(data: try JSONEncoder().encode(value)))
        response.headers.contentType = .json
        return response
    }

    private static func streamResponse(
        output: DockerRuntimeProcessOutput, tty: Bool, contentType: Bool = true
    ) -> Response {
        var data = Data()
        if tty {
            data.append(output.stdout)
            data.append(output.stderr)
        } else {
            data.append(frame(output.stdout, stream: 1))
            data.append(frame(output.stderr, stream: 2))
        }
        let response = Response(status: .ok, body: .init(data: data))
        if contentType {
            response.headers.contentType = HTTPMediaType(type: "application", subType: "vnd.docker.raw-stream")
        }
        return response
    }

    private static func streamResponse(
        stream: AsyncThrowingStream<DockerRuntimeProcessFrame, Error>,
        tty: Bool,
        contentType: Bool = true
    ) -> Response {
        let response = Response(
            status: .ok,
            body: .init(managedAsyncStream: { writer in
                for try await frame in stream {
                    guard frame.exitCode == nil else { continue }
                    let data =
                        tty
                        ? frame.data
                        : Self.frame(frame.data, stream: frame.stream == .stderr ? 2 : 1)
                    try await writer.writeBuffer(ByteBuffer(data: data))
                }
            })
        )
        if contentType {
            response.headers.contentType = HTTPMediaType(type: "application", subType: "vnd.docker.raw-stream")
        }
        return response
    }

    private static func applyTail(
        _ output: DockerRuntimeProcessOutput, value: String
    ) throws -> DockerRuntimeProcessOutput {
        guard value == "all" || Int(value) != nil else {
            throw Abort(.badRequest, reason: "Invalid tail value: \(value)")
        }
        guard value != "all", let count = Int(value) else { return output }
        guard count >= 0 else {
            throw Abort(.badRequest, reason: "Invalid tail value: \(value)")
        }
        func tail(_ data: Data) -> Data {
            guard count > 0, !data.isEmpty else { return Data() }
            let hasTrailingNewline = data.last == 0x0A
            var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
            if hasTrailingNewline { lines.removeLast() }
            let selected = lines.suffix(count)
            guard !selected.isEmpty else { return Data() }
            var result = Data()
            for (index, line) in selected.enumerated() {
                result.append(line)
                if index < selected.count - 1 || hasTrailingNewline {
                    result.append(0x0A)
                }
            }
            return result
        }
        return DockerRuntimeProcessOutput(
            stdout: tail(output.stdout), stderr: tail(output.stderr), exitCode: output.exitCode
        )
    }

    private static func frame(_ payload: Data, stream: UInt8) -> Data {
        guard !payload.isEmpty else { return Data() }
        var result = Data([stream, 0, 0, 0])
        var size = UInt32(payload.count).bigEndian
        result.append(Data(bytes: &size, count: 4))
        result.append(payload)
        return result
    }

    private static func mobyBool(_ value: String?) -> Bool {
        guard let value else { return false }
        return value == "1" || value.lowercased() == "true"
    }

    private static func logOptions(_ req: Request) throws -> DockerRuntimeLogOptions {
        func parse(_ name: String) throws -> Int64? {
            guard let raw = req.query[String.self, at: name], !raw.isEmpty, raw != "0" else {
                return nil
            }
            if let seconds = Double(raw), seconds >= 0, seconds.isFinite {
                return Int64(seconds)
            }
            if let date = ISO8601DateFormatter().date(from: raw), date.timeIntervalSince1970 >= 0 {
                return Int64(date.timeIntervalSince1970)
            }
            throw Abort(.badRequest, reason: "Invalid (name) value: (raw)")
        }
        return DockerRuntimeLogOptions(
            timestamps: mobyBool(req.query[String.self, at: "timestamps"]),
            details: mobyBool(req.query[String.self, at: "details"]),
            since: try parse("since"),
            until: try parse("until")
        )
    }

    private static func imageReference(fromImage: String, tag: String?) -> String {
        guard let tag, !tag.isEmpty, !fromImage.contains("@") else { return fromImage }
        if tag.hasPrefix("sha256:") { return "\(fromImage)@\(tag)" }
        return "\(fromImage):\(tag)"
    }

    private static func imageExportReferences(_ raw: String?) throws -> [String] {
        guard let raw else { throw Abort(.badRequest, reason: "names is required") }
        let references = raw.split(separator: ",").map(String.init).filter { !$0.isEmpty }
        guard !references.isEmpty else { throw Abort(.badRequest, reason: "names is required") }
        return references
    }

    private static func networkSummary(_ network: DockerRuntimeNetwork) -> RESTNetworkSummary {
        let ipamConfig = network.ipam.Config.first
        return RESTNetworkSummary(
            Name: network.name,
            Id: network.id,
            Created: ISO8601DateFormatter().string(from: network.createdAt),
            Scope: network.scope,
            Driver: network.driver,
            EnableIPv4: network.enableIPv4,
            EnableIPv6: network.enableIPv6,
            Internal: network.internalNetwork,
            Attachable: network.attachable,
            Ingress: network.ingress,
            IPAM: network.ipam,
            Options: network.options,
            Containers: network.containers.mapValues {
                NetworkContainer(
                    Name: $0.name,
                    EndpointID: $0.endpointID,
                    MacAddress: $0.macAddress,
                    IPv4Address: $0.ipv4Address,
                    IPv6Address: $0.ipv6Address
                )
            },
            ConfigFrom: nil,
            Labels: network.labels,
            Subnet: ipamConfig?.Subnet,
            Gateway: ipamConfig?.Gateway
        )
    }

    private static func isProtectedGuestNetwork(_ network: DockerRuntimeNetwork) -> Bool {
        network.id == "glassdock0" || network.name == "bridge"
    }

    private static func archivePathStatHeader(_ info: DockerRuntimeArchivePath) throws -> String {
        struct PathStat: Encodable {
            let name: String
            let size: Int64
            let mode: Int64
            let mtime: Date
            let linkTarget: String
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(
            PathStat(
                name: info.name,
                size: info.size,
                mode: info.mode,
                mtime: info.modifiedAt,
                linkTarget: info.linkTarget
            )
        )
        return data.base64EncodedString()
    }

    private static func validateCreateOptions(_ data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DockerRuntimeRouteError.invalidRequest("request body must be a JSON object")
        }
        for key in [
            "AttachStdin", "OpenStdin", "StdinOnce", "NetworkDisabled", "Volumes", "Healthcheck",
            "Domainname", "MacAddress", "OnBuild", "Shell",
        ] where object[key].map({ !isDefaultJSONValue($0) }) == true {
            throw Abort(.notImplemented, reason: "Container create option \(key) is not implemented")
        }
        if let signal = object["StopSignal"] as? String,
            !signal.isEmpty, signal.uppercased() != "SIGTERM", signal != "15"
        {
            throw Abort(.notImplemented, reason: "Container create option StopSignal is not implemented")
        }
        guard let host = object["HostConfig"] as? [String: Any] else { return }
        for key in [
            "Privileged", "ReadonlyRootfs", "OomKillDisable", "PublishAllPorts", "Init", "Memory",
            "MemorySwap", "MemoryReservation", "NanoCpus", "CpuShares", "CpuPeriod",
            "CpuQuota", "CpuRealtimePeriod", "CpuRealtimeRuntime", "CpusetCpus", "CpusetMems",
            "PidsLimit", "BlkioWeight", "BlkioWeightDevice", "BlkioDeviceReadBps",
            "BlkioDeviceWriteBps", "BlkioDeviceReadIOps", "BlkioDeviceWriteIOps", "CapAdd", "CapDrop",
            "Devices", "DeviceCgroupRules", "DeviceRequests", "Ulimits", "SecurityOpt", "GroupAdd", "Dns",
            "DnsOptions", "DnsSearch", "ExtraHosts", "Links", "VolumesFrom", "Tmpfs", "Sysctls",
            "StorageOpt", "CgroupParent",
        ] where host[key].map({ !isDefaultJSONValue($0) }) == true {
            throw Abort(.notImplemented, reason: "HostConfig option \(key) is not implemented")
        }
        if let swappiness = host["MemorySwappiness"] as? NSNumber,
            swappiness.intValue != -1, swappiness.intValue != 0
        {
            throw Abort(.notImplemented, reason: "HostConfig option MemorySwappiness is not implemented")
        }
        if let mode = host["NetworkMode"] as? String,
            !mode.isEmpty, mode != "default", mode != "bridge"
        {
            throw Abort(.notImplemented, reason: "NetworkMode \(mode) is not implemented")
        }
        for key in ["PidMode", "UTSMode", "UsernsMode"] {
            if let value = host[key] as? String, !value.isEmpty {
                throw Abort(.notImplemented, reason: "HostConfig option \(key) is not implemented")
            }
        }
        if let mode = host["IpcMode"] as? String, !mode.isEmpty, mode != "private" {
            throw Abort(.notImplemented, reason: "IpcMode \(mode) is not implemented")
        }
        if let mode = host["CgroupnsMode"] as? String, !mode.isEmpty, mode != "private" {
            throw Abort(.notImplemented, reason: "CgroupnsMode \(mode) is not implemented")
        }
        if let runtime = host["Runtime"] as? String, !runtime.isEmpty, runtime != "runc" {
            throw Abort(.notImplemented, reason: "Runtime \(runtime) is not implemented")
        }
        if let policy = host["RestartPolicy"] as? [String: Any],
            let name = policy["Name"] as? String, !name.isEmpty, name != "no"
        {
            throw Abort(.notImplemented, reason: "RestartPolicy \(name) is not implemented")
        }
    }

    private static func isDefaultJSONValue(_ value: Any) -> Bool {
        if value is NSNull { return true }
        if let value = value as? Bool { return !value }
        if let value = value as? NSNumber { return value.doubleValue == 0 }
        if let value = value as? String { return value.isEmpty }
        if let value = value as? [Any] { return value.isEmpty }
        if let value = value as? [String: Any] {
            return value.isEmpty || value.values.allSatisfy(isDefaultJSONValue)
        }
        return false
    }

    private static func registryAuth(_ value: String?) throws -> DockerRegistryAuth? {
        guard let value, !value.isEmpty else { return nil }
        var normalized = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        guard let data = Data(base64Encoded: normalized),
            let auth = try? JSONDecoder().decode(DockerRegistryAuth.self, from: data)
        else {
            throw Abort(.badRequest, reason: "Invalid X-Registry-Auth header")
        }
        return auth
    }

    private static func matchesReference(_ reference: String, pattern: String) -> Bool {
        let forms = familiarReferenceForms(reference)
        return forms.contains { candidate in
            globMatch(pattern: pattern, candidate: candidate)
        }
    }

    private static let imageFilterKeys: Set<String> = [
        "before", "dangling", "label", "reference", "since", "until",
    ]

    private static func imageFilters(_ raw: String?) throws -> [String: [String]] {
        guard let raw, !raw.isEmpty, let data = raw.data(using: .utf8) else {
            return [:]
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Abort(.badRequest, reason: "invalid filter")
        }
        var filters: [String: [String]] = [:]
        for (key, value) in object {
            guard imageFilterKeys.contains(key) else {
                throw Abort(.badRequest, reason: "invalid filter '\(key)'")
            }
            if let values = value as? [String: Any] {
                guard values.values.allSatisfy(isJSONBool) else {
                    throw Abort(.badRequest, reason: "invalid filter")
                }
                filters[key] = values.compactMap { key, value in
                    guard (value as? Bool) == true else { return nil }
                    return key
                }
            } else if let values = value as? [Any] {
                guard values.allSatisfy({ $0 is String }) else {
                    throw Abort(.badRequest, reason: "invalid filter")
                }
                filters[key] = values.compactMap { $0 as? String }
            } else if let value = value as? String {
                filters[key] = [value]
            } else {
                throw Abort(.badRequest, reason: "invalid filter")
            }
        }
        return filters
    }

    private static func isJSONBool(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func applyImageFilters(
        _ images: [DockerRuntimeImage],
        filters: [String: [String]]
    ) throws -> [DockerRuntimeImage] {
        var result = images
        if let values = filters["dangling"] {
            let isTrue = try Self.danglingFilterValue(values)
            result = result.filter { Self.isDangling($0) == isTrue }
        }
        if let patterns = filters["reference"] {
            result = result.filter { image in
                image.references.contains { reference in
                    patterns.contains { Self.matchesReference(reference, pattern: $0) }
                }
            }
        }
        if let values = filters["label"] {
            result = result.filter { image in
                values.contains { Self.matchesImageLabel($0, labels: image.labels) }
            }
        }
        if let values = filters["before"] {
            guard let boundary = Self.imageFilterDate(values, images: images) else {
                throw Abort(.badRequest, reason: "invalid filter 'before'")
            }
            result = result.filter { $0.createdAt < boundary }
        }
        if let values = filters["since"] {
            guard let boundary = Self.imageFilterDate(values, images: images) else {
                throw Abort(.badRequest, reason: "invalid filter 'since'")
            }
            result = result.filter { $0.createdAt > boundary }
        }
        if let values = filters["until"] {
            guard let raw = values.first, let boundary = parseDate(raw) else {
                throw Abort(.badRequest, reason: "invalid filter 'until'")
            }
            result = result.filter { $0.createdAt < boundary }
        }
        return result
    }

    private static func validateImageFilters(_ filters: [String: [String]]) throws {
        if let values = filters["dangling"] {
            _ = try danglingFilterValue(values)
        }
    }

    private static func danglingFilterValue(_ values: [String]) throws -> Bool {
        guard !values.isEmpty else {
            throw Abort(.badRequest, reason: "invalid filter 'dangling'")
        }
        let isTrue = values.contains { $0 == "1" || $0 == "true" }
        let isFalse = values.contains { $0 == "0" || $0 == "false" }
        guard isTrue != isFalse else {
            throw Abort(.badRequest, reason: "invalid filter 'dangling'")
        }
        return isTrue
    }

    private static func isDangling(_ image: DockerRuntimeImage) -> Bool {
        image.references.allSatisfy {
            $0 == "<none>:<none>" || $0.hasPrefix("sha256:") || $0.contains("@sha256:")
        }
    }

    private static func matchesImageLabel(_ expression: String, labels: [String: String]) -> Bool {
        let parts = expression.split(separator: "=", maxSplits: 1).map(String.init)
        guard let key = parts.first, !key.isEmpty, let value = labels[key] else { return false }
        return parts.count == 1 || value == parts[1]
    }

    private static func imageFilterDate(
        _ values: [String],
        images: [DockerRuntimeImage]
    ) -> Date? {
        guard let value = values.first, !value.isEmpty else { return nil }
        if let image = images.first(where: {
            $0.digest == value || $0.reference == value || $0.references.contains(value)
        }) {
            return image.createdAt
        }
        return parseDate(value)
    }

    private static func familiarReferenceForms(_ reference: String) -> [String] {
        let familiar = familiarizeReference(reference)
        var name = familiar
        if let at = name.firstIndex(of: "@") {
            name = String(name[..<at])
        }
        if let colon = name.lastIndex(of: ":"),
            !name[name.index(after: colon)...].contains("/")
        {
            name = String(name[..<colon])
        }
        return name == familiar ? [familiar] : [familiar, name]
    }

    private static func familiarizeReference(_ reference: String) -> String {
        for prefix in ["docker.io/library/", "docker.io/"] where reference.hasPrefix(prefix) {
            return String(reference.dropFirst(prefix.count))
        }
        return reference
    }

    private static func globMatch(pattern: String, candidate: String) -> Bool {
        let patternSegments = pattern.split(separator: "/", omittingEmptySubsequences: false)
        let candidateSegments = candidate.split(separator: "/", omittingEmptySubsequences: false)
        guard patternSegments.count == candidateSegments.count else { return false }
        return zip(patternSegments, candidateSegments).allSatisfy {
            wildcardMatch(pattern: Array($0), candidate: Array($1))
        }
    }

    private static func wildcardMatch(pattern: [Character], candidate: [Character]) -> Bool {
        var patternIndex = 0
        var candidateIndex = 0
        var starIndex = -1
        var starCandidateIndex = 0
        while candidateIndex < candidate.count {
            if patternIndex < pattern.count,
                pattern[patternIndex] == "?" || pattern[patternIndex] == candidate[candidateIndex]
            {
                patternIndex += 1
                candidateIndex += 1
            } else if patternIndex < pattern.count, pattern[patternIndex] == "*" {
                starIndex = patternIndex
                starCandidateIndex = candidateIndex
                patternIndex += 1
            } else if starIndex >= 0 {
                patternIndex = starIndex + 1
                starCandidateIndex += 1
                candidateIndex = starCandidateIndex
            } else {
                return false
            }
        }
        while patternIndex < pattern.count, pattern[patternIndex] == "*" {
            patternIndex += 1
        }
        return patternIndex == pattern.count
    }

    private static let systemDataUsageTypes: Set<String> = [
        "container", "image", "volume", "build-cache",
    ]

    private static func validateSystemDataUsageTypes(_ types: [String]) throws {
        if let unknown = types.first(where: { !systemDataUsageTypes.contains($0) }) {
            throw Abort(.badRequest, reason: "unknown object type: \(unknown)")
        }
    }

    private static func pruneAll(_ rawFilters: String?) -> Bool {
        guard let rawFilters, let data = rawFilters.data(using: .utf8) else { return false }
        if let filters = try? JSONDecoder().decode([String: [String: Bool]].self, from: data) {
            return filters["dangling"]?["false"] != nil
        }
        if let filters = try? JSONDecoder().decode([String: [String]].self, from: data) {
            return filters["dangling"]?.contains("false") == true
        }
        return false
    }

    private static func containerFilters(_ raw: String) throws -> [String: [String]] {
        guard let data = raw.data(using: .utf8) else {
            throw Abort(.badRequest, reason: "Invalid container filters")
        }
        if let filters = try? JSONDecoder().decode([String: [String]].self, from: data) {
            return filters
        }
        if let filters = try? JSONDecoder().decode([String: [String: Bool]].self, from: data) {
            return filters.mapValues { $0.compactMap { $0.value ? $0.key : nil } }
        }
        throw Abort(.badRequest, reason: "Invalid container filters")
    }

    private static func containerPruneFilters(_ raw: String) throws -> [String: [String]] {
        let filters = try containerFilters(raw)
        guard let unsupported = filters.keys.first(where: { $0 != "label" && $0 != "until" }) else {
            return filters
        }
        throw Abort(.badRequest, reason: "Unsupported container prune filter: \(unsupported)")
    }

    private static func matches(
        _ container: DockerRuntimeContainer,
        filters: [String: [String]]
    ) -> Bool {
        filters.allSatisfy { key, values in
            guard !values.isEmpty else { return true }
            switch key {
            case "id":
                return values.contains { container.id.hasPrefix($0) }
            case "name":
                return values.contains {
                    container.name.contains($0.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
                }
            case "status":
                return values.contains(container.state.rawValue)
            case "ancestor":
                return values.contains {
                    container.image == $0 || container.image.hasPrefix($0)
                }
            case "label":
                return values.contains { expression in
                    let parts = expression.split(separator: "=", maxSplits: 1).map(String.init)
                    guard let actual = container.labels[parts[0]] else { return false }
                    return parts.count == 1 || actual == parts[1]
                }
            case "until":
                guard let raw = values.first, let cutoff = parseDate(raw) else { return false }
                return container.createdAt < cutoff
            default:
                return false
            }
        }
    }

    private static func parseDate(_ value: String) -> Date? {
        if let seconds = Double(value) { return Date(timeIntervalSince1970: seconds) }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func imageDeleteItems(_ result: DockerRuntimeImageDelete) -> [ImageDeleteItem] {
        result.untagged.map { ImageDeleteItem(Deleted: nil, Untagged: $0) }
            + result.deleted.map { ImageDeleteItem(Deleted: $0, Untagged: nil) }
    }

    private func mounts(from host: CreateHostConfig?) async throws -> [DockerRuntimeMount] {
        var result: [DockerRuntimeMount] = []
        for bind in host?.Binds ?? [] {
            let components = bind.split(separator: ":", maxSplits: 2).map(String.init)
            guard components.count >= 2, components[1].hasPrefix("/") else {
                throw Abort(.badRequest, reason: "Invalid bind mount: \(bind)")
            }
            let source = try await resolveMountSource(components[0])
            result.append(
                DockerRuntimeMount(
                    source: source.path, target: components[1], readOnly: components.count == 3 && components[2].split(separator: ",").contains("ro"), volumeName: source.volumeName
                ))
        }
        for mount in host?.Mounts ?? [] {
            guard mount.`Type` == "bind" || mount.`Type` == "volume" else {
                throw Abort(.notImplemented, reason: "Mount type \(mount.`Type`) is not supported")
            }
            guard let source = mount.Source, mount.Target.hasPrefix("/") else {
                throw Abort(.badRequest, reason: "Invalid bind mount")
            }
            let resolved = try await resolveMountSource(source)
            result.append(DockerRuntimeMount(source: resolved.path, target: mount.Target, readOnly: mount.ReadOnly ?? false, volumeName: resolved.volumeName))
        }
        return result
    }

    private func resolveMountSource(_ source: String) async throws -> (path: String, volumeName: String?) {
        if source.hasPrefix("/") {
            let canonicalSource = canonicalFileURL(URL(fileURLWithPath: source)).path
            return (canonicalSource, nil)
        }
        guard let volumeClient else {
            throw Abort(.notImplemented, reason: "Named volume mounts are not configured")
        }
        return (try await volumeClient.inspect(name: source).Mountpoint, source)
    }

    private static func ports(from host: CreateHostConfig?) -> [DockerRuntimePortBinding] {
        (host?.PortBindings ?? [:]).flatMap { key, bindings -> [DockerRuntimePortBinding] in
            let pieces = key.split(separator: "/", maxSplits: 1)
            guard let port = Int(pieces[0]) else { return [] }
            let proto = pieces.count == 2 ? String(pieces[1]) : "tcp"
            return bindings.map {
                DockerRuntimePortBinding(
                    containerPort: port,
                    proto: proto,
                    hostIP: $0.HostIp ?? "0.0.0.0",
                    hostPort: $0.HostPort.flatMap(Int.init)
                )
            }
        }
    }
}

private struct ImageDeleteItem: Encodable {
    let Deleted: String?
    let Untagged: String?
}

private struct ImageImportProgress: Encodable {
    let stream: String
}

private struct ImagePruneResponse: Encodable {
    let ImagesDeleted: [ImageDeleteItem]
    let SpaceReclaimed: Int64
}

private struct ImageHistoryResponseItem: Encodable {
    let Id: String
    let Created: Int64
    let CreatedBy: String
    let Tags: [String]
    let Size: Int64
    let Comment: String
}

private struct ContainerPruneResponse: Encodable {
    let ContainersDeleted: [String]
    let SpaceReclaimed: Int64
}

private struct ImageSummary: Encodable {
    let Id: String
    let ParentId = ""
    let RepoTags: [String]
    let RepoDigests: [String]
    let Created: Int64
    let Size: Int64
    let SharedSize: Int64 = -1
    let VirtualSize: Int64
    let Labels: [String: String]
    let Containers: Int64 = -1

    init(_ image: DockerRuntimeImage) {
        Id = image.digest
        RepoTags = image.references.filter { !$0.contains("@sha256:") }
        RepoDigests = image.references.filter { $0.contains("@sha256:") }
        Created = Int64(image.createdAt.timeIntervalSince1970)
        Size = image.size
        VirtualSize = image.size
        Labels = image.labels
    }
}

private struct ImageInspectResponse: Encodable {
    struct ConfigPayload: Encodable {
        let Labels: [String: String]
    }
    struct RootFSPayload: Encodable {
        let `Type` = "layers"
        let Layers: [String]
    }

    let Id: String
    let RepoTags: [String]
    let RepoDigests: [String]
    let Created: String
    let Size: Int64
    let VirtualSize: Int64
    let Config: ConfigPayload
    let RootFS: RootFSPayload

    init(_ image: DockerRuntimeImage) {
        Id = image.digest
        RepoTags = image.references.filter { !$0.contains("@sha256:") }
        RepoDigests = image.references.filter { $0.contains("@sha256:") }
        Created = ISO8601DateFormatter().string(from: image.createdAt)
        Size = image.size
        VirtualSize = image.size
        Config = ConfigPayload(Labels: image.labels)
        RootFS = RootFSPayload(Layers: image.rootFSLayers)
    }
}

private struct SystemDataUsageResponse: Encodable {
    struct ImageUsage: Encodable {
        let Id: String
        let ParentId = ""
        let RepoTags: [String]
        let RepoDigests: [String]
        let Created: Int64
        let Size: Int64
        let SharedSize: Int64 = -1
        let VirtualSize: Int64
        let Labels: [String: String]
        let Containers: Int64

        init(_ image: DockerRuntimeImage, containerCount: Int64) {
            Id = image.digest
            RepoTags = image.references.filter { !$0.contains("@sha256:") }
            RepoDigests = image.references.filter { $0.contains("@sha256:") }
            Created = Int64(image.createdAt.timeIntervalSince1970)
            Size = image.size
            VirtualSize = image.size
            Labels = image.labels
            Containers = containerCount
        }
    }

    struct ContainerUsage: Encodable {
        let Id: String
        let Names: [String]
        let Image: String
        let ImageID: String
        let Command: String
        let Created: Int64
        let SizeRw: Int64 = -1
        let SizeRootFs: Int64 = -1
        let Labels: [String: String]
        let State: String
        let Status: String

        init(_ container: DockerRuntimeContainer) {
            Id = container.id
            Names = [container.name.hasPrefix("/") ? container.name : "/\(container.name)"]
            Image = container.image
            ImageID = container.image
            Command = container.command.joined(separator: " ")
            Created = Int64(container.createdAt.timeIntervalSince1970)
            Labels = container.labels
            State = container.state.rawValue
            Status = container.state.rawValue
        }
    }

    let LayersSize: Int64
    let Images: [ImageUsage]
    let Containers: [ContainerUsage]
    let Volumes: [Volume]
    let BuildCache: [String] = []

    init(
        images: [DockerRuntimeImage],
        containers: [DockerRuntimeContainer],
        volumes: [Volume] = []
    ) {
        let counts = containers.reduce(into: [String: Int64]()) { counts, container in
            counts[container.image, default: 0] += 1
        }
        LayersSize = images.reduce(into: Int64(0)) { total, image in
            total += max(image.size, 0)
        }
        Images = images.map { ImageUsage($0, containerCount: counts[$0.reference, default: -1]) }
        Containers = containers.map(ContainerUsage.init)
        Volumes = volumes
    }
}

private struct DockerNetworkCreateRequest: Content {
    let Name: String
    let Driver: String?
    let Scope: String?
    let Internal: Bool?
    let Attachable: Bool?
    let Ingress: Bool?
    let EnableIPv4: Bool?
    let EnableIPv6: Bool?
    let IPAM: DockerNetworkIPAMRequest?
    let Options: [String: String]?
    let Labels: [String: String]?
}

private struct DockerNetworkIPAMRequest: Content {
    let Driver: String?
    let Config: [DockerNetworkIPAMConfigRequest]?

    var runtimeIPAM: DockerRuntimeNetworkIPAM {
        DockerRuntimeNetworkIPAM(
            driver: Driver,
            config: (Config ?? []).map {
                DockerRuntimeNetworkIPAMConfig(
                    subnet: $0.Subnet,
                    ipRange: $0.IPRange,
                    gateway: $0.Gateway,
                    auxiliaryAddresses: $0.AuxiliaryAddresses
                )
            }
        )
    }
}

private struct DockerNetworkIPAMConfigRequest: Content {
    let Subnet: String?
    let IPRange: String?
    let Gateway: String?
    let AuxiliaryAddresses: [String: String]?
}

private struct DockerNetworkConnectRequest: Content {
    let Container: String
    let EndpointConfig: DockerNetworkEndpointConfig?
}

private struct DockerNetworkDisconnectRequest: Content {
    let Container: String
    let Force: Bool?
}

private struct DockerNetworkEndpointConfig: Content {
    let IPAMConfig: ContainerIPAMConfig?
}

private struct CreateRequest: Content {
    let Image: String
    let Cmd: [String]?
    let Entrypoint: [String]?
    let Env: [String]?
    let WorkingDir: String?
    let User: String?
    let Hostname: String?
    let Labels: [String: String]?
    let Tty: Bool?
    let HostConfig: CreateHostConfig?
}

private struct RenameRequest: Content {
    let Name: String
}

private struct SystemDataUsageQuery: Content {
    let type: [String]?
}

private struct CreateHostConfig: Content {
    let AutoRemove: Bool?
    let Binds: [String]?
    let Mounts: [CreateMount]?
    let PortBindings: [String: [CreatePortBinding]]?
}

private struct CreateMount: Content {
    let `Type`: String
    let Source: String?
    let Target: String
    let ReadOnly: Bool?
}

private struct CreatePortBinding: Content {
    let HostIp: String?
    let HostPort: String?
}

private struct ExecCreateRequest: Content {
    let Cmd: [String]?
    let AttachStdout: Bool?
    let AttachStderr: Bool?
    let Tty: Bool?
    let Env: [String]?
    let User: String?
    let WorkingDir: String?
}

private struct ExecStartRequest: Content {
    let Detach: Bool?
    let Tty: Bool?
}

private struct InspectResponse: Content {
    struct StatePayload: Content {
        let Status: String
        let Running: Bool
        let ExitCode: Int32
    }
    struct ConfigPayload: Content {
        let Image: String
        let Cmd: [String]
        let Tty: Bool
        let Labels: [String: String]
    }
    struct NetworkSettingsPayload: Content { let Ports: [String: [CreatePortBinding]] }
    struct HostConfigPayload: Content { let PortBindings: [String: [CreatePortBinding]] }

    let Id: String
    let Name: String
    let Image: String
    let Created: String
    let State: StatePayload
    let Config: ConfigPayload
    let HostConfig: HostConfigPayload
    let NetworkSettings: NetworkSettingsPayload

    init(_ container: DockerRuntimeContainer) {
        Id = container.id
        Name = container.name.hasPrefix("/") ? container.name : "/\(container.name)"
        Image = container.image
        Created = ISO8601DateFormatter().string(from: container.createdAt)
        State = .init(
            Status: container.state.rawValue,
            Running: container.state == .running,
            ExitCode: container.exitCode ?? 0
        )
        Config = .init(Image: container.image, Cmd: container.command, Tty: container.tty, Labels: container.labels)
        var ports: [String: [CreatePortBinding]] = [:]
        for binding in container.ports {
            ports["\(binding.containerPort)/\(binding.proto)", default: []].append(
                .init(HostIp: binding.hostIP, HostPort: binding.hostPort.map(String.init))
            )
        }
        HostConfig = .init(PortBindings: ports)
        NetworkSettings = .init(Ports: ports)
    }
}

private struct ListResponse: Content {
    struct PortPayload: Content {
        let IP: String
        let PrivatePort: Int
        let PublicPort: Int?
        let `Type`: String
    }
    let Id: String
    let Names: [String]
    let Image: String
    let Command: String
    let Created: Int64
    let Labels: [String: String]
    let State: String
    let Status: String
    let Ports: [PortPayload]

    init(_ container: DockerRuntimeContainer) {
        Id = container.id
        Names = [container.name.hasPrefix("/") ? container.name : "/\(container.name)"]
        Image = container.image
        Command = container.command.joined(separator: " ")
        Created = Int64(container.createdAt.timeIntervalSince1970)
        Labels = container.labels
        State = container.state.rawValue
        Status = container.state.rawValue
        Ports = container.ports.map {
            PortPayload(
                IP: $0.hostIP,
                PrivatePort: $0.containerPort,
                PublicPort: $0.hostPort,
                Type: $0.proto
            )
        }
    }
}

private struct ExecInspectResponse: Content {
    struct ProcessConfigPayload: Content {
        let entrypoint: String
        let arguments: [String]
        let tty: Bool
    }
    let ID: String
    let Running: Bool
    let ExitCode: Int32?
    let ContainerID: String
    let ProcessConfig: ProcessConfigPayload

    init(id: String, entry: DockerRuntimeExecState.Entry) {
        ID = id
        Running = entry.running
        ExitCode = entry.exitCode
        ContainerID = entry.request.containerID
        ProcessConfig = .init(
            entrypoint: entry.request.command.first ?? "",
            arguments: Array(entry.request.command.dropFirst()),
            tty: entry.request.tty
        )
    }
}
