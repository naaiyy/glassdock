import Foundation
import NIOCore
import Vapor

import func Foundation.fputs
import var Foundation.stderr

enum EngineContainerState: String, Sendable, Equatable {
    case created
    case running
    case paused
    case restarting
    case exited
}

enum DockerRuntimeGuestLimits {
    // Uploads use the guest stdin stream protocol, so the request itself stays
    // below the 16 MiB frame limit. The application body limit remains the
    // final bound for a single Docker request.
    static let maximumImportArchiveBytes = 64 * 1024 * 1024
    static let maximumBuildContextBytes = 64 * 1024 * 1024
    static let maximumContainerArchiveBytes = 64 * 1024 * 1024
    static let maximumImageVolumeCopyUpBytes = 64 * 1024 * 1024 * 1024
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
    func exportImages(references: [String]) async throws -> (firstChunk: Data, remaining: AsyncThrowingStream<Data, Error>)
    func importImages(data: Data) async throws -> [DockerRuntimeImage]
    func buildImage(context: Data, dockerfile: String, tags: [String]) async throws -> DockerRuntimeImage
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
    func deleteNetwork(id: String) async throws
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
    func connectNetwork(
        id: String,
        containerID: String,
        aliases: [String]?,
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
    let tail: Int?

    var requiresGuestFiltering: Bool {
        timestamps || details || since != nil || until != nil || tail != nil
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

protocol DockerRuntimeImageImportBackend: DockerRuntimeRouteBackend {
    func importImages(data: Data, reference: String?) async throws -> [DockerRuntimeImage]
}

/// Backends whose guest protocol accepts streaming uploads, removing the
/// in-memory size bound on image imports and loads.
protocol DockerRuntimeImageImportStreamingBackend: DockerRuntimeRouteBackend {
    func openImportSession(reference: String?) async throws -> GuestImportSession
}

protocol DockerRuntimeImagePruneBackend: Sendable {
    func pruneImages(all: Bool, filters: [String: [String]]) async throws -> DockerRuntimeImageDelete
}

/// Real build-cache accounting served by the embedded BuildKit controller.
protocol DockerRuntimeBuildCacheBackend: Sendable {
    func systemDataUsage() async throws -> (
        layersSize: Int64, buildCache: [GuestBuildCacheRecord]
    )
    func pruneBuildCache(all: Bool) async throws -> GuestBuilderPrunePayload
}

protocol DockerRuntimeImageBuildOptionsBackend: Sendable {
    func buildImage(
        context: Data, dockerfile: String, tags: [String], buildArgs: [String: String]
    ) async throws -> DockerRuntimeImage
}

protocol DockerRuntimeInteractiveBackend: DockerRuntimeRouteBackend {
    func streamExec(
        id: String, tty: Bool, onInput: GuestInputRelay?
    ) async throws -> AsyncThrowingStream<DockerRuntimeProcessFrame, Error>
    func attachContainer(
        id: String, stdout: Bool, stderr: Bool, options: DockerRuntimeLogOptions,
        onInput: GuestInputRelay?
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
    func connectNetwork(
        id: String,
        containerID: String,
        aliases: [String]?,
        ipv4Address: String?,
        ipv6Address: String?
    ) async throws {
        _ = aliases
        try await connectNetwork(
            id: id,
            containerID: containerID,
            ipv4Address: ipv4Address,
            ipv6Address: ipv6Address
        )
    }

    func buildImage(context: Data, dockerfile: String, tags: [String]) async throws -> DockerRuntimeImage {
        throw DockerRuntimeRouteError.invalidRequest("image build is not supported")
    }

    func pushImage(source: String, target: String, platform: String?, auth: DockerRegistryAuth?) async throws -> DockerRuntimeImage {
        throw DockerRuntimeRouteError.invalidRequest("image push is not supported")
    }
    func exportImages(references: [String]) async throws -> (firstChunk: Data, remaining: AsyncThrowingStream<Data, Error>) {
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
    func deleteNetwork(id: String) async throws {
        throw DockerRuntimeRouteError.invalidRequest("network deletion is not supported")
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
    let author: String
    let architecture: String
    let os: String
    let osVersion: String
    let variant: String
    let config: DockerRuntimeImageConfig
    let rootFSLayers: [String]
    let history: [DockerRuntimeImageHistory]

    init(
        reference: String, digest: String, references: [String] = [],
        createdAt: Date = Date(timeIntervalSince1970: 0), size: Int64 = 0,
        labels: [String: String] = [:], author: String = "",
        architecture: String = "", os: String = "", osVersion: String = "",
        variant: String = "", config: DockerRuntimeImageConfig = .init(),
        rootFSLayers: [String] = [],
        history: [DockerRuntimeImageHistory] = []
    ) {
        self.reference = reference
        self.digest = digest
        self.references = references.isEmpty ? [reference] : references
        self.createdAt = createdAt
        self.size = size
        self.labels = labels
        self.author = author
        self.architecture = architecture
        self.os = os
        self.osVersion = osVersion
        self.variant = variant
        self.config = config
        self.rootFSLayers = rootFSLayers
        self.history = history
    }
}

struct DockerRuntimeImageConfig: Sendable, Equatable {
    let user: String
    let exposedPorts: Set<String>
    let environment: [String]
    let entrypoint: [String]
    let cmd: [String]
    let volumes: Set<String>
    let workingDirectory: String
    let labels: [String: String]
    let stopSignal: String
    let healthcheck: DockerRuntimeHealthcheck?
    let onBuild: [String]
    let shell: [String]

    init(
        user: String = "", exposedPorts: Set<String> = [], environment: [String] = [],
        entrypoint: [String] = [], cmd: [String] = [], volumes: Set<String> = [],
        workingDirectory: String = "", labels: [String: String] = [:], stopSignal: String = "",
        healthcheck: DockerRuntimeHealthcheck? = nil, onBuild: [String] = [], shell: [String] = []
    ) {
        self.user = user
        self.exposedPorts = exposedPorts
        self.environment = environment
        self.entrypoint = entrypoint
        self.cmd = cmd
        self.volumes = volumes
        self.workingDirectory = workingDirectory
        self.labels = labels
        self.stopSignal = stopSignal
        self.healthcheck = healthcheck
        self.onBuild = onBuild
        self.shell = shell
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
    var name: String = ""
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
    let type: String
    let options: [String]
    var volumeName: String? = nil
    var noCopy: Bool = false

    enum CodingKeys: String, CodingKey {
        case source, target, readOnly, type, options, volumeName, noCopy
    }

    init(
        source: String,
        target: String,
        readOnly: Bool,
        type: String = "bind",
        options: [String] = [],
        volumeName: String? = nil,
        noCopy: Bool = false
    ) {
        self.source = source
        self.target = target
        self.readOnly = readOnly
        self.type = type
        self.options = options
        self.volumeName = volumeName
        self.noCopy = noCopy
    }

    /// The guest serializes mounts with `omitempty`; absent `readOnly`,
    /// `options`, and `source` decode as defaults instead of failing.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        source = try values.decodeIfPresent(String.self, forKey: .source) ?? ""
        target = try values.decode(String.self, forKey: .target)
        readOnly = try values.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
        type = try values.decodeIfPresent(String.self, forKey: .type) ?? "bind"
        options = try values.decodeIfPresent([String].self, forKey: .options) ?? []
        volumeName = try values.decodeIfPresent(String.self, forKey: .volumeName)
        noCopy = try values.decodeIfPresent(Bool.self, forKey: .noCopy) ?? false
    }
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

struct DockerRuntimeHealthcheck: Codable, Sendable, Equatable {
    let test: [String]
    let interval: Int64
    let timeout: Int64
    let retries: Int
    let startPeriod: Int64
    let startInterval: Int64

    init(
        test: [String], interval: Int64 = 0, timeout: Int64 = 0, retries: Int = 0,
        startPeriod: Int64 = 0, startInterval: Int64 = 0
    ) {
        self.test = test
        self.interval = interval
        self.timeout = timeout
        self.retries = retries
        self.startPeriod = startPeriod
        self.startInterval = startInterval
    }
}

struct DockerRuntimeHealth: Codable, Sendable, Equatable {
    let status: String
    let failingStreak: Int
    let log: [HealthcheckResult]

    struct HealthcheckResult: Codable, Sendable, Equatable {
        let start: Date
        let end: Date
        let exitCode: Int32
        let output: String

        init(start: Date, end: Date, exitCode: Int32, output: String = "") {
            self.start = start
            self.end = end
            self.exitCode = exitCode
            self.output = output
        }

        enum CodingKeys: String, CodingKey {
            case start, end, exitCode, output
        }

        /// The guest omits `output` when a probe produced no text.
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            start = try values.decode(Date.self, forKey: .start)
            end = try values.decode(Date.self, forKey: .end)
            exitCode = try values.decode(Int32.self, forKey: .exitCode)
            output = try values.decodeIfPresent(String.self, forKey: .output) ?? ""
        }
    }

    init(
        status: String = "none", failingStreak: Int = 0,
        log: [HealthcheckResult] = []
    ) {
        self.status = status
        self.failingStreak = failingStreak
        self.log = log
    }
}

struct DockerRuntimeRestartPolicy: Codable, Sendable, Equatable {
    let name: String
    let maximumRetryCount: Int

    init(name: String = "no", maximumRetryCount: Int = 0) {
        self.name = name
        self.maximumRetryCount = maximumRetryCount
    }

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case maximumRetryCount = "MaximumRetryCount"
        case lowerName = "name"
        case lowerMaximumRetryCount = "maximumRetryCount"
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name =
            try values.decodeIfPresent(String.self, forKey: .name)
            ?? values.decodeIfPresent(String.self, forKey: .lowerName) ?? "no"
        maximumRetryCount =
            try values.decodeIfPresent(Int.self, forKey: .maximumRetryCount)
            ?? values.decodeIfPresent(Int.self, forKey: .lowerMaximumRetryCount) ?? 0
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(name, forKey: .name)
        try values.encode(maximumRetryCount, forKey: .maximumRetryCount)
    }
}

struct DockerRuntimeResources: Codable, Sendable, Equatable {
    let memory: Int64
    let memorySwap: Int64
    let memoryReservation: Int64
    let nanoCPUs: Int64
    let cpuShares: Int64
    let cpuPeriod: Int64
    let cpuQuota: Int64
    let cpusetCpus: String
    let cpusetMems: String
    let pidsLimit: Int64

    init(
        memory: Int64 = 0, memorySwap: Int64 = 0, memoryReservation: Int64 = 0,
        nanoCPUs: Int64 = 0, cpuShares: Int64 = 0, cpuPeriod: Int64 = 0,
        cpuQuota: Int64 = 0, cpusetCpus: String = "", cpusetMems: String = "",
        pidsLimit: Int64 = 0
    ) {
        self.memory = memory
        self.memorySwap = memorySwap
        self.memoryReservation = memoryReservation
        self.nanoCPUs = nanoCPUs
        self.cpuShares = cpuShares
        self.cpuPeriod = cpuPeriod
        self.cpuQuota = cpuQuota
        self.cpusetCpus = cpusetCpus
        self.cpusetMems = cpusetMems
        self.pidsLimit = pidsLimit
    }

    private enum CodingKeys: String, CodingKey {
        case memory, memorySwap, memoryReservation, nanoCPUs
        case cpuShares, cpuPeriod, cpuQuota, cpusetCpus, cpusetMems, pidsLimit
    }

    /// The guest serializes resources with `omitempty`, so absent keys decode
    /// as zero values instead of failing the whole state decode.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            memory: try container.decodeIfPresent(Int64.self, forKey: .memory) ?? 0,
            memorySwap: try container.decodeIfPresent(Int64.self, forKey: .memorySwap) ?? 0,
            memoryReservation: try container.decodeIfPresent(Int64.self, forKey: .memoryReservation) ?? 0,
            nanoCPUs: try container.decodeIfPresent(Int64.self, forKey: .nanoCPUs) ?? 0,
            cpuShares: try container.decodeIfPresent(Int64.self, forKey: .cpuShares) ?? 0,
            cpuPeriod: try container.decodeIfPresent(Int64.self, forKey: .cpuPeriod) ?? 0,
            cpuQuota: try container.decodeIfPresent(Int64.self, forKey: .cpuQuota) ?? 0,
            cpusetCpus: try container.decodeIfPresent(String.self, forKey: .cpusetCpus) ?? "",
            cpusetMems: try container.decodeIfPresent(String.self, forKey: .cpusetMems) ?? "",
            pidsLimit: try container.decodeIfPresent(Int64.self, forKey: .pidsLimit) ?? 0
        )
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
    let stopTimeout: Int?
    let mounts: [DockerRuntimeMount]
    let ports: [DockerRuntimePortBinding]
    let attachStdin: Bool
    let openStdin: Bool
    let stdinOnce: Bool
    let networkMode: String
    let networkIPv4Address: String?
    let networkIPv6Address: String?
    let networkAliases: [String]
    let readonlyRootfs: Bool
    let privileged: Bool
    let healthcheck: DockerRuntimeHealthcheck?
    let restartPolicy: DockerRuntimeRestartPolicy
    let restartCount: Int
    let resources: DockerRuntimeResources
    let stopSignal: String?
    let dns: [String]
    let dnsSearch: [String]
    let extraHosts: [String]

    init(
        name: String?, image: String, command: [String], entrypoint: [String]?, cmd: [String]?,
        environment: [String], workingDirectory: String?, user: String?, hostname: String?,
        labels: [String: String], tty: Bool, autoRemove: Bool, stopTimeout: Int?,
        mounts: [DockerRuntimeMount], ports: [DockerRuntimePortBinding],
        attachStdin: Bool = false, openStdin: Bool = false, stdinOnce: Bool = false,
        networkMode: String = "default", readonlyRootfs: Bool = false, privileged: Bool = false,
        networkIPv4Address: String? = nil, networkIPv6Address: String? = nil,
        networkAliases: [String] = [],
        healthcheck: DockerRuntimeHealthcheck? = nil,
        restartPolicy: DockerRuntimeRestartPolicy = .init(),
        restartCount: Int = 0, resources: DockerRuntimeResources = .init(), stopSignal: String? = nil,
        dns: [String] = [], dnsSearch: [String] = [], extraHosts: [String] = []
    ) {
        self.name = name
        self.image = image
        self.command = command
        self.entrypoint = entrypoint
        self.cmd = cmd
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.user = user
        self.hostname = hostname
        self.labels = labels
        self.tty = tty
        self.autoRemove = autoRemove
        self.stopTimeout = stopTimeout
        self.mounts = mounts
        self.ports = ports
        self.attachStdin = attachStdin
        self.openStdin = openStdin
        self.stdinOnce = stdinOnce
        self.networkMode = networkMode
        self.networkIPv4Address = networkIPv4Address
        self.networkIPv6Address = networkIPv6Address
        self.networkAliases = networkAliases
        self.readonlyRootfs = readonlyRootfs
        self.privileged = privileged
        self.healthcheck = healthcheck
        self.restartPolicy = restartPolicy
        self.restartCount = restartCount
        self.resources = resources
        self.stopSignal = stopSignal
        self.dns = dns
        self.dnsSearch = dnsSearch
        self.extraHosts = extraHosts
    }
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
    let stopTimeout: Int?
    let sizeRw: Int64
    let sizeRootFs: Int64
    let health: DockerRuntimeHealth
    let healthcheck: DockerRuntimeHealthcheck?
    let restartPolicy: DockerRuntimeRestartPolicy
    let restartCount: Int
    let resources: DockerRuntimeResources
    let stopSignal: String
    let networkMode: String
    let autoRemove: Bool
    let entrypoint: [String]?
    let cmd: [String]?
    let environment: [String]
    let workingDirectory: String
    let user: String
    let hostname: String
    let attachStdin: Bool
    let openStdin: Bool
    let stdinOnce: Bool
    let mounts: [DockerRuntimeMount]
    let readonlyRootfs: Bool
    let privileged: Bool
    let dns: [String]
    let dnsSearch: [String]
    let extraHosts: [String]

    init(
        id: String,
        name: String,
        image: String,
        command: [String],
        createdAt: Date,
        state: EngineContainerState,
        exitCode: Int32?,
        labels: [String: String],
        tty: Bool,
        ports: [DockerRuntimePortBinding],
        sizeRw: Int64 = -1,
        sizeRootFs: Int64 = -1,
        stopTimeout: Int? = nil,
        health: DockerRuntimeHealth = .init(),
        healthcheck: DockerRuntimeHealthcheck? = nil,
        restartPolicy: DockerRuntimeRestartPolicy = .init(),
        restartCount: Int = 0,
        resources: DockerRuntimeResources = .init(),
        stopSignal: String = "", networkMode: String = "default", autoRemove: Bool = false,
        entrypoint: [String]? = nil, cmd: [String]? = nil, environment: [String] = [],
        workingDirectory: String = "", user: String = "", hostname: String = "",
        attachStdin: Bool = false, openStdin: Bool = false, stdinOnce: Bool = false,
        mounts: [DockerRuntimeMount] = [], readonlyRootfs: Bool = false, privileged: Bool = false,
        dns: [String] = [], dnsSearch: [String] = [], extraHosts: [String] = []
    ) {
        self.id = id
        self.name = name
        self.image = image
        self.command = command
        self.createdAt = createdAt
        self.state = state
        self.exitCode = exitCode
        self.labels = labels
        self.tty = tty
        self.ports = ports
        self.sizeRw = sizeRw
        self.sizeRootFs = sizeRootFs
        self.stopTimeout = stopTimeout
        self.health = health
        self.healthcheck = healthcheck
        self.restartPolicy = restartPolicy
        self.restartCount = restartCount
        self.resources = resources
        self.stopSignal = stopSignal
        self.networkMode = networkMode
        self.autoRemove = autoRemove
        self.entrypoint = entrypoint
        self.cmd = cmd
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.user = user
        self.hostname = hostname
        self.attachStdin = attachStdin
        self.openStdin = openStdin
        self.stdinOnce = stdinOnce
        self.mounts = mounts
        self.readonlyRootfs = readonlyRootfs
        self.privileged = privileged
        self.dns = dns
        self.dnsSearch = dnsSearch
        self.extraHosts = extraHosts
    }
}

struct DockerRuntimeContainerUpdate: Decodable, Sendable, Equatable {
    let nanoCPUs: Int64?
    let cpuShares: Int64?
    let memory: Int64?
    let memorySwap: Int64?
    let memoryReservation: Int64?
    let cpuPeriod: Int64?
    let cpuQuota: Int64?
    let cpusetCpus: String?
    let cpusetMems: String?
    let pidsLimit: Int64?
    let restartPolicy: DockerRuntimeRestartPolicy?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case nanoCPUs = "NanoCpus"
        case cpuShares = "CpuShares"
        case memory = "Memory"
        case memorySwap = "MemorySwap"
        case memoryReservation = "MemoryReservation"
        case cpuPeriod = "CpuPeriod"
        case cpuQuota = "CpuQuota"
        case cpusetCpus = "CpusetCpus"
        case cpusetMems = "CpusetMems"
        case pidsLimit = "PidsLimit"
        case restartPolicy = "RestartPolicy"
    }

    static let supportedDockerFields = Set(CodingKeys.allCases.map(\.stringValue))

    func validate() throws {
        if let cpuShares, cpuShares < 0 {
            throw DockerRuntimeRouteError.invalidRequest("CpuShares must be non-negative")
        }
        if let nanoCPUs, nanoCPUs < 0 {
            throw DockerRuntimeRouteError.invalidRequest("NanoCpus must be non-negative")
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
        if let restartPolicy, !["", "no", "always", "unless-stopped", "on-failure"].contains(restartPolicy.name) {
            throw DockerRuntimeRouteError.invalidRequest(
                "RestartPolicy.Name must be no, always, unless-stopped, or on-failure"
            )
        }
        if let restartPolicy, restartPolicy.maximumRetryCount < 0 {
            throw DockerRuntimeRouteError.invalidRequest(
                "RestartPolicy.MaximumRetryCount must be non-negative"
            )
        }
    }
}

struct DockerRuntimeNetworkContainer: Sendable {
    let name: String
    let endpointID: String?
    let macAddress: String?
    let ipv4Address: String
    let ipv6Address: String?
    let aliases: [String]?
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
    let attachStdin: Bool
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
        try routes.registerVersionedRoute(.POST, pattern: "/build", use: buildImage)
        try routes.registerVersionedRoute(.POST, pattern: "/build/prune", use: pruneBuildCache)
        try routes.registerVersionedRoute(.POST, pattern: "/images/load", body: .stream, use: importImages)
        try routes.registerVersionedRoute(.POST, pattern: "/images/create", body: .stream, use: pullImage)
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

    private func buildImage(_ req: Request) async throws -> Response {
        guard
            let buffer = try await req.body.collect(
                max: min(
                    req.application.routes.defaultMaxBodySize.value,
                    DockerRuntimeGuestLimits.maximumBuildContextBytes
                )
            ).get(),
            let context = buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes),
            !context.isEmpty
        else {
            throw Abort(.badRequest, reason: "Build context request body is required")
        }

        let dockerfile = req.query[String.self, at: "dockerfile"] ?? "Dockerfile"
        guard !dockerfile.isEmpty else {
            throw Abort(.badRequest, reason: "dockerfile must not be empty")
        }
        let tags = req.query[String.self, at: "t"]?.split(separator: ",").map(String.init) ?? []
        let buildArgs = try Self.buildArguments(req.query[String.self, at: "buildargs"])
        let image: DockerRuntimeImage
        if let optionsBackend = backend as? any DockerRuntimeImageBuildOptionsBackend {
            image = try await call {
                try await optionsBackend.buildImage(
                    context: context, dockerfile: dockerfile, tags: tags, buildArgs: buildArgs
                )
            }
        } else {
            image = try await call {
                try await backend.buildImage(context: context, dockerfile: dockerfile, tags: tags)
            }
        }

        struct BuildProgress: Encodable {
            let stream: String
        }
        var body = try JSONEncoder().encode(
            BuildProgress(stream: "Successfully built \(image.digest)\n")
        )
        body.append(0x0A)
        let response = Response(status: .ok, body: .init(data: body))
        response.headers.contentType = .json
        return response
    }

    private func pruneBuildCache(_ req: Request) async throws -> Response {
        _ = try DockerBuildFilterUtility.parseBuildPruneFilters(
            filtersParam: req.query[String.self, at: "filters"], logger: req.logger
        )
        struct BuildCachePruneResponse: Encodable {
            let CachesDeleted: [String]
            let SpaceReclaimed: Int64
        }
        if let cacheBackend = backend as? any DockerRuntimeBuildCacheBackend {
            let result = try await call { try await cacheBackend.pruneBuildCache(all: true) }
            await broadcastBuilderPrune(req, reclaimed: result.spaceReclaimed ?? 0)
            return try jsonResponse(
                .ok,
                BuildCachePruneResponse(
                    CachesDeleted: (result.cachesDeleted ?? []).map { $0.id },
                    SpaceReclaimed: result.spaceReclaimed ?? 0
                )
            )
        }
        await broadcastBuilderPrune(req, reclaimed: 0)
        return try jsonResponse(.ok, BuildCachePruneResponse(CachesDeleted: [], SpaceReclaimed: 0))
    }

    private func broadcastBuilderPrune(_ req: Request, reclaimed: Int64) async {
        guard let broadcaster = req.application.storage[EventBroadcasterKey.self] else { return }
        await broadcaster.broadcast(
            DockerEvent.make(
                type: "builder", action: "prune", actorID: "",
                attributes: ["reclaimed": String(reclaimed)]
            )
        )
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
        let reference: String? = {
            guard let repository = req.query[String.self, at: "repo"], !repository.isEmpty else {
                return nil
            }
            return Self.imageReference(
                fromImage: repository, tag: req.query[String.self, at: "tag"]
            )
        }()

        // Streaming path: chunks flow straight from the request body into
        // guest stdin frames with end-to-end backpressure, so arbitrarily
        // large archives import without a memory ceiling.
        if let streamingBackend = backend as? any DockerRuntimeImageImportStreamingBackend {
            let session = try await call {
                try await streamingBackend.openImportSession(reference: reference)
            }
            let sawData = SawDataFlag()
            do {
                try await Self.pumpRequestBody(req) { data in
                    sawData.mark()
                    try await session.write(data)
                }
                try await session.endInput()
            } catch {
                session.abort()
                throw error
            }
            guard sawData.didSeeData else {
                throw Abort(.badRequest, reason: "Image archive request body is required")
            }
            let imported = try await call { try await session.finish() }
            return try Self.buildImportResponse(imported)
        }

        guard
            let buffer = try await req.body.collect(
                max: min(
                    req.application.routes.defaultMaxBodySize.value,
                    DockerRuntimeGuestLimits.maximumImportArchiveBytes
                )
            ).get(),
            let data = buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes),
            !data.isEmpty
        else {
            throw Abort(.badRequest, reason: "Image archive request body is required")
        }
        let images: [DockerRuntimeImage]
        if let importer = backend as? any DockerRuntimeImageImportBackend {
            images = try await call {
                try await importer.importImages(data: data, reference: reference)
            }
        } else {
            images = try await call { try await backend.importImages(data: data) }
        }
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

    /// Streams the HTTP request body chunk-by-chunk into `sink`. Vapor's drain
    /// callback returns a future per chunk, so the next chunk is only read once
    /// the previous one has been fully written to the guest — that future is
    /// what carries backpressure.
    private static func pumpRequestBody(
        _ req: Request, sink: @escaping @Sendable (Data) async throws -> Void
    ) async throws {
        let eventLoop = req.eventLoop
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let completionBox = DrainCompletionBox(continuation: continuation)
            req.body.drain { (result: BodyStreamResult) -> EventLoopFuture<Void> in
                switch result {
                case .buffer(let buffer):
                    let promise = eventLoop.makePromise(of: Void.self)
                    Task {
                        do {
                            try await sink(Data(buffer: buffer))
                            promise.succeed(())
                        } catch {
                            promise.fail(error)
                            completionBox.resumeOnce(with: error)
                        }
                    }
                    return promise.futureResult
                case .end:
                    completionBox.resumeOnce()
                    return eventLoop.makeSucceededFuture(())
                case .error(let error):
                    completionBox.resumeOnce(with: error)
                    return eventLoop.makeSucceededFuture(())
                @unknown default:
                    completionBox.resumeOnce()
                    return eventLoop.makeSucceededFuture(())
                }
            }
        }
    }

    private static func buildImportResponse(_ images: [DockerRuntimeImage]) throws -> Response {
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
            ID: "glassdock-\(ProcessInfo.processInfo.hostName)",
            Containers: containers.count,
            ContainersRunning: running,
            ContainersPaused: paused,
            ContainersStopped: stopped,
            Images: images.count,
            Driver: "overlayfs",
            DriverStatus: [["Backing Filesystem", "virtualized"]],
            DockerRootDir: GlassDockDirectories.engineStateDirectory.path,
            Plugins: PluginsInfo(),
            MemoryLimit: true,
            SwapLimit: false,
            CpuCfsPeriod: true,
            CpuCfsQuota: true,
            CPUShares: true,
            CPUSet: true,
            PidsLimit: true,
            IPv4Forwarding: true,
            Debug: false,
            KernelVersion: getKernel(),
            OSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            OSType: "linux",
            OperatingSystem: "Glass Dock guest runtime",
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
            IndexServerAddress: "https://index.docker.io/v1/",
            LoggingDriver: "json-file",
            CgroupDriver: "none",
            CgroupVersion: "2",
            SecurityOptions: ["name=seccomp,profile=default"],
            ProductLicense: "Apache-2.0",
            SystemTime: ISO8601DateFormatter().string(from: Date()),
            Warnings: [
                "Some Docker Engine capabilities are unavailable because Glass Dock uses a persistent containerd guest runtime."
            ]
        )
        return try jsonResponse(.ok, info)
    }

    private func listImages(_ req: Request) async throws -> Response {
        let filters = try ImageListFilter.parse(req.query[String.self, at: "filters"])
        try ImageListFilter.validate(filters)
        let images = try await call { try await backend.listImages() }
        let filtered = try ImageListFilter.apply(images, filters: filters)
        let containers = try await call { try await backend.listContainers(showAll: true) }
        let includeSharedSize = Self.mobyBool(req.query[String.self, at: "shared-size"])
        let includeDigests = Self.mobyBool(req.query[String.self, at: "digests"])
        let includeManifests = Self.mobyBool(req.query[String.self, at: "manifests"])
        return try jsonResponse(
            .ok,
            filtered.map { image in
                ImageSummary(
                    image,
                    includeSharedSize: includeSharedSize,
                    includeDigests: includeDigests,
                    includeManifests: includeManifests,
                    containerCount: Int64(
                        containers.filter { Self.imageMatchesContainer($0, image: image) }.count
                    )
                )
            }
        )
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
        let filters = try Self.imagePruneFilters(req.query[String.self, at: "filters"])
        let all = filters["dangling"]?.contains { $0 == "false" || $0 == "0" } == true
        let result: DockerRuntimeImageDelete
        if let filteredBackend = backend as? any DockerRuntimeImagePruneBackend {
            result = try await call {
                try await filteredBackend.pruneImages(all: all, filters: filters)
            }
        } else {
            result = try await call { try await backend.pruneImages(all: all) }
        }
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
            container.state != .running && container.state != .paused && container.state != .restarting
                && (filters.map { Self.matches(container, filters: $0) } ?? true)
        }
        var deleted: [String] = []
        var reclaimed: Int64 = 0
        for container in candidates {
            try await call {
                try await backend.deleteContainer(id: container.id, force: false, removeVolumes: false)
            }
            deleted.append(container.id)
            if container.sizeRw > 0 {
                reclaimed = reclaimed.addingReportingOverflow(container.sizeRw).partialValue
            }
        }
        return try jsonResponse(
            .ok,
            ContainerPruneResponse(ContainersDeleted: deleted, SpaceReclaimed: reclaimed)
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
        let changes = (try? req.query.get([String].self, at: "changes"))?.joined(separator: "\n")
        let image = try await call {
            try await backend.commitImage(
                container: container,
                repository: req.query[String.self, at: "repo"],
                tag: req.query[String.self, at: "tag"],
                comment: req.query[String.self, at: "comment"],
                author: req.query[String.self, at: "author"],
                pause: req.query[String.self, at: "pause"].map(Self.mobyBool) ?? true,
                changes: changes
            )
        }
        struct CommitResponse: Encodable {
            let Id: String
        }
        return try jsonResponse(.created, CommitResponse(Id: image.digest))
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
        return try await imageExportResponse(references: references, logger: req.logger)
    }

    private func exportNamedImage(_ req: Request) async throws -> Response {
        let reference = try requiredParameter("name", request: req)
        return try await imageExportResponse(references: [reference], logger: req.logger)
    }

    private func imageExportResponse(references: [String], logger: Logger) async throws -> Response {
        // Validate every reference before headers are sent so missing images are
        // clean 404s instead of errors inside an already-committed stream body.
        for reference in references {
            _ = try await call { try await backend.inspectImage(reference: reference) }
        }
        // The first chunk gates the response: if the guest rejects the export
        // during setup (missing content, unknown image), the error surfaces as
        // a real HTTP 500 instead of a committed 200 with a dropped body.
        let (first, remaining) = try await call {
            try await backend.exportImages(references: references)
        }
        return try await streamingResponse(
            logger: logger,
            contentType: HTTPMediaType(type: "application", subType: "x-tar")
        ) { writer in
            try await writer.writeBuffer(ByteBuffer(data: first))
            for try await data in remaining {
                try await writer.writeBuffer(ByteBuffer(data: data))
            }
        }
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
        let image = try await call { try await backend.inspectImage(reference: body.Image) }
        let resolvedMounts = try await mounts(from: body.HostConfig)
        var mounts = resolvedMounts.mounts
        let imageVolumeTargets = try Self.imageVolumeTargets(image.config.volumes)
        var autoCreatedVolumes = resolvedMounts.autoCreatedVolumes
        var anonymousVolumeNames = resolvedMounts.anonymousVolumeNames
        let stopSignal = body.StopSignal.flatMap { $0.isEmpty ? nil : $0 } ?? image.config.stopSignal
        do {
            if let volumeClient {
                let explicitTargets = Set(mounts.map { Self.normalizedContainerPath($0.target) })
                for target in imageVolumeTargets.sorted() where !explicitTargets.contains(target) {
                    let volume = try await volumeClient.create(
                        request: RESTVolumeCreate(
                            Name: "",
                            Driver: "local",
                            Options: [:],
                            Labels: [ClientVolumeService.anonymousVolumeLabel: "true"]
                        )
                    )
                    autoCreatedVolumes.append(volume)
                    anonymousVolumeNames.insert(volume.Name)
                    mounts.append(
                        DockerRuntimeMount(
                            source: volume.Mountpoint,
                            target: target,
                            readOnly: false,
                            type: "bind",
                            volumeName: volume.Name
                        )
                    )
                }
            }
        } catch {
            await deleteAutoCreatedVolumes(autoCreatedVolumes)
            throw error
        }
        let networkMode = Self.networkMode(body: body)
        let endpointConfig = Self.endpointConfig(body: body, networkMode: networkMode)
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
            stopTimeout: body.StopTimeout,
            mounts: mounts,
            ports: Self.ports(from: body.HostConfig),
            attachStdin: body.AttachStdin ?? false,
            openStdin: body.OpenStdin ?? false,
            stdinOnce: body.StdinOnce ?? false,
            networkMode: networkMode,
            readonlyRootfs: body.HostConfig?.ReadonlyRootfs ?? false,
            privileged: body.HostConfig?.Privileged ?? false,
            networkIPv4Address: endpointConfig?.IPAMConfig?.IPv4Address,
            networkIPv6Address: endpointConfig?.IPAMConfig?.IPv6Address,
            networkAliases: Self.endpointAliases(endpointConfig) ?? [],
            healthcheck: body.Healthcheck.flatMap(Self.healthcheck),
            restartPolicy: Self.restartPolicy(body.HostConfig?.RestartPolicy),
            resources: Self.resources(body.HostConfig),
            stopSignal: stopSignal,
            dns: body.HostConfig?.Dns ?? [],
            dnsSearch: body.HostConfig?.DnsSearch ?? [],
            extraHosts: body.HostConfig?.ExtraHosts ?? []
        )
        try Self.validateCreateRequest(request)
        let container: DockerRuntimeContainer
        do {
            container = try await call { try await backend.createContainer(request) }
        } catch {
            await deleteAutoCreatedVolumes(autoCreatedVolumes)
            throw error
        }
        do {
            for mount in mounts
            where
                mount.volumeName != nil
                && !mount.noCopy
                && imageVolumeTargets.contains(Self.normalizedContainerPath(mount.target))
            {
                try await copyUpImageVolume(
                    containerID: container.id,
                    imagePath: Self.normalizedContainerPath(mount.target),
                    volumePath: mount.source
                )
            }
            if let volumes = volumeClient as? RuntimeVolumeService {
                try await volumes.retain(
                    names: Set(mounts.compactMap(\.volumeName)), containerID: container.id,
                    anonymousNames: anonymousVolumeNames)
            }
        } catch {
            try? await backend.deleteContainer(
                id: container.id, force: true, removeVolumes: false)
            await deleteAutoCreatedVolumes(autoCreatedVolumes)
            throw error
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
        // Moby's rename operation takes the new name as a required query
        // parameter, not a request body.
        guard let rawName = req.query[String.self, at: "name"], !rawName.isEmpty else {
            throw Abort(.badRequest, reason: "Neither json name nor query param name was specified")
        }
        let name = rawName.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !name.isEmpty else { throw Abort(.badRequest, reason: "Container name cannot be empty") }
        guard DockerContainerMetadataStore.isValid(name) else {
            throw Abort(.badRequest, reason: "Invalid container name: \(rawName)")
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
        return Response(status: .ok)
    }

    private func restartContainer(_ req: Request) async throws -> Response {
        let id = try requiredParameter("id", request: req)
        let container = try await call { try await backend.inspectContainer(id: id) }
        let timeout = req.query[Int.self, at: "t"] ?? container.stopTimeout ?? 10
        if container.state == .running || container.state == .paused {
            if container.state == .paused {
                try await call { try await backend.resumeContainer(id: id) }
            }
            let signalText = req.query[String.self, at: "signal"] ?? container.stopSignal
            let resolvedSignalText = signalText.isEmpty ? "TERM" : signalText
            guard let signal = DockerSignal.number(resolvedSignalText) else {
                throw Abort(.badRequest, reason: "Invalid restart signal: \(resolvedSignalText)")
            }
            try await stopAndWait(id: id, signal: signal, timeout: timeout)
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
        let backend = self.backend
        return try await streamingResponse(
            logger: req.logger,
            contentType: .json,
            resolve: {
                // Resolve before headers are sent: a missing container must
                // surface as a normal 404, not as an error inside an
                // already-committed stream body.
                _ = try await backend.inspectContainer(id: id)
            }
        ) { writer in
            let exitCode = try await backend.waitContainer(id: id, condition: condition)
            let data = try JSONEncoder().encode(RESTContainerWait(statusCode: Int64(exitCode)))
            try await writer.writeBuffer(ByteBuffer(bytes: data))
        }
    }

    private func stopContainer(_ req: Request) async throws -> Response {
        let id = try requiredParameter("id", request: req)
        let container = try await call { try await backend.inspectContainer(id: id) }
        guard container.state == .running || container.state == .paused else {
            return Response(status: .notModified)
        }
        if container.state == .paused {
            try await call { try await backend.resumeContainer(id: id) }
        }
        let signalText = req.query[String.self, at: "signal"] ?? container.stopSignal
        let resolvedSignalText = signalText.isEmpty ? "TERM" : signalText
        guard let signal = DockerSignal.number(resolvedSignalText) else {
            throw Abort(.badRequest, reason: "Invalid stop signal: \(resolvedSignalText)")
        }
        let timeout = req.query[Int.self, at: "t"] ?? container.stopTimeout ?? 10
        try await stopAndWait(id: id, signal: signal, timeout: timeout)
        return Response(status: .noContent)
    }

    private func stopAndWait(id: String, signal: UInt32, timeout: Int) async throws {
        try await call { try await backend.killContainer(id: id, signal: signal) }
        if timeout < 0 {
            // Docker's t=-1 waits indefinitely for the container to exit.
            _ = try await call { try await backend.waitContainer(id: id, condition: .notRunning) }
            return
        }
        do {
            // The wait runs as a real group child so cancelAll() can unwind it
            // when the timeout fires. Awaiting an unstructured Task here would
            // deadlock: Task.value ignores cancellation, so the group could
            // never finish and SIGKILL escalation would never run.
            _ = try await withThrowingTaskGroup(of: Int32.self) { group in
                group.addTask { try await backend.waitContainer(id: id, condition: .notRunning) }
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
            _ = try await call { try await backend.waitContainer(id: id, condition: .notRunning) }
        }
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
        let networks = try await call { try await backend.listNetworks() }
        let includeSize = Self.mobyBool(req.query[String.self, at: "size"])
        return try jsonResponse(
            .ok,
            InspectResponse(container, networks: networks, includeSize: includeSize)
        )
    }

    private func listContainers(_ req: Request) async throws -> Response {
        var containers = try await call {
            try await backend.listContainers(showAll: Self.mobyBool(req.query[String.self, at: "all"]))
        }
        if let raw = req.query[String.self, at: "filters"] {
            let filters = try Self.containerFilters(raw)
            try Self.validateContainerListFilters(filters)
            let resolvedFilters = Self.resolveContainerReferenceFilters(
                filters, containers: containers
            )
            let networks =
                filters.keys.contains("network")
                ? try await call { try await backend.listNetworks() }
                : []
            containers = containers.filter {
                Self.matches($0, filters: resolvedFilters, networks: networks)
            }
        }
        if let limit = req.query[Int.self, at: "limit"] {
            guard limit >= 0 else { throw Abort(.badRequest, reason: "limit must be non-negative") }
            if limit > 0 {
                containers = Array(containers.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
            }
        }
        let includeSize = Self.mobyBool(req.query[String.self, at: "size"])
        return try jsonResponse(.ok, containers.map { ListResponse($0, includeSize: includeSize) })
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
                aliases: Self.endpointAliases(body.EndpointConfig),
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

        var deleted: [String] = []
        var errors: [String: String] = [:]
        for network in candidates {
            guard network.Id != "glassdock0", network.Name != "bridge" else { continue }
            do {
                let current = try await call { try await backend.inspectNetwork(id: network.Id) }
                guard current.containers.isEmpty else { continue }
                try await call { try await backend.deleteNetwork(id: network.Id) }
                deleted.append(network.Id)
                if let broadcaster = req.application.storage[EventBroadcasterKey.self] {
                    await broadcaster.broadcast(
                        DockerEvent.make(
                            type: "network", action: "destroy", actorID: network.Id,
                            attributes: ["name": network.Name, "type": network.Driver]))
                }
            } catch {
                errors[network.Id] = String(describing: error)
            }
        }
        if let broadcaster = req.application.storage[EventBroadcasterKey.self] {
            await broadcaster.broadcast(
                DockerEvent.make(
                    type: "network", action: "prune", actorID: "",
                    attributes: ["reclaimed": "0"]))
        }
        return try jsonResponse(
            .ok,
            DockerRuntimeNetworkPruneResponse(NetworksDeleted: deleted, Errors: errors)
        )
    }

    private func deleteNetwork(_ req: Request) async throws -> Response {
        let id = try requiredParameter("id", request: req)
        let network = try await call { try await backend.inspectNetwork(id: id) }
        if Self.isProtectedGuestNetwork(network) {
            throw Abort(.forbidden, reason: "error while removing network: \(network.name) is a protected guest network")
        }
        try await call { try await backend.deleteNetwork(id: network.id) }
        return Response(status: .noContent)
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
        let container = try await call { try await backend.inspectContainer(id: id) }
        let name = container.name.hasPrefix("/") ? container.name : "/\(container.name)"
        return try await streamingResponse(
            logger: req.logger,
            contentType: .json,
        ) { writer in
            repeat {
                var stats = try await backend.statsContainer(id: id)
                stats.name = name
                var data = try JSONEncoder().encode(stats)
                if stream { data.append(0x0A) }
                try await writer.writeBuffer(ByteBuffer(data: data))
                if !stream || oneShot { break }
                try await Task.sleep(for: .seconds(1))
            } while !Task.isCancelled
        }
    }

    private func exportContainer(_ req: Request) async throws -> Response {
        let id = try requiredParameter("id", request: req)
        let stream = try await call { try await backend.exportContainer(id: id) }
        return try await streamingResponse(
            logger: req.logger,
            contentType: HTTPMediaType(type: "application", subType: "octet-stream"),
            resolve: {
                // Resolve before headers are sent so a missing container is a
                // clean 404.
                _ = try await inspectContainer(id: id)
            }
        ) { writer in
            for try await data in stream {
                try await writer.writeBuffer(ByteBuffer(data: data))
            }
        }
    }

    private func archiveContainer(_ req: Request) async throws -> Response {
        let id = try requiredParameter("id", request: req)
        let path = try requiredQuery("path", request: req)
        let info = try await call { try await backend.archiveContainerInfo(id: id, path: path) }
        let stream = try await call { try await backend.archiveContainer(id: id, path: path) }
        let statHeader = try Self.archivePathStatHeader(info)
        return try await streamingResponse(
            logger: req.logger,
            contentType: HTTPMediaType(type: "application", subType: "x-tar"),
            extraHeaders: { headers in
                headers.replaceOrAdd(name: "X-Docker-Container-Path-Stat", value: statHeader)
            }
        ) { writer in
            for try await data in stream {
                try await writer.writeBuffer(ByteBuffer(data: data))
            }
        }
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
        guard
            let buffer = try await req.body.collect(
                max: min(
                    req.application.routes.defaultMaxBodySize.value,
                    DockerRuntimeGuestLimits.maximumContainerArchiveBytes
                )
            ).get(),
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
            attachStdin: body.AttachStdin ?? false,
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
        return Response(status: .ok)
    }

    private func startExec(_ req: Request) async throws -> Response {
        let id = try requiredParameter("id", request: req)
        guard let entry = execState.entry(id: id) else {
            throw Abort(.notFound, reason: "Exec instance not found: \(id)")
        }
        let body: ExecStartRequest
        if let buffer = try await req.body.collect(
            max: req.application.routes.defaultMaxBodySize.value
        ).get(), buffer.readableBytes > 0 {
            do {
                guard let data = buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes)
                else { throw Abort(.badRequest, reason: "Invalid exec start request") }
                body = try JSONDecoder().decode(ExecStartRequest.self, from: data)
            } catch let abort as Abort {
                throw abort
            } catch {
                throw Abort(.badRequest, reason: "Invalid exec start request: \(error)")
            }
        } else {
            body = ExecStartRequest(Detach: nil, Tty: nil)
        }
        let tty = body.Tty ?? entry.request.tty
        let relay = entry.request.attachStdin ? GuestInputRelay() : nil
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
            return Response(status: .ok)
        }
        try execState.markRunning(id: id)
        let upgraded =
            req.headers.first(name: "Upgrade")?.lowercased() == "tcp"
            && req.headers.first(name: "Connection")?.lowercased().split(separator: ",")
                .map({ $0.trimmingCharacters(in: .whitespaces) }).contains("upgrade") == true
        var initialInput: Data?
        if relay != nil, !upgraded,
            let buffer = try await req.body.collect(
                max: req.application.routes.defaultMaxBodySize.value
            ).get()
        {
            initialInput = buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes)
        }
        let stream: AsyncThrowingStream<DockerRuntimeProcessFrame, Error>
        if let interactive = backend as? any DockerRuntimeInteractiveBackend {
            stream = try await call {
                try await interactive.streamExec(id: id, tty: tty, onInput: relay)
            }
        } else {
            stream = try await call { try await backend.streamExec(id: id, tty: tty) }
        }
        if let relay, let initialInput, !initialInput.isEmpty { relay.send(initialInput) }
        if let relay, !upgraded { relay.send(Data()) }
        if upgraded {
            let state = execState
            return .dockerTCPUpgrade(execId: id, ttyEnabled: tty) { channel, handler in
                if let relay {
                    handler.setStdinDataHandler { data in relay.send(data) }
                }
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
        let response = try await streamingResponse(
            logger: req.logger,
            contentType: HTTPMediaType(type: "application", subType: "vnd.docker.raw-stream")
        ) { writer in
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
        }
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
        var layersSize: Int64?
        var buildCache: [SystemDataUsageResponse.BuildCacheUsage] = []
        if let cacheBackend = backend as? any DockerRuntimeBuildCacheBackend {
            let usage = try await call { try await cacheBackend.systemDataUsage() }
            layersSize = usage.layersSize
            if includeAll || types.contains("build-cache") {
                buildCache = usage.buildCache.map(Self.buildCacheUsage)
            }
        }
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
            SystemDataUsageResponse(
                images: images,
                containers: containers,
                volumes: volumes,
                layersSizeOverride: layersSize,
                buildCache: buildCache
            )
        )
    }

    private static func buildCacheUsage(_ record: GuestBuildCacheRecord) -> SystemDataUsageResponse.BuildCacheUsage {
        SystemDataUsageResponse.BuildCacheUsage(
            id: record.id,
            type: record.type ?? "exec.cachemount",
            description: record.description ?? "",
            inUse: record.inUse ?? false,
            shared: record.shared ?? false,
            size: record.size ?? 0,
            createdAt: record.createdAt ?? Date(timeIntervalSince1970: 0),
            lastUsedAt: record.lastUsedAt,
            usageCount: record.usageCount ?? 0
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
            return Self.streamResponse(
                logger: req.logger, stream: stream, tty: container.tty, contentType: false
            )
        }
        let output: DockerRuntimeProcessOutput
        if let optionsBackend = backend as? any DockerRuntimeLogOptionsBackend {
            output = try await call {
                try await optionsBackend.logs(
                    id: id, stdout: stdout, stderr: stderr, options: options
                )
            }
        } else {
            var fallback = try await call {
                try await backend.logs(id: id, stdout: stdout, stderr: stderr)
            }
            if let tail = req.query[String.self, at: "tail"] {
                fallback = try Self.applyTail(fallback, value: tail)
            }
            output = fallback
        }
        return Self.streamResponse(output: output, tty: container.tty, contentType: true)
    }

    private func attach(_ req: Request) async throws -> Response {
        let id = try requiredParameter("id", request: req)
        let tty = try await inspectContainer(id: id).tty
        let backend = self.backend
        let replayLogs = Self.mobyBool(req.query[String.self, at: "logs"])
        let streamOutput = Self.mobyBool(req.query[String.self, at: "stream"])
        let relay =
            streamOutput && Self.mobyBool(req.query[String.self, at: "stdin"])
            ? GuestInputRelay() : nil
        let stdout = req.query[String.self, at: "stdout"].map(Self.mobyBool) ?? false
        let stderr = req.query[String.self, at: "stderr"].map(Self.mobyBool) ?? false
        guard stdout || stderr else {
            throw Abort(.badRequest, reason: "Bad parameters: you must choose at least one stream")
        }
        let options = DockerRuntimeLogOptions(
            timestamps: false, details: false, since: nil, until: nil,
            tail: replayLogs ? nil : 0
        )
        let upgraded =
            req.headers.first(name: "Upgrade")?.lowercased() == "tcp"
            && req.headers.first(name: "Connection")?.lowercased().split(separator: ",")
                .map({ $0.trimmingCharacters(in: .whitespaces) }).contains("upgrade") == true
        guard replayLogs || streamOutput else {
            var headers = HTTPHeaders()
            headers.contentType = HTTPMediaType(type: "application", subType: "vnd.docker.raw-stream")
            return Response(
                status: .ok,
                headers: headers,
                body: .init(data: Data())
            )
        }
        if replayLogs && !streamOutput {
            let output: DockerRuntimeProcessOutput
            if let optionsBackend = backend as? any DockerRuntimeLogOptionsBackend {
                output = try await call {
                    try await optionsBackend.logs(
                        id: id, stdout: stdout, stderr: stderr, options: options
                    )
                }
            } else {
                output = try await call { try await backend.logs(id: id, stdout: stdout, stderr: stderr) }
            }
            return Self.streamResponse(output: output, tty: tty, contentType: true)
        }
        var initialInput: Data?
        if relay != nil && !upgraded,
            let buffer = try await req.body.collect(
                max: req.application.routes.defaultMaxBodySize.value
            ).get()
        {
            initialInput = buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes)
        }
        let stream: AsyncThrowingStream<DockerRuntimeProcessFrame, Error>
        if let interactive = backend as? any DockerRuntimeInteractiveBackend {
            stream = try await call {
                try await interactive.attachContainer(
                    id: id, stdout: stdout, stderr: stderr,
                    options: options, onInput: relay
                )
            }
        } else {
            stream = try await call {
                try await backend.attachContainer(id: id, stdout: stdout, stderr: stderr)
            }
        }
        if let relay, let initialInput, !initialInput.isEmpty {
            relay.send(initialInput)
        }
        if let relay, !upgraded {
            relay.send(Data())
        }
        if upgraded {
            return .dockerTCPUpgrade(execId: id, ttyEnabled: tty) { channel, handler in
                if let relay {
                    handler.setStdinDataHandler { data in relay.send(data) }
                }
                do {
                    for try await frame in stream {
                        guard frame.exitCode == nil else { continue }
                        let bytes =
                            tty
                            ? frame.data
                            : Self.frame(frame.data, stream: frame.stream == .stderr ? 2 : 1)
                        var buffer = channel.allocator.buffer(capacity: bytes.count)
                        buffer.writeBytes(bytes)
                        try await channel.writeAndFlush(buffer).get()
                    }
                    try await channel.close().get()
                } catch {
                    throw error
                }
            }
        }
        var headers = HTTPHeaders()
        headers.contentType = HTTPMediaType(type: "application", subType: "vnd.docker.raw-stream")
        return try await streamingResponse(
            logger: req.logger,
            contentType: HTTPMediaType(type: "application", subType: "vnd.docker.raw-stream")
        ) { writer in
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
        }
    }

    private func attachWebSocket(_ req: Request) async throws -> Response {
        let id = try requiredParameter("id", request: req)
        let replayLogs = Self.mobyBool(req.query[String.self, at: "logs"])
        let streamOutput = Self.mobyBool(req.query[String.self, at: "stream"])
        let relay =
            streamOutput && Self.mobyBool(req.query[String.self, at: "stdin"])
            ? GuestInputRelay() : nil
        let stdout = req.query[String.self, at: "stdout"].map(Self.mobyBool) ?? false
        let stderr = req.query[String.self, at: "stderr"].map(Self.mobyBool) ?? false
        guard stdout || stderr else {
            throw Abort(.badRequest, reason: "Bad parameters: you must choose at least one stream")
        }
        let tty = try await inspectContainer(id: id).tty
        let backend = self.backend
        let options = DockerRuntimeLogOptions(
            timestamps: false, details: false, since: nil, until: nil,
            tail: replayLogs ? nil : 0
        )
        return req.webSocket { _, socket in
            do {
                if !replayLogs && !streamOutput {
                    try await socket.close()
                    return
                }
                if replayLogs && !streamOutput {
                    let output: DockerRuntimeProcessOutput
                    if let optionsBackend = backend as? any DockerRuntimeLogOptionsBackend {
                        output = try await optionsBackend.logs(
                            id: id, stdout: stdout, stderr: stderr, options: options
                        )
                    } else {
                        output = try await backend.logs(id: id, stdout: stdout, stderr: stderr)
                    }
                    if stdout, !output.stdout.isEmpty {
                        try await socket.send([UInt8](Self.frame(output.stdout, stream: 1)))
                    }
                    if stderr, !output.stderr.isEmpty {
                        try await socket.send([UInt8](Self.frame(output.stderr, stream: 2)))
                    }
                    try await socket.close()
                    return
                }
                let stream: AsyncThrowingStream<DockerRuntimeProcessFrame, Error>
                if let interactive = backend as? any DockerRuntimeInteractiveBackend {
                    stream = try await interactive.attachContainer(
                        id: id, stdout: stdout, stderr: stderr,
                        options: options, onInput: relay
                    )
                } else {
                    stream = try await backend.attachContainer(
                        id: id, stdout: stdout, stderr: stderr
                    )
                }
                if let relay {
                    socket.onBinary { _, buffer in
                        if let data = buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes) {
                            relay.send(data)
                        }
                    }
                    socket.onText { _, text in relay.send(Data(text.utf8)) }
                }
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

    /// Builds a streaming response under the resolve-before-commit contract:
    ///
    /// - `resolve` runs before response headers are committed and maps errors
    ///   through `call`, so missing containers or images surface as clean 404s
    ///   and conflicts as 409s instead of errors inside an already-committed
    ///   stream body (which clients observe as a silent connection drop).
    /// - Errors thrown by `body` after commit cannot become HTTP status codes
    ///   anymore. They are logged here and then terminate the stream; new
    ///   streaming routes must therefore validate everything client-dependent
    ///   in `resolve`.
    ///
    /// Every streaming route must be built through this helper so the contract
    /// cannot regress.
    private func streamingResponse(
        logger: Logger,
        status: HTTPResponseStatus = .ok,
        contentType: HTTPMediaType? = nil,
        extraHeaders: (inout HTTPHeaders) -> Void = { _ in },
        resolve: () async throws -> Void = {},
        body: @escaping @Sendable (AsyncBodyStreamWriter) async throws -> Void
    ) async throws -> Response {
        try await call(resolve)
        var headers = HTTPHeaders()
        if let contentType { headers.contentType = contentType }
        extraHeaders(&headers)
        return Response(
            status: status,
            headers: headers,
            body: .init(managedAsyncStream: { writer in
                do {
                    // Commit the response headers immediately by flushing an
                    // empty first chunk. Vapor defers the header write until
                    // the first body byte, but Moby's streaming endpoints
                    // (wait, events, attach, stats, logs follow) send their
                    // status line right away: docker run -d opens /wait and
                    // blocks on its response headers BEFORE sending the
                    // container start request.
                    try await writer.writeBuffer(ByteBuffer())
                    try await body(writer)
                } catch is CancellationError {
                    // Client disconnects land here; nothing left to report.
                } catch {
                    logger.error(
                        "stream terminated after response commit",
                        metadata: ["error": "\(error)"]
                    )
                }
            })
        )
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
                (try JSONSerialization.jsonObject(with: data) as? [String: Any]) != nil
            else {
                throw Abort(.badRequest, reason: "Container update request body is required")
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

    /// Streaming body for routes whose setup already completed before this is
    /// called. Post-commit errors cannot become HTTP statuses; they are logged
    /// and then terminate the stream.
    private static func streamResponse(
        logger: Logger,
        stream: AsyncThrowingStream<DockerRuntimeProcessFrame, Error>,
        tty: Bool,
        contentType: Bool = true
    ) -> Response {
        let response = Response(
            status: .ok,
            body: .init(managedAsyncStream: { writer in
                do {
                    // Commit headers immediately; see streamingResponse.
                    for try await frame in stream {
                        guard frame.exitCode == nil else { continue }
                        let data =
                            tty
                            ? frame.data
                            : Self.frame(frame.data, stream: frame.stream == .stderr ? 2 : 1)
                        try await writer.writeBuffer(ByteBuffer(data: data))
                    }
                } catch is CancellationError {
                } catch {
                    logger.error(
                        "stream terminated after response commit",
                        metadata: ["error": "\(error)"]
                    )
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

    private static func endpointAliases(_ config: DockerNetworkEndpointConfig?) -> [String]? {
        guard let config else { return nil }
        var result: [String] = []
        for alias in config.Aliases ?? [] {
            if !alias.isEmpty, !result.contains(alias) { result.append(alias) }
        }
        for link in config.Links ?? [] {
            let alias = link.split(separator: ":", omittingEmptySubsequences: true).last.map(String.init)
            if let alias, !result.contains(alias) { result.append(alias) }
        }
        return result.isEmpty ? nil : result
    }

    private static func endpointConfig(
        body: CreateRequest, networkMode: String
    ) -> DockerNetworkEndpointConfig? {
        guard let endpoints = body.NetworkingConfig?.EndpointsConfig, !endpoints.isEmpty else {
            return nil
        }
        let rawMode = body.HostConfig?.NetworkMode ?? ""
        let normalizedMode = rawMode.lowercased()
        if networkMode == "host" || networkMode == "none"
            || normalizedMode == "path" || normalizedMode.hasPrefix("container:")
        {
            return nil
        }
        if let exact = endpoints[rawMode] {
            return exact
        }
        if let normalized = endpoints[normalizedMode] {
            return normalized
        }
        if networkMode == "private" {
            if let bridge = endpoints["bridge"] { return bridge }
            if let `default` = endpoints["default"] { return `default` }
        }
        return endpoints.count == 1 ? endpoints.values.first : nil
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
            throw Abort(.badRequest, reason: "Invalid \(name) value: \(raw)")
        }
        return DockerRuntimeLogOptions(
            timestamps: mobyBool(req.query[String.self, at: "timestamps"]),
            details: mobyBool(req.query[String.self, at: "details"]),
            since: try parse("since"),
            until: try parse("until"),
            tail: try parseTail(req.query[String.self, at: "tail"])
        )
    }

    private static func parseTail(_ raw: String?) throws -> Int? {
        guard let raw, !raw.isEmpty, raw != "all" else { return nil }
        guard let count = Int(raw), count >= 0 else {
            throw Abort(.badRequest, reason: "Invalid tail value: \(raw)")
        }
        return count
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
        let ipamConfig = ipv4IPAMConfig(network) ?? network.ipam.Config.first
        let ipv6Config = ipv6IPAMConfig(network)
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
                    IPv4Address: Self.networkEndpointAddress(
                        $0.ipv4Address, subnet: ipamConfig?.Subnet
                    ),
                    IPv6Address: Self.networkEndpointAddress(
                        $0.ipv6Address, subnet: ipv6Config?.Subnet
                    )
                )
            },
            ConfigFrom: nil,
            Labels: network.labels,
            Subnet: ipamConfig?.Subnet,
            Gateway: ipamConfig?.Gateway
        )
    }

    private static func networkEndpointAddress(_ address: String?, subnet: String?) -> String {
        guard let address else { return "" }
        guard !address.isEmpty, !address.contains("/"), let subnet,
            let slash = subnet.lastIndex(of: "/"), Int(subnet[subnet.index(after: slash)...]) != nil
        else { return address }
        return "\(address)/\(subnet[subnet.index(after: slash)...])"
    }

    private static func ipv4IPAMConfig(_ network: DockerRuntimeNetwork) -> NetworkIPAMConfig? {
        network.ipam.Config.first { config in
            guard let subnet = config.Subnet, let slash = subnet.firstIndex(of: "/") else {
                return false
            }
            return !String(subnet[..<slash]).contains(":")
        }
    }

    private static func ipv6IPAMConfig(_ network: DockerRuntimeNetwork) -> NetworkIPAMConfig? {
        network.ipam.Config.first { config in
            guard let subnet = config.Subnet, let slash = subnet.firstIndex(of: "/") else {
                return false
            }
            return String(subnet[..<slash]).contains(":")
        }
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
        // Moby accepts a broad create schema and ignores fields that are not
        // meaningful to the selected runtime. Decode the fields that Glass
        // Dock can apply below and preserve the rest for forward compatibility.
        if let image = object["Image"] as? String, image.isEmpty {
            throw DockerRuntimeRouteError.invalidRequest("Image cannot be empty")
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

    fileprivate static func imageMatchesContainer(
        _ container: DockerRuntimeContainer, image: DockerRuntimeImage
    ) -> Bool {
        if image.references.contains(container.image) || image.digest == container.image {
            return true
        }
        let containerID =
            container.image.hasPrefix("sha256:")
            ? String(container.image.dropFirst("sha256:".count)) : container.image
        let imageID =
            image.digest.hasPrefix("sha256:")
            ? String(image.digest.dropFirst("sha256:".count)) : image.digest
        return containerID == imageID
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

    private static func buildArguments(_ raw: String?) throws -> [String: String] {
        guard let raw, !raw.isEmpty else { return [:] }
        guard let data = raw.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw Abort(.badRequest, reason: "Invalid buildargs query parameter")
        }
        var result: [String: String] = [:]
        for (key, value) in object {
            guard !key.isEmpty else {
                throw Abort(.badRequest, reason: "Build argument names must not be empty")
            }
            if value is NSNull { continue }
            guard let string = value as? String else {
                throw Abort(.badRequest, reason: "Build argument \(key) must be a string")
            }
            result[key] = string
        }
        return result
    }

    private static func imagePruneFilters(_ raw: String?) throws -> [String: [String]] {
        guard let raw else { return [:] }
        guard let data = raw.data(using: .utf8) else {
            throw Abort(.badRequest, reason: "Invalid image prune filters")
        }
        var filters: [String: [String]]
        if let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
            filters = decoded
        } else if let decoded = try? JSONDecoder().decode([String: [String: Bool]].self, from: data) {
            filters = decoded.mapValues { values in
                values.compactMap { $0.value ? $0.key : nil }
            }
        } else {
            throw Abort(.badRequest, reason: "Invalid image prune filters")
        }
        let supported = Set(["dangling", "label", "until"])
        if let unsupported = filters.keys.first(where: { !supported.contains($0) }) {
            throw Abort(.badRequest, reason: "Unsupported image prune filter: \(unsupported)")
        }
        if let dangling = filters["dangling"],
            dangling.contains(where: { value in
                value != "true" && value != "false" && value != "1" && value != "0"
            })
        {
            throw Abort(.badRequest, reason: "Invalid dangling image prune filter")
        }
        return filters
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

    private static let containerListFilterKeys: Set<String> = [
        "ancestor", "before", "expose", "exited", "health", "id", "is-task",
        "isolation", "label", "name", "network", "publish", "since", "status",
        "volume",
    ]

    private static func validateContainerListFilters(
        _ filters: [String: [String]]
    ) throws {
        if let unknown = filters.keys.first(where: { !containerListFilterKeys.contains($0) }) {
            throw Abort(.badRequest, reason: "Invalid container filter: \(unknown)")
        }
        if let health = filters["health"],
            health.contains(where: {
                !["starting", "healthy", "unhealthy", "none"].contains($0.lowercased())
            })
        {
            throw Abort(.badRequest, reason: "Invalid health filter")
        }
        if let isolation = filters["isolation"],
            isolation.contains(where: {
                !["default", "process", "hyperv"].contains($0.lowercased())
            })
        {
            throw Abort(.badRequest, reason: "Invalid isolation filter")
        }
    }

    private static func resolveContainerReferenceFilters(
        _ filters: [String: [String]], containers: [DockerRuntimeContainer]
    ) -> [String: [String]] {
        var resolved = filters
        for key in ["before", "since"] {
            guard let values = filters[key] else { continue }
            resolved[key] = values.map { value in
                guard parseDate(value) == nil,
                    let container = containers.first(where: {
                        $0.id == value || $0.id.hasPrefix(value)
                            || $0.name.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == value
                    })
                else { return value }
                return String(container.createdAt.timeIntervalSince1970)
            }
        }
        return resolved
    }

    private static func containerPruneFilters(_ raw: String) throws -> [String: [String]] {
        let filters = try containerFilters(raw)
        guard
            let unsupported = filters.keys.first(where: {
                $0 != "label" && $0 != "until"
            })
        else {
            return filters
        }
        throw Abort(.badRequest, reason: "Unsupported container prune filter: \(unsupported)")
    }

    private static func matches(
        _ container: DockerRuntimeContainer,
        filters: [String: [String]],
        networks: [DockerRuntimeNetwork] = []
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
            case "before", "since":
                guard let raw = values.first, let boundary = parseDate(raw) else { return false }
                return key == "before"
                    ? container.createdAt < boundary
                    : container.createdAt > boundary
            case "exited":
                return values.contains {
                    guard let code = Int32($0) else { return false }
                    return container.state == .exited && container.exitCode == code
                }
            case "health":
                let health = container.health.status.isEmpty ? "none" : container.health.status
                return values.contains { $0.lowercased() == health.lowercased() }
            case "isolation":
                return values.contains { $0.lowercased() == "default" }
            case "is-task":
                // Glass Dock's Swarm task records are kept outside the runtime
                // container list. A regular container is therefore a non-task.
                return values.contains { Self.mobyBool($0) == false }
            case "network":
                return values.contains { value in
                    networks.contains { network in
                        (network.id == value || network.id.hasPrefix(value) || network.name == value)
                            && network.containers[container.id] != nil
                    }
                }
            case "volume":
                return values.contains { value in
                    container.mounts.contains {
                        $0.target == value || $0.source == value || $0.volumeName == value
                    }
                }
            case "publish":
                return values.contains { Self.matchesPortFilter($0, ports: container.ports, published: true) }
            case "expose":
                return values.contains { Self.matchesPortFilter($0, ports: container.ports, published: false) }
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

    private static func matchesPortFilter(
        _ raw: String, ports: [DockerRuntimePortBinding], published: Bool
    ) -> Bool {
        let pieces = raw.split(separator: "/", maxSplits: 1).map(String.init)
        let portSpec = pieces.first ?? ""
        let protocolName = pieces.count == 2 ? pieces[1].lowercased() : nil
        let range = portSpec.split(separator: "-", maxSplits: 1).compactMap { Int($0) }
        guard !range.isEmpty, range.count == 1 || range.count == 2 else { return false }
        let lower = range[0]
        let upper = range.count == 2 ? range[1] : lower
        guard lower > 0, upper >= lower, upper <= 65_535 else { return false }
        return ports.contains { port in
            guard protocolName == nil || protocolName == port.proto.lowercased() else { return false }
            let candidate = published ? port.hostPort : Optional(port.containerPort)
            guard let candidate else { return false }
            return (lower...upper).contains(candidate)
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

    private func mounts(from host: CreateHostConfig?) async throws -> (
        mounts: [DockerRuntimeMount], autoCreatedVolumes: [Volume], anonymousVolumeNames: Set<String>
    ) {
        var result: [DockerRuntimeMount] = []
        var autoCreatedVolumes: [Volume] = []
        var anonymousVolumeNames: Set<String> = []
        for bind in host?.Binds ?? [] {
            let components = bind.split(separator: ":", maxSplits: 2).map(String.init)
            guard components.count >= 2, components[1].hasPrefix("/") else {
                throw Abort(.badRequest, reason: "Invalid bind mount: \(bind)")
            }
            let source = try await resolveMountSource(components[0])
            if source.isAnonymous {
                anonymousVolumeNames.insert(try requireVolumeName(source))
            }
            if let created = source.createdVolume, source.isAnonymous {
                autoCreatedVolumes.append(created)
            }
            let flags = components.count == 3 ? components[2].split(separator: ",").map(String.init) : []
            result.append(
                DockerRuntimeMount(
                    source: source.path,
                    target: components[1],
                    readOnly: flags.contains("ro"),
                    volumeName: source.volumeName,
                    noCopy: flags.contains("nocopy")
                ))
        }
        for mount in host?.Mounts ?? [] {
            guard mount.Target.hasPrefix("/") else {
                throw Abort(.badRequest, reason: "Invalid mount target")
            }
            switch mount.`Type`.lowercased() {
            case "bind":
                guard let source = mount.Source, source.hasPrefix("/") else {
                    throw Abort(.badRequest, reason: "Mount source is required")
                }
                let resolved = try await resolveMountSource(source)
                if resolved.isAnonymous {
                    anonymousVolumeNames.insert(try requireVolumeName(resolved))
                }
                if let created = resolved.createdVolume, resolved.isAnonymous {
                    autoCreatedVolumes.append(created)
                }
                result.append(
                    DockerRuntimeMount(
                        source: resolved.path, target: mount.Target,
                        // RuntimeVolumeService exposes the volume data through
                        // the shared host directory. The guest therefore
                        // receives a bind mount, while volumeName preserves
                        // Docker's volume identity for inspect and refcounts.
                        readOnly: mount.ReadOnly ?? false, type: "bind",
                        volumeName: resolved.volumeName,
                        noCopy: false
                    )
                )
            case "volume":
                if let source = mount.Source, source.hasPrefix("/") {
                    throw Abort(.badRequest, reason: "Volume source must be a volume name")
                }
                let resolved = try await resolveMountSource(mount.Source ?? "")
                if resolved.isAnonymous {
                    anonymousVolumeNames.insert(try requireVolumeName(resolved))
                }
                if let created = resolved.createdVolume, resolved.isAnonymous {
                    autoCreatedVolumes.append(created)
                }
                result.append(
                    DockerRuntimeMount(
                        source: resolved.path,
                        target: mount.Target,
                        // RuntimeVolumeService exposes the volume data through
                        // the shared host directory. The guest therefore
                        // receives a bind mount, while volumeName preserves
                        // Docker's volume identity for inspect and refcounts.
                        readOnly: mount.ReadOnly ?? false,
                        type: "bind",
                        volumeName: resolved.volumeName,
                        noCopy: mount.VolumeOptions?.NoCopy ?? false
                    )
                )
            case "tmpfs":
                var options: [String] = []
                if let tmpfs = mount.TmpfsOptions {
                    if let size = tmpfs.SizeBytes, size > 0 { options.append("size=\(size)") }
                    if let mode = tmpfs.Mode, mode > 0 { options.append("mode=\(String(mode, radix: 8))") }
                }
                result.append(
                    DockerRuntimeMount(
                        source: "", target: mount.Target, readOnly: mount.ReadOnly ?? false,
                        type: "tmpfs", options: options
                    )
                )
            default:
                throw Abort(.badRequest, reason: "Unsupported mount type \(mount.`Type`)")
            }
        }
        for (target, options) in host?.Tmpfs ?? [:] {
            guard target.hasPrefix("/") else {
                throw Abort(.badRequest, reason: "Invalid tmpfs target")
            }
            result.append(
                DockerRuntimeMount(
                    source: "", target: target, readOnly: false, type: "tmpfs",
                    options: options.split(separator: ",").map(String.init)
                )
            )
        }
        return (result, autoCreatedVolumes, anonymousVolumeNames)
    }

    private struct ResolvedMountSource {
        let path: String
        let volumeName: String?
        let isAnonymous: Bool
        let createdVolume: Volume?
    }

    private func requireVolumeName(_ source: ResolvedMountSource) throws -> String {
        guard let volumeName = source.volumeName, !volumeName.isEmpty else {
            throw Abort(.internalServerError, reason: "Anonymous volume did not return a name")
        }
        return volumeName
    }

    private func resolveMountSource(_ source: String) async throws -> ResolvedMountSource {
        if source.hasPrefix("/") {
            let canonicalSource = canonicalFileURL(URL(fileURLWithPath: source)).path
            return .init(path: canonicalSource, volumeName: nil, isAnonymous: false, createdVolume: nil)
        }
        guard let volumeClient else {
            throw Abort(.serviceUnavailable, reason: "Named volume mounts are not configured")
        }
        if !source.isEmpty {
            do {
                return .init(
                    path: try await volumeClient.inspect(name: source).Mountpoint,
                    volumeName: source, isAnonymous: false, createdVolume: nil)
            } catch {
                guard VolumeNotFound.matches(error) else { throw error }
            }
        }
        let volume = try await volumeClient.create(
            request: RESTVolumeCreate(
                Name: source,
                Driver: "local",
                Options: [:],
                Labels: source.isEmpty
                    ? [ClientVolumeService.anonymousVolumeLabel: ""]
                    : nil
            )
        )
        return .init(
            path: volume.Mountpoint, volumeName: volume.Name, isAnonymous: source.isEmpty,
            createdVolume: source.isEmpty ? volume : nil)
    }

    private static func normalizedContainerPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func imageVolumeTargets(_ volumes: Set<String>) throws -> Set<String> {
        var targets = Set<String>()
        for volume in volumes {
            guard volume.hasPrefix("/") else {
                throw Abort(.internalServerError, reason: "Image has an invalid VOLUME target: \(volume)")
            }
            let target = normalizedContainerPath(volume)
            guard target != "/" else {
                throw Abort(.internalServerError, reason: "Image VOLUME target cannot be the root filesystem")
            }
            targets.insert(target)
        }
        return targets
    }

    private func deleteAutoCreatedVolumes(_ volumes: [Volume]) async {
        guard let volumeClient else { return }
        for volume in volumes {
            try? await volumeClient.delete(name: volume.Name)
        }
    }

    private func copyUpImageVolume(
        containerID: String,
        imagePath: String,
        volumePath: String
    ) async throws {
        let volumeURL = URL(fileURLWithPath: volumePath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: volumeURL.path) else {
            throw Abort(.internalServerError, reason: "Volume mountpoint is missing: \(volumePath)")
        }
        guard
            try FileManager.default.contentsOfDirectory(
                at: volumeURL,
                includingPropertiesForKeys: nil,
                options: []
            ).isEmpty
        else {
            return
        }

        let temporaryDirectory = try RequestBodyFileWriter.createSecureTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let archivePath = temporaryDirectory.appendingPathComponent("volume.tar", isDirectory: false)
        do {
            _ = try await backend.archiveContainerInfo(id: containerID, path: imagePath)
        } catch let error as DockerRuntimeRouteError {
            if case .notFound = error { return }
            throw error
        }
        let stream = try await backend.archiveContainer(id: containerID, path: imagePath)
        _ = try await RequestBodyFileWriter.writeData(
            stream,
            to: archivePath,
            maxBytes: DockerRuntimeGuestLimits.maximumImageVolumeCopyUpBytes,
            kind: "image volume copy-up archive"
        )

        let extractionDirectory = temporaryDirectory.appendingPathComponent("extract", isDirectory: true)
        try ArchiveUtility.extract(
            tarPath: archivePath,
            to: extractionDirectory,
            limits: .volumeCopyUp
        )
        let rootName = URL(fileURLWithPath: imagePath).lastPathComponent
        let extractedRoot = extractionDirectory.appendingPathComponent(rootName, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: extractedRoot.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw Abort(.internalServerError, reason: "Image VOLUME archive has no directory root")
        }
        guard
            try FileManager.default.contentsOfDirectory(
                at: volumeURL,
                includingPropertiesForKeys: nil,
                options: []
            ).isEmpty
        else {
            return
        }
        for child in try FileManager.default.contentsOfDirectory(
            at: extractedRoot,
            includingPropertiesForKeys: nil,
            options: []
        ) {
            let destination = volumeURL.appendingPathComponent(child.lastPathComponent, isDirectory: false)
            try FileManager.default.moveItem(at: child, to: destination)
        }
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

    private static func networkMode(body: CreateRequest) -> String {
        if body.NetworkDisabled == true { return "none" }
        guard let raw = body.HostConfig?.NetworkMode, !raw.isEmpty else { return "private" }
        switch raw.lowercased() {
        case "default", "bridge": return "private"
        case "host": return "host"
        case "none": return "none"
        case let value where value.hasPrefix("container:"):
            return raw
        default: return raw
        }
    }

    private static func healthcheck(_ healthcheck: CreateHealthcheck) -> DockerRuntimeHealthcheck? {
        guard let test = healthcheck.Test else { return nil }
        return DockerRuntimeHealthcheck(
            test: test,
            interval: healthcheck.Interval ?? 0,
            timeout: healthcheck.Timeout ?? 0,
            retries: healthcheck.Retries ?? 0,
            startPeriod: healthcheck.StartPeriod ?? 0,
            startInterval: healthcheck.StartInterval ?? 0
        )
    }

    private static func restartPolicy(_ policy: CreateRestartPolicy?) -> DockerRuntimeRestartPolicy {
        guard let policy else { return .init() }
        return DockerRuntimeRestartPolicy(
            name: policy.Name ?? "no", maximumRetryCount: policy.MaximumRetryCount ?? 0
        )
    }

    private static func resources(_ host: CreateHostConfig?) -> DockerRuntimeResources {
        guard let host else { return .init() }
        return DockerRuntimeResources(
            memory: host.Memory ?? 0,
            memorySwap: host.MemorySwap ?? 0,
            memoryReservation: host.MemoryReservation ?? 0,
            nanoCPUs: host.NanoCpus ?? 0,
            cpuShares: host.CpuShares ?? 0,
            cpuPeriod: host.CpuPeriod ?? 0,
            cpuQuota: host.CpuQuota ?? 0,
            cpusetCpus: host.CpusetCpus ?? "",
            cpusetMems: host.CpusetMems ?? "",
            pidsLimit: host.PidsLimit ?? 0
        )
    }

    private static func validateCreateRequest(_ request: DockerRuntimeContainerCreate) throws {
        let resources = request.resources
        guard resources.memory >= 0, resources.memorySwap >= -1,
            resources.memoryReservation >= 0, resources.nanoCPUs >= 0,
            resources.cpuShares >= 0, resources.cpuPeriod >= 0,
            resources.cpuQuota >= -1, resources.pidsLimit >= -1
        else {
            throw Abort(.badRequest, reason: "Container resource limits must be valid non-negative values")
        }
        guard
            ["", "no", "always", "unless-stopped", "on-failure"].contains(
                request.restartPolicy.name.lowercased()
            )
        else {
            throw Abort(.badRequest, reason: "Invalid restart policy")
        }
        guard request.restartPolicy.maximumRetryCount >= 0 else {
            throw Abort(.badRequest, reason: "MaximumRetryCount must be non-negative")
        }
        if let healthcheck = request.healthcheck {
            guard !healthcheck.test.isEmpty else {
                throw Abort(.badRequest, reason: "Healthcheck test must not be empty")
            }
            guard healthcheck.interval >= 0, healthcheck.timeout >= 0,
                healthcheck.retries >= 0, healthcheck.startPeriod >= 0,
                healthcheck.startInterval >= 0
            else {
                throw Abort(.badRequest, reason: "Healthcheck values must be non-negative")
            }
        }
        for port in request.ports {
            guard port.containerPort > 0, ["tcp", "udp", "sctp"].contains(port.proto.lowercased()),
                port.hostPort.map({ (1...65_535).contains($0) }) ?? true
            else {
                throw Abort(.badRequest, reason: "Invalid published port")
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
    let SharedSize: Int64
    let VirtualSize: Int64
    let Labels: [String: String]
    let Containers: Int64
    let Manifests: [String]?

    init(
        _ image: DockerRuntimeImage,
        includeSharedSize: Bool = false,
        includeDigests: Bool = false,
        includeManifests: Bool = false,
        containerCount: Int64 = -1
    ) {
        Id = image.digest
        RepoTags = image.references.filter { !$0.contains("@sha256:") }
        RepoDigests = includeDigests ? image.references.filter { $0.contains("@sha256:") } : []
        Created = Int64(image.createdAt.timeIntervalSince1970)
        Size = image.size
        SharedSize = -1
        VirtualSize = image.size
        Labels = image.labels
        Containers = containerCount
        Manifests = includeManifests ? [] : nil
    }
}

private struct ImageInspectResponse: Encodable {
    struct EmptyObject: Encodable {}
    struct ConfigPayload: Encodable {
        let User: String
        let ExposedPorts: [String: EmptyObject]
        let Env: [String]
        let Cmd: [String]
        let Healthcheck: InspectHealthcheck?
        let ArgsEscaped: Bool
        let Volumes: [String: EmptyObject]
        let WorkingDir: String
        let Entrypoint: [String]?
        let OnBuild: [String]?
        let Labels: [String: String]
        let StopSignal: String?
        let Shell: [String]?
    }
    struct InspectHealthcheck: Encodable {
        let Test: [String]
        let Interval: Int64
        let Timeout: Int64
        let Retries: Int
        let StartPeriod: Int64
        let StartInterval: Int64
    }
    struct RootFSPayload: Encodable {
        let `Type` = "layers"
        let Layers: [String]
    }
    struct GraphDriverPayload: Encodable {
        let Name: String
        let Data: [String: String]
    }

    let Id: String
    let RepoTags: [String]
    let RepoDigests: [String]
    let Created: String
    let Parent: String
    let Comment: String
    let DockerVersion: String
    let Author: String
    let Architecture: String
    let Variant: String?
    let Os: String
    let OsVersion: String?
    let Size: Int64
    let VirtualSize: Int64
    let Config: ConfigPayload
    let GraphDriver: GraphDriverPayload
    let RootFS: RootFSPayload

    init(_ image: DockerRuntimeImage) {
        Id = image.digest
        RepoTags = image.references.filter { !$0.contains("@sha256:") }
        RepoDigests = image.references.filter { $0.contains("@sha256:") }
        Created = ISO8601DateFormatter().string(from: image.createdAt)
        Parent = ""
        Comment = ""
        DockerVersion = ""
        Author = image.author
        Architecture = image.architecture.isEmpty ? "arm64" : image.architecture
        Variant = image.variant.isEmpty ? nil : image.variant
        Os = image.os.isEmpty ? "linux" : image.os
        OsVersion = image.osVersion.isEmpty ? nil : image.osVersion
        Size = image.size
        VirtualSize = image.size
        Config = ConfigPayload(
            User: image.config.user,
            ExposedPorts: image.config.exposedPorts.reduce(into: [:]) { $0[$1] = EmptyObject() },
            Env: image.config.environment, Cmd: image.config.cmd,
            Healthcheck: image.config.healthcheck.map {
                InspectHealthcheck(
                    Test: $0.test, Interval: $0.interval, Timeout: $0.timeout,
                    Retries: $0.retries, StartPeriod: $0.startPeriod,
                    StartInterval: $0.startInterval
                )
            },
            ArgsEscaped: false,
            Volumes: image.config.volumes.reduce(into: [:]) { $0[$1] = EmptyObject() },
            WorkingDir: image.config.workingDirectory,
            Entrypoint: image.config.entrypoint.isEmpty ? nil : image.config.entrypoint,
            OnBuild: image.config.onBuild.isEmpty ? nil : image.config.onBuild,
            Labels: image.config.labels.isEmpty ? image.labels : image.config.labels,
            StopSignal: image.config.stopSignal.isEmpty ? nil : image.config.stopSignal,
            Shell: image.config.shell.isEmpty ? nil : image.config.shell
        )
        GraphDriver = GraphDriverPayload(Name: "overlayfs", Data: [:])
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
        let SizeRw: Int64
        let SizeRootFs: Int64
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
            SizeRw = container.sizeRw
            SizeRootFs = container.sizeRootFs
            Labels = container.labels
            State = container.state.rawValue
            Status = container.state.rawValue
        }
    }

    struct BuildCacheUsage: Encodable {
        let ID: String
        let Parents: [String]
        let `Type`: String
        let Description: String
        let InUse: Bool
        let Shared: Bool
        let Size: Int64
        let CreatedAt: String
        let LastUsedAt: String?
        let UsageCount: Int

        init(
            id: String,
            type: String,
            description: String,
            inUse: Bool,
            shared: Bool,
            size: Int64,
            createdAt: Date,
            lastUsedAt: Date?,
            usageCount: Int
        ) {
            ID = id
            Parents = []
            self.`Type` = type
            Description = description
            InUse = inUse
            Shared = shared
            Size = size
            CreatedAt = Self.dockerTimestamp(createdAt)
            LastUsedAt = lastUsedAt.map(Self.dockerTimestamp)
            UsageCount = usageCount
        }

        private static func dockerTimestamp(_ date: Date) -> String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.string(from: date)
        }
    }

    let LayersSize: Int64
    let Images: [ImageUsage]
    let Containers: [ContainerUsage]
    let Volumes: [Volume]
    let BuildCache: [BuildCacheUsage]

    init(
        images: [DockerRuntimeImage],
        containers: [DockerRuntimeContainer],
        volumes: [Volume] = [],
        layersSizeOverride: Int64? = nil,
        buildCache: [BuildCacheUsage] = []
    ) {
        LayersSize =
            layersSizeOverride
            ?? images.reduce(into: Int64(0)) { total, image in
                total += max(image.size, 0)
            }
        Images = images.map { image in
            let count = containers.filter {
                DockerRuntimeRoutes.imageMatchesContainer($0, image: image)
            }.count
            return ImageUsage(image, containerCount: Int64(count))
        }
        Containers = containers.map(ContainerUsage.init)
        Volumes = volumes
        BuildCache = buildCache
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
    let Aliases: [String]?
    let Links: [String]?
}

private struct DockerNetworkingConfig: Content {
    let EndpointsConfig: [String: DockerNetworkEndpointConfig]?
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
    let StopTimeout: Int?
    let AttachStdin: Bool?
    let OpenStdin: Bool?
    let StdinOnce: Bool?
    let NetworkDisabled: Bool?
    let NetworkingConfig: DockerNetworkingConfig?
    let StopSignal: String?
    let Healthcheck: CreateHealthcheck?
    let HostConfig: CreateHostConfig?
}

private struct SystemDataUsageQuery: Content {
    let type: [String]?
}

private struct CreateHostConfig: Content {
    let AutoRemove: Bool?
    let Binds: [String]?
    let Mounts: [CreateMount]?
    let PortBindings: [String: [CreatePortBinding]]?
    let NetworkMode: String?
    let ReadonlyRootfs: Bool?
    let Memory: Int64?
    let MemorySwap: Int64?
    let MemoryReservation: Int64?
    let NanoCpus: Int64?
    let CpuShares: Int64?
    let CpuPeriod: Int64?
    let CpuQuota: Int64?
    let CpusetCpus: String?
    let CpusetMems: String?
    let PidsLimit: Int64?
    let RestartPolicy: CreateRestartPolicy?
    let Dns: [String]?
    let DnsSearch: [String]?
    let ExtraHosts: [String]?
    let Tmpfs: [String: String]?
    let PublishAllPorts: Bool?
    let Privileged: Bool?
    let Init: Bool?
    let SecurityOpt: [String]?
}

private struct CreateMount: Content {
    let `Type`: String
    let Source: String?
    let Target: String
    let ReadOnly: Bool?
    let VolumeOptions: CreateVolumeOptions?
    let TmpfsOptions: CreateTmpfsOptions?
}

private struct CreateVolumeOptions: Content {
    let NoCopy: Bool?
}

private struct CreateTmpfsOptions: Content {
    let SizeBytes: Int64?
    let Mode: Int64?
}

private struct CreateHealthcheck: Content {
    let Test: [String]?
    let Interval: Int64?
    let Timeout: Int64?
    let Retries: Int?
    let StartPeriod: Int64?
    let StartInterval: Int64?
}

private struct CreateRestartPolicy: Content {
    let Name: String?
    let MaximumRetryCount: Int?
}

private struct CreatePortBinding: Content {
    let HostIp: String?
    let HostPort: String?
}

private struct ExecCreateRequest: Content {
    let Cmd: [String]?
    let AttachStdin: Bool?
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
    struct EmptyObject: Content {}
    struct HealthLogPayload: Content {
        let Start: String
        let End: String
        let ExitCode: Int32
        let Output: String
    }

    struct HealthPayload: Content {
        let Status: String
        let FailingStreak: Int
        let Log: [HealthLogPayload]

        init(_ health: DockerRuntimeHealth) {
            Status = health.status
            FailingStreak = health.failingStreak
            Log = health.log.map {
                HealthLogPayload(
                    Start: ISO8601DateFormatter().string(from: $0.start),
                    End: ISO8601DateFormatter().string(from: $0.end),
                    ExitCode: $0.exitCode,
                    Output: $0.output
                )
            }
        }
    }

    struct HealthcheckPayload: Content {
        let Test: [String]
        let Interval: Int64
        let Timeout: Int64
        let Retries: Int
        let StartPeriod: Int64
        let StartInterval: Int64

        init(_ healthcheck: DockerRuntimeHealthcheck) {
            Test = healthcheck.test
            Interval = healthcheck.interval
            Timeout = healthcheck.timeout
            Retries = healthcheck.retries
            StartPeriod = healthcheck.startPeriod
            StartInterval = healthcheck.startInterval
        }
    }

    struct RestartPolicyPayload: Content {
        let Name: String
        let MaximumRetryCount: Int

        init(_ policy: DockerRuntimeRestartPolicy) {
            Name = policy.name
            MaximumRetryCount = policy.maximumRetryCount
        }
    }

    struct StatePayload: Content {
        let Status: String
        let Running: Bool
        let Paused: Bool
        let Restarting: Bool
        let OOMKilled: Bool
        let Dead: Bool
        let Pid: Int
        let ExitCode: Int32
        let Error: String
        let StartedAt: String
        let FinishedAt: String
        let Health: HealthPayload?

        enum CodingKeys: String, CodingKey {
            case Status, Running, Paused, Restarting, OOMKilled, Dead, Pid, ExitCode, Error
            case StartedAt, FinishedAt, Health
        }

        init(container: DockerRuntimeContainer, timestamp: String) {
            Status = container.state.rawValue
            Running = container.state == .running || container.state == .paused
            Paused = container.state == .paused
            Restarting = container.state == .restarting
            OOMKilled = false
            Dead = false
            Pid = 0
            ExitCode = container.exitCode ?? 0
            Error = ""
            StartedAt = container.state == .created ? "0001-01-01T00:00:00Z" : timestamp
            FinishedAt = container.state == .exited ? timestamp : "0001-01-01T00:00:00Z"
            Health = container.health.status == "none" ? nil : HealthPayload(container.health)
        }
    }

    struct ConfigPayload: Content {
        let Image: String
        let Cmd: [String]
        let Entrypoint: [String]?
        let Env: [String]
        let ExposedPorts: [String: EmptyObject]
        let Volumes: [String: EmptyObject]
        let WorkingDir: String
        let User: String
        let Hostname: String
        let AttachStdin: Bool
        let AttachStdout: Bool
        let AttachStderr: Bool
        let OpenStdin: Bool
        let StdinOnce: Bool
        let Tty: Bool
        let Labels: [String: String]
        let StopSignal: String?
        let Healthcheck: HealthcheckPayload?
    }

    struct NetworkEndpointPayload: Content {
        let NetworkID: String
        let EndpointID: String
        let IPAddress: String
        let IPPrefixLen: Int
        let MacAddress: String
        let Gateway: String
        let GlobalIPv6Address: String
        let GlobalIPv6PrefixLen: Int
        let IPv6Gateway: String
        let Links: [String]?
        let Aliases: [String]?
    }

    struct NetworkSettingsPayload: Content {
        let Bridge: String
        let SandboxID: String
        let HairpinMode: Bool
        let LinkLocalIPv6Address: String
        let LinkLocalIPv6PrefixLen: Int
        let Ports: [String: [CreatePortBinding]]
        let SandboxKey: String
        let SecondaryIPAddresses: [String]
        let SecondaryIPv6Addresses: [String]
        let EndpointID: String
        let Gateway: String
        let GlobalIPv6Address: String
        let GlobalIPv6PrefixLen: Int
        let IPAddress: String
        let IPPrefixLen: Int
        let IPv6Gateway: String
        let MacAddress: String
        let Networks: [String: NetworkEndpointPayload]
    }

    struct HostConfigPayload: Content {
        let Binds: [String]
        let PortBindings: [String: [CreatePortBinding]]
        let NetworkMode: String
        let StopTimeout: Int?
        let RestartPolicy: RestartPolicyPayload
        let AutoRemove: Bool
        let ReadonlyRootfs: Bool
        let Privileged: Bool
        let Init: Bool?
        let Dns: [String]
        let DnsSearch: [String]
        let ExtraHosts: [String]
        let Memory: Int64
        let MemorySwap: Int64
        let MemoryReservation: Int64
        let NanoCpus: Int64
        let CpuShares: Int64
        let CpuPeriod: Int64
        let CpuQuota: Int64
        let CpusetCpus: String
        let CpusetMems: String
        let PidsLimit: Int64
    }

    struct GraphDriverPayload: Content {
        let Name: String
        let Data: [String: String]
    }

    struct MountPayload: Content {
        let `Type`: String
        let Name: String?
        let Source: String
        let Destination: String
        let Driver: String
        let Mode: String
        let RW: Bool
        let Propagation: String

        init(_ mount: DockerRuntimeMount) {
            let isVolume = mount.volumeName != nil
            `Type` = isVolume ? "volume" : mount.type
            Name = mount.volumeName
            Source = mount.source
            Destination = mount.target
            Driver = isVolume ? "local" : ""
            Mode = mount.readOnly ? "ro" : "rw"
            RW = !mount.readOnly
            Propagation = ""
        }
    }

    let Id: String
    let Name: String
    let Image: String
    let Created: String
    let Path: String
    let Args: [String]
    let ResolvConfPath: String
    let HostnamePath: String
    let HostsPath: String
    let LogPath: String?
    let RestartCount: Int
    let Driver: String
    let Platform: String
    let MountLabel: String
    let ProcessLabel: String
    let AppArmorProfile: String
    let ExecIDs: [String]?
    let State: StatePayload
    let Config: ConfigPayload
    let HostConfig: HostConfigPayload
    let NetworkSettings: NetworkSettingsPayload
    let GraphDriver: GraphDriverPayload
    let SizeRw: Int64?
    let SizeRootFs: Int64?
    let Mounts: [MountPayload]

    init(
        _ container: DockerRuntimeContainer,
        networks: [DockerRuntimeNetwork] = [],
        includeSize: Bool = false
    ) {
        Id = container.id
        Name = container.name.hasPrefix("/") ? container.name : "/\(container.name)"
        Image = container.image
        Created = ISO8601DateFormatter().string(from: container.createdAt)
        Path = container.command.first ?? ""
        Args = Array(container.command.dropFirst())
        ResolvConfPath = ""
        HostnamePath = ""
        HostsPath = ""
        LogPath = nil
        RestartCount = container.restartCount
        Driver = "overlayfs"
        Platform = "linux"
        MountLabel = ""
        ProcessLabel = ""
        AppArmorProfile = ""
        ExecIDs = nil
        State = .init(container: container, timestamp: Created)
        Config = .init(
            Image: container.image, Cmd: container.cmd ?? container.command,
            Entrypoint: container.entrypoint, Env: container.environment,
            ExposedPorts: Dictionary(
                uniqueKeysWithValues: container.ports.map {
                    ("\($0.containerPort)/\($0.proto)", EmptyObject())
                }),
            Volumes: Dictionary(
                uniqueKeysWithValues: container.mounts.filter {
                    $0.volumeName != nil || $0.type == "volume"
                }.map {
                    ($0.target, EmptyObject())
                }),
            WorkingDir: container.workingDirectory, User: container.user,
            Hostname: container.hostname, AttachStdin: container.attachStdin,
            AttachStdout: true, AttachStderr: true, OpenStdin: container.openStdin,
            StdinOnce: container.stdinOnce,
            Tty: container.tty, Labels: container.labels,
            StopSignal: container.stopSignal.isEmpty ? nil : container.stopSignal,
            Healthcheck: container.healthcheck.map(HealthcheckPayload.init)
        )
        var ports: [String: [CreatePortBinding]] = [:]
        for binding in container.ports {
            ports["\(binding.containerPort)/\(binding.proto)", default: []].append(
                .init(HostIp: binding.hostIP, HostPort: binding.hostPort.map(String.init))
            )
        }
        HostConfig = .init(
            Binds: container.mounts.filter { $0.type == "bind" }.map {
                let mode = $0.readOnly ? "ro" : "rw"
                let noCopy = $0.noCopy ? ",nocopy" : ""
                return "\($0.volumeName ?? $0.source):\($0.target):\(mode)\(noCopy)"
            }, PortBindings: ports, NetworkMode: container.networkMode,
            StopTimeout: container.stopTimeout,
            RestartPolicy: .init(container.restartPolicy), AutoRemove: container.autoRemove,
            ReadonlyRootfs: container.readonlyRootfs, Privileged: container.privileged, Init: nil,
            Dns: container.dns, DnsSearch: container.dnsSearch, ExtraHosts: container.extraHosts,
            Memory: container.resources.memory, MemorySwap: container.resources.memorySwap,
            MemoryReservation: container.resources.memoryReservation,
            NanoCpus: container.resources.nanoCPUs, CpuShares: container.resources.cpuShares,
            CpuPeriod: container.resources.cpuPeriod, CpuQuota: container.resources.cpuQuota,
            CpusetCpus: container.resources.cpusetCpus, CpusetMems: container.resources.cpusetMems,
            PidsLimit: container.resources.pidsLimit
        )
        let endpoints = networks.compactMap { network -> (String, NetworkEndpointPayload)? in
            guard let endpoint = network.containers[container.id] else { return nil }
            let ipv4Config = Self.ipv4IPAMConfig(network)
            let ipv6Config = Self.ipv6IPAMConfig(network)
            let (ipv4, ipv4Prefix) = Self.addressAndPrefix(
                endpoint.ipv4Address, fallback: ipv4Config?.Subnet
            )
            let (ipv6, ipv6Prefix) = Self.addressAndPrefix(
                endpoint.ipv6Address, fallback: ipv6Config?.Subnet
            )
            return (
                network.name,
                NetworkEndpointPayload(
                    NetworkID: network.id, EndpointID: endpoint.endpointID ?? "",
                    IPAddress: ipv4, IPPrefixLen: ipv4Prefix,
                    MacAddress: endpoint.macAddress ?? "", Gateway: ipv4Config?.Gateway ?? "",
                    GlobalIPv6Address: ipv6, GlobalIPv6PrefixLen: ipv6Prefix,
                    IPv6Gateway: ipv6Config?.Gateway ?? "", Links: nil, Aliases: endpoint.aliases
                )
            )
        }
        let endpointMap = Dictionary(uniqueKeysWithValues: endpoints)
        let primary = endpoints.first?.1
        NetworkSettings = .init(
            Bridge: endpoints.first?.0 ?? "", SandboxID: "", HairpinMode: false,
            LinkLocalIPv6Address: "", LinkLocalIPv6PrefixLen: 0, Ports: ports,
            SandboxKey: "", SecondaryIPAddresses: [], SecondaryIPv6Addresses: [],
            EndpointID: primary?.EndpointID ?? "", Gateway: primary?.Gateway ?? "",
            GlobalIPv6Address: primary?.GlobalIPv6Address ?? "",
            GlobalIPv6PrefixLen: primary?.GlobalIPv6PrefixLen ?? 0,
            IPAddress: primary?.IPAddress ?? "", IPPrefixLen: primary?.IPPrefixLen ?? 0,
            IPv6Gateway: primary?.IPv6Gateway ?? "", MacAddress: primary?.MacAddress ?? "",
            Networks: endpointMap
        )
        GraphDriver = .init(Name: "overlayfs", Data: [:])
        SizeRw = includeSize && container.sizeRw >= 0 ? container.sizeRw : nil
        SizeRootFs = includeSize && container.sizeRootFs >= 0 ? container.sizeRootFs : nil
        Mounts = container.mounts.map(MountPayload.init)
    }

    private static func addressAndPrefix(_ value: String?, fallback: String?) -> (String, Int) {
        guard let value, !value.isEmpty else { return ("", 0) }
        if let slash = value.lastIndex(of: "/"), let prefix = Int(value[value.index(after: slash)...]) {
            return (String(value[..<slash]), prefix)
        }
        if let fallback, let slash = fallback.lastIndex(of: "/"),
            let prefix = Int(fallback[fallback.index(after: slash)...])
        {
            return (value, prefix)
        }
        return (value, 0)
    }

    private static func ipv4IPAMConfig(_ network: DockerRuntimeNetwork) -> NetworkIPAMConfig? {
        network.ipam.Config.first { config in
            guard let subnet = config.Subnet, let slash = subnet.firstIndex(of: "/") else {
                return false
            }
            return !String(subnet[..<slash]).contains(":")
        }
    }

    private static func ipv6IPAMConfig(_ network: DockerRuntimeNetwork) -> NetworkIPAMConfig? {
        network.ipam.Config.first { config in
            guard let subnet = config.Subnet, let slash = subnet.firstIndex(of: "/") else {
                return false
            }
            return String(subnet[..<slash]).contains(":")
        }
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
    let SizeRw: Int64?
    let SizeRootFs: Int64?

    init(_ container: DockerRuntimeContainer, includeSize: Bool = false) {
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
        SizeRw = includeSize && container.sizeRw >= 0 ? container.sizeRw : (includeSize ? 0 : nil)
        SizeRootFs = includeSize && container.sizeRootFs >= 0 ? container.sizeRootFs : (includeSize ? 0 : nil)
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

final class SawDataFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var sawAny = false

    func mark() {
        lock.withLock { sawAny = true }
    }

    var didSeeData: Bool {
        lock.withLock { sawAny }
    }
}

/// Ensures a body-drain continuation resumes exactly once.
private final class DrainCompletionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let continuation: CheckedContinuation<Void, any Error>

    init(continuation: CheckedContinuation<Void, any Error>) {
        self.continuation = continuation
    }

    func resumeOnce() {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        continuation.resume()
    }

    func resumeOnce(with error: Error) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        continuation.resume(throwing: error)
    }
}
