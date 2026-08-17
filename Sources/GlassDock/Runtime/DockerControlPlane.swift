import Foundation
import NIOCore
import Vapor

protocol DockerControlPlaneRuntime: Sendable {
    func supportsLogOptions() async -> Bool
    func createContainer(_ request: DockerRuntimeContainerCreate) async throws -> DockerRuntimeContainer
    func startContainer(id: String) async throws
    func deleteContainer(id: String, force: Bool, removeVolumes: Bool) async throws
    func inspectContainer(id: String) async throws -> DockerRuntimeContainer
    func logs(id: String, stdout: Bool, stderr: Bool) async throws -> DockerRuntimeProcessOutput
    func logs(
        id: String,
        stdout: Bool,
        stderr: Bool,
        options: DockerRuntimeLogOptions
    ) async throws -> DockerRuntimeProcessOutput
    func streamLogs(
        id: String,
        stdout: Bool,
        stderr: Bool,
        options: DockerRuntimeLogOptions
    ) async throws -> AsyncThrowingStream<DockerRuntimeProcessFrame, Error>
}

extension GuestRuntime: DockerControlPlaneRuntime {}

extension DockerControlPlaneRuntime {
    func supportsLogOptions() async -> Bool { false }

    func logs(
        id: String,
        stdout: Bool,
        stderr: Bool,
        options: DockerRuntimeLogOptions
    ) async throws -> DockerRuntimeProcessOutput {
        try await logs(id: id, stdout: stdout, stderr: stderr)
    }

    func streamLogs(
        id: String,
        stdout: Bool,
        stderr: Bool,
        options: DockerRuntimeLogOptions
    ) async throws -> AsyncThrowingStream<DockerRuntimeProcessFrame, Error> {
        let output = try await logs(id: id, stdout: stdout, stderr: stderr, options: options)
        return AsyncThrowingStream { continuation in
            if stdout, !output.stdout.isEmpty {
                continuation.yield(.init(stream: .stdout, data: output.stdout, exitCode: nil))
            }
            if stderr, !output.stderr.isEmpty {
                continuation.yield(.init(stream: .stderr, data: output.stderr, exitCode: nil))
            }
            continuation.finish()
        }
    }
}

extension GuestRuntime {
    func supportsLogOptions() async -> Bool { true }

    func streamLogs(
        id: String,
        stdout: Bool,
        stderr: Bool,
        options: DockerRuntimeLogOptions
    ) async throws -> AsyncThrowingStream<DockerRuntimeProcessFrame, Error> {
        try await attachContainer(
            id: id, stdout: stdout, stderr: stderr, options: options
        )
    }
}

/// Stores the Docker control-plane objects that do not belong to a running
/// container. The persistent guest runtime has no Swarm manager, so this
/// state models the single-node control plane without pretending to schedule
/// workloads or attach a second node.
actor DockerControlPlane {
    struct Object: Sendable, Equatable {
        let id: String
        let version: UInt64
        let createdAt: Date
        let updatedAt: Date
        let spec: Spec
    }

    struct Spec: Sendable, Equatable, Codable {
        var name: String
        var labels: [String: String]
        var data: String?

        init(name: String, labels: [String: String] = [:], data: String? = nil) {
            self.name = name
            self.labels = labels
            self.data = data
        }
    }

    struct Swarm: Sendable, Equatable, Codable {
        let id: String
        let version: UInt64
        let createdAt: Date
        let updatedAt: Date
        let spec: SwarmSpec
        let workerToken: String
        let managerToken: String
        let unlockKey: String
        let nodeID: String
    }

    struct SwarmSpec: Sendable, Equatable, Codable {
        var name: String
        var labels: [String: String]
        var orchestration: [String: JSONValue]
        var raft: [String: JSONValue]
        var dispatcher: [String: JSONValue]
        var certificates: [String: JSONValue]
        var encryption: [String: JSONValue]

        init(name: String = "", labels: [String: String] = [:]) {
            self.name = name
            self.labels = labels
            self.orchestration = [:]
            self.raft = [:]
            self.dispatcher = [:]
            self.certificates = [:]
            self.encryption = [:]
        }

        private enum CodingKeys: String, CodingKey {
            case name = "Name"
            case labels = "Labels"
            case orchestration = "Orchestration"
            case raft = "Raft"
            case dispatcher = "Dispatcher"
            case certificates = "CAConfig"
            case encryption = "EncryptionConfig"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
            labels = try container.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
            orchestration =
                try container.decodeIfPresent(
                    [String: JSONValue].self, forKey: .orchestration
                ) ?? [:]
            raft = try container.decodeIfPresent([String: JSONValue].self, forKey: .raft) ?? [:]
            dispatcher =
                try container.decodeIfPresent(
                    [String: JSONValue].self, forKey: .dispatcher
                ) ?? [:]
            certificates =
                try container.decodeIfPresent(
                    [String: JSONValue].self, forKey: .certificates
                ) ?? [:]
            encryption =
                try container.decodeIfPresent(
                    [String: JSONValue].self, forKey: .encryption
                ) ?? [:]
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(labels, forKey: .labels)
            try container.encode(orchestration, forKey: .orchestration)
            try container.encode(raft, forKey: .raft)
            try container.encode(dispatcher, forKey: .dispatcher)
            try container.encode(certificates, forKey: .certificates)
            try container.encode(encryption, forKey: .encryption)
        }
    }

    struct Node: Sendable, Equatable, Codable {
        let id: String
        let version: UInt64
        let createdAt: Date
        let updatedAt: Date
        let spec: [String: JSONValue]
    }

    struct Service: Sendable, Equatable, Codable {
        let id: String
        let version: UInt64
        let createdAt: Date
        let updatedAt: Date
        let spec: [String: JSONValue]
        let taskIDs: [String]

        var taskID: String { taskIDs.first ?? "" }
    }

    struct Task: Sendable, Equatable, Codable {
        let id: String
        let version: UInt64
        let createdAt: Date
        let updatedAt: Date
        let serviceID: String
        let spec: [String: JSONValue]
        let state: String
        let containerID: String?
        let exitCode: Int32?
        let slot: Int?
        let nodeID: String?
    }

    struct Plugin: Sendable, Equatable, Codable {
        let id: String
        var name: String
        var reference: String
        var enabled: Bool
        var version: UInt64
        var createdAt: Date
        var updatedAt: Date
        var config: [String: JSONValue]
        var settings: [String: JSONValue]
    }

    enum JSONValue: Sendable, Equatable, Codable {
        case string(String)
        case number(Double)
        case bool(Bool)
        case object([String: JSONValue])
        case array([JSONValue])
        case null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else if let value = try? container.decode(Double.self) {
                self = .number(value)
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode([String: JSONValue].self) {
                self = .object(value)
            } else {
                self = .array(try container.decode([JSONValue].self))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value): try container.encode(value)
            case .number(let value): try container.encode(value)
            case .bool(let value): try container.encode(value)
            case .object(let value): try container.encode(value)
            case .array(let value): try container.encode(value)
            case .null: try container.encodeNil()
            }
        }
    }

    private struct StoredObject: Sendable, Codable {
        let id: String
        var version: UInt64
        let createdAt: Date
        var updatedAt: Date
        var spec: Spec
    }

    private var configs: [String: StoredObject] = [:]
    private var secrets: [String: StoredObject] = [:]
    private var swarm: Swarm?
    private var nodeVersion: UInt64 = 1
    private var nodeSpec: [String: JSONValue] = [
        "Name": .string("glassdock"),
        "Role": .string("manager"),
        "Availability": .string("active"),
        "Labels": .object([:]),
    ]
    private var services: [String: Service] = [:]
    private var tasks: [String: Task] = [:]
    private var plugins: [String: Plugin] = [:]
    private let stateURL: URL?

    private struct PersistedState: Codable {
        var configs: [String: StoredObject]
        var secrets: [String: StoredObject]
        var swarm: Swarm?
        var nodeVersion: UInt64
        var nodeSpec: [String: JSONValue]
        var services: [String: Service]
        var tasks: [String: Task]
        var plugins: [String: Plugin]
    }

    init(stateURL: URL? = nil) {
        self.stateURL = stateURL
        guard let stateURL,
            let data = try? Data(contentsOf: stateURL),
            let state = try? Self.stateDecoder.decode(PersistedState.self, from: data)
        else { return }
        configs = state.configs
        secrets = state.secrets
        swarm = state.swarm
        nodeVersion = state.nodeVersion
        nodeSpec = state.nodeSpec
        services = state.services
        tasks = state.tasks
        plugins = state.plugins
    }

    private static let stateEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let stateDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    func createConfig(spec: Spec) -> Object {
        let object = create(spec: spec, in: &configs)
        persist()
        return object
    }

    func listConfigs(filters: [String: [String]]?) -> [Object] {
        list(in: configs, filters: filters)
    }

    func configExists(name: String) -> Bool {
        configs.values.contains { $0.spec.name == name }
    }

    func inspectConfig(id: String) -> Object? {
        object(in: configs, id: id)
    }

    func updateConfig(id: String, spec: Spec) -> Object? {
        let object = update(id: id, spec: spec, in: &configs)
        if object != nil { persist() }
        return object
    }

    func configVersion(id: String) -> UInt64? { object(in: configs, id: id)?.version }

    func deleteConfig(id: String) -> Bool {
        let deleted = configs.removeValue(forKey: resolve(id, in: configs)) != nil
        if deleted { persist() }
        return deleted
    }

    func createSecret(spec: Spec) -> Object {
        let object = create(spec: spec, in: &secrets)
        persist()
        return object
    }

    func listSecrets(filters: [String: [String]]?) -> [Object] {
        list(in: secrets, filters: filters).map { object in
            Object(
                id: object.id,
                version: object.version,
                createdAt: object.createdAt,
                updatedAt: object.updatedAt,
                spec: Spec(name: object.spec.name, labels: object.spec.labels)
            )
        }
    }

    func secretExists(name: String) -> Bool {
        secrets.values.contains { $0.spec.name == name }
    }

    func inspectSecret(id: String) -> Object? {
        guard let object = object(in: secrets, id: id) else { return nil }
        return Object(
            id: object.id,
            version: object.version,
            createdAt: object.createdAt,
            updatedAt: object.updatedAt,
            spec: Spec(name: object.spec.name, labels: object.spec.labels)
        )
    }

    func updateSecret(id: String, spec: Spec) -> Object? {
        guard let object = update(id: id, spec: spec, in: &secrets) else { return nil }
        persist()
        return Object(
            id: object.id,
            version: object.version,
            createdAt: object.createdAt,
            updatedAt: object.updatedAt,
            spec: Spec(name: object.spec.name, labels: object.spec.labels)
        )
    }

    func secretVersion(id: String) -> UInt64? { object(in: secrets, id: id)?.version }

    func deleteSecret(id: String) -> Bool {
        let deleted = secrets.removeValue(forKey: resolve(id, in: secrets)) != nil
        if deleted { persist() }
        return deleted
    }

    func initializeSwarm(spec: SwarmSpec) -> Swarm {
        if let swarm { return swarm }
        nodeVersion = 1
        nodeSpec = [
            "Name": .string("glassdock"),
            "Role": .string("manager"),
            "Availability": .string("active"),
            "Labels": .object([:]),
        ]
        let now = Date()
        let initialized = Swarm(
            id: Self.identifier(),
            version: 1,
            createdAt: now,
            updatedAt: now,
            spec: spec,
            workerToken: "SWMTKN-1-\(Self.identifier())-worker",
            managerToken: "SWMTKN-1-\(Self.identifier())-manager",
            unlockKey: "unlock-\(Self.identifier())",
            nodeID: Self.identifier()
        )
        swarm = initialized
        persist()
        return initialized
    }

    func currentSwarm() -> Swarm? { swarm }

    func joinSwarm(spec: SwarmSpec, token: String, remoteAddresses: [String]) -> Swarm? {
        guard Self.validJoinToken(token), !remoteAddresses.isEmpty,
            remoteAddresses.allSatisfy(Self.validRemoteAddress)
        else { return nil }
        if let swarm {
            guard token == swarm.workerToken || token == swarm.managerToken else { return nil }
            return swarm
        }
        return initializeSwarm(spec: spec)
    }

    func updateSwarm(spec: SwarmSpec) -> Swarm? {
        guard let current = swarm else { return nil }
        let updated = Swarm(
            id: current.id,
            version: current.version + 1,
            createdAt: current.createdAt,
            updatedAt: Date(),
            spec: spec,
            workerToken: current.workerToken,
            managerToken: current.managerToken,
            unlockKey: current.unlockKey,
            nodeID: current.nodeID
        )
        swarm = updated
        persist()
        return updated
    }

    func leaveSwarm() {
        swarm = nil
        nodeVersion = 1
        nodeSpec = [:]
        services.removeAll()
        tasks.removeAll()
        persist()
    }

    func unlockSwarm(key: String) -> Bool {
        guard let swarm else { return false }
        return key == swarm.unlockKey
    }

    func listNodes(filters: [String: [String]]?) -> [Node] {
        guard let node = node() else { return [] }
        guard matchesNode(node, filters: filters) else { return [] }
        return [node]
    }

    func inspectNode(id: String) -> Node? {
        guard let node = node(), node.id == id || node.id.hasPrefix(id) else { return nil }
        return node
    }

    func updateNode(id: String, spec: [String: JSONValue]) -> Node? {
        guard let node = inspectNode(id: id) else { return nil }
        let updated = Node(
            id: node.id,
            version: node.version + 1,
            createdAt: node.createdAt,
            updatedAt: Date(),
            spec: spec
        )
        nodeVersion = updated.version
        nodeSpec = updated.spec
        persist()
        return updated
    }

    func nodeVersion(id: String) -> UInt64? { inspectNode(id: id)?.version }

    func removeNode(id: String) -> Bool {
        guard inspectNode(id: id) != nil else { return false }
        leaveSwarm()
        return true
    }

    func createService(spec: [String: JSONValue]) -> Service? {
        guard swarm != nil else { return nil }
        guard
            !services.values.contains(where: { service in
                guard case .string(let name) = service.spec["Name"],
                    case .string(let requested) = spec["Name"]
                else { return false }
                return name == requested
            })
        else { return nil }
        let now = Date()
        let serviceID = Self.identifier()
        let taskIDs = (0..<Self.replicaCount(spec: spec)).map { _ in Self.identifier() }
        let service = Service(
            id: serviceID,
            version: 1,
            createdAt: now,
            updatedAt: now,
            spec: spec,
            taskIDs: taskIDs
        )
        let taskSpec: [String: JSONValue] = {
            guard case .object(let value) = spec["TaskTemplate"] else { return [:] }
            return value
        }()
        for taskID in taskIDs {
            let task = Task(
                id: taskID,
                version: 1,
                createdAt: now,
                updatedAt: now,
                serviceID: serviceID,
                spec: taskSpec,
                state: "new",
                containerID: nil,
                exitCode: nil,
                slot: taskIDs.firstIndex(of: taskID).map { $0 + 1 },
                nodeID: swarm?.nodeID
            )
            tasks[taskID] = task
        }
        services[serviceID] = service
        persist()
        return service
    }

    func listServices(filters: [String: [String]]?) -> [Service] {
        services.values
            .filter { matchesService($0, filters: filters) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func inspectService(id: String) -> Service? {
        services[resolveServiceID(id)]
    }

    func updateService(id: String, spec: [String: JSONValue]) -> Service? {
        let resolved = resolveServiceID(id)
        guard let current = services[resolved] else { return nil }
        for taskID in current.taskIDs {
            tasks.removeValue(forKey: taskID)
        }
        let taskIDs = (0..<Self.replicaCount(spec: spec)).map { _ in Self.identifier() }
        let taskSpec: [String: JSONValue] = {
            guard case .object(let value) = spec["TaskTemplate"] else { return [:] }
            return value
        }()
        let now = Date()
        for taskID in taskIDs {
            tasks[taskID] = Task(
                id: taskID,
                version: 1,
                createdAt: now,
                updatedAt: now,
                serviceID: current.id,
                spec: taskSpec,
                state: "new",
                containerID: nil,
                exitCode: nil,
                slot: taskIDs.firstIndex(of: taskID).map { $0 + 1 },
                nodeID: swarm?.nodeID
            )
        }
        let updated = Service(
            id: current.id,
            version: current.version + 1,
            createdAt: current.createdAt,
            updatedAt: now,
            spec: spec,
            taskIDs: taskIDs
        )
        services[resolved] = updated
        persist()
        return updated
    }

    func serviceVersion(id: String) -> UInt64? { inspectService(id: id)?.version }

    func removeService(id: String) -> Bool {
        let resolved = resolveServiceID(id)
        guard let service = services.removeValue(forKey: resolved) else { return false }
        for taskID in service.taskIDs {
            tasks.removeValue(forKey: taskID)
        }
        persist()
        return true
    }

    func listTasks(filters: [String: [String]]?) -> [Task] {
        tasks.values
            .filter { matchesTask($0, filters: filters) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func inspectTask(id: String) -> Task? {
        tasks[resolveTaskID(id)]
    }

    func attachTaskContainer(taskID: String, containerID: String) -> Bool {
        let resolved = resolveTaskID(taskID)
        guard let task = tasks[resolved] else { return false }
        tasks[resolved] = Task(
            id: task.id,
            version: task.version,
            createdAt: task.createdAt,
            updatedAt: Date(),
            serviceID: task.serviceID,
            spec: task.spec,
            state: "running",
            containerID: containerID,
            exitCode: nil,
            slot: task.slot,
            nodeID: task.nodeID
        )
        persist()
        return true
    }

    func taskContainerID(id: String) -> String? {
        tasks[resolveTaskID(id)]?.containerID
    }

    func updateTaskRuntime(
        id: String, container: DockerRuntimeContainer
    ) -> Task? {
        let resolved = resolveTaskID(id)
        guard let task = tasks[resolved] else { return nil }
        let state: String
        switch container.state {
        case .created: state = "new"
        case .running, .paused: state = "running"
        case .restarting: state = "starting"
        case .exited: state = container.exitCode == 0 ? "complete" : "failed"
        }
        let exitCode = container.exitCode
        guard task.state != state || task.containerID != container.id || task.exitCode != exitCode
        else { return task }
        let updated = Task(
            id: task.id,
            version: task.version + 1,
            createdAt: task.createdAt,
            updatedAt: Date(),
            serviceID: task.serviceID,
            spec: task.spec,
            state: state,
            containerID: container.id,
            exitCode: exitCode,
            slot: task.slot,
            nodeID: task.nodeID
        )
        tasks[resolved] = updated
        persist()
        return updated
    }

    func taskContainerIDs(for service: Service) -> [String] {
        service.taskIDs.compactMap { tasks[$0]?.containerID }
    }

    func serviceTaskStatus(for service: Service) -> (running: UInt64, desired: UInt64, completed: UInt64) {
        let serviceTasks = service.taskIDs.compactMap { tasks[$0] }
        return (
            running: UInt64(serviceTasks.filter { $0.state == "running" }.count),
            desired: UInt64(serviceTasks.count),
            completed: UInt64(serviceTasks.filter { $0.state == "complete" }.count)
        )
    }

    func allTaskContainerIDs() -> [String] {
        tasks.values.compactMap(\.containerID)
    }

    func replicaCount(for spec: [String: JSONValue]) -> Int {
        Self.replicaCount(spec: spec)
    }

    func listPlugins(filters: [String: [String]]? = nil) -> [Plugin] {
        plugins.values
            .filter { matchesPlugin($0, filters: filters) }
            .sorted { $0.name < $1.name }
    }

    func inspectPlugin(name: String) -> Plugin? {
        plugins[resolvePluginName(name)]
    }

    func createPlugin(
        name: String,
        reference: String? = nil,
        config: [String: JSONValue] = [:]
    ) -> Plugin {
        if let existing = inspectPlugin(name: name) { return existing }
        let now = Date()
        let plugin = Plugin(
            id: Self.identifier(),
            name: name,
            reference: reference ?? name,
            enabled: false,
            version: 1,
            createdAt: now,
            updatedAt: now,
            config: config,
            settings: [:]
        )
        plugins[plugin.name] = plugin
        persist()
        return plugin
    }

    func pluginExists(name: String) -> Bool {
        inspectPlugin(name: name) != nil
    }

    func pullPlugin(name: String, reference: String) -> Plugin {
        createPlugin(name: name, reference: reference)
    }

    func deletePlugin(name: String) -> Bool {
        let deleted = plugins.removeValue(forKey: resolvePluginName(name)) != nil
        if deleted { persist() }
        return deleted
    }

    func setPluginEnabled(name: String, enabled: Bool) -> Plugin? {
        let resolved = resolvePluginName(name)
        guard var plugin = plugins[resolved] else { return nil }
        plugin.enabled = enabled
        plugin.updatedAt = Date()
        plugin.version += 1
        plugins[resolved] = plugin
        persist()
        return plugin
    }

    func setPluginSettings(name: String, settings: [String: JSONValue]) -> Plugin? {
        let resolved = resolvePluginName(name)
        guard var plugin = plugins[resolved] else { return nil }
        plugin.settings = settings
        plugin.updatedAt = Date()
        plugin.version += 1
        plugins[resolved] = plugin
        persist()
        return plugin
    }

    func upgradePlugin(name: String, reference: String?) -> Plugin? {
        let resolved = resolvePluginName(name)
        guard var plugin = plugins[resolved] else { return nil }
        if let reference, !reference.isEmpty { plugin.reference = reference }
        plugin.updatedAt = Date()
        plugin.version += 1
        plugins[resolved] = plugin
        persist()
        return plugin
    }

    private func node() -> Node? {
        guard let swarm else { return nil }
        return Node(
            id: swarm.nodeID,
            version: nodeVersion,
            createdAt: swarm.createdAt,
            updatedAt: swarm.updatedAt,
            spec: nodeSpec
        )
    }

    private func matchesNode(_ node: Node, filters: [String: [String]]?) -> Bool {
        guard let filters else { return true }
        if let ids = filters["id"], !ids.isEmpty, !ids.contains(where: { node.id.hasPrefix($0) }) {
            return false
        }
        if let names = filters["name"], !names.isEmpty {
            guard case .string(let name) = node.spec["Name"],
                names.contains(where: { name == $0 || name.hasPrefix($0) })
            else { return false }
        }
        if let roles = filters["role"], !roles.isEmpty {
            guard case .string(let role) = node.spec["Role"], roles.contains(role) else { return false }
        }
        if let availability = filters["availability"], !availability.isEmpty {
            guard case .string(let value) = node.spec["Availability"], availability.contains(value)
            else { return false }
        }
        if let labels = filters["label"], !labels.isEmpty, !Self.matchesLabels(labels, actual: Self.stringMap(node.spec["Labels"])) {
            return false
        }
        return true
    }

    private func matchesService(_ service: Service, filters: [String: [String]]?) -> Bool {
        guard let filters else { return true }
        if let ids = filters["id"], !ids.isEmpty, !ids.contains(where: { service.id.hasPrefix($0) }) {
            return false
        }
        if let names = filters["name"], !names.isEmpty {
            guard case .string(let name) = service.spec["Name"],
                names.contains(where: { name == $0 || name.hasPrefix($0) })
            else { return false }
        }
        if let labels = filters["label"], !labels.isEmpty,
            !Self.matchesLabels(labels, actual: Self.stringMap(service.spec["Labels"]))
        {
            return false
        }
        if let modes = filters["mode"], !modes.isEmpty {
            let mode = Self.serviceMode(service.spec)
            if !modes.contains(mode) { return false }
        }
        return true
    }

    private func matchesTask(_ task: Task, filters: [String: [String]]?) -> Bool {
        guard let filters else { return true }
        if let ids = filters["id"], !ids.isEmpty, !ids.contains(where: { task.id.hasPrefix($0) }) {
            return false
        }
        if let serviceIDs = filters["service"], !serviceIDs.isEmpty,
            !serviceIDs.contains(where: { task.serviceID.hasPrefix($0) })
        {
            return false
        }
        if let nodeIDs = filters["node"], !nodeIDs.isEmpty,
            !nodeIDs.contains(where: { task.nodeID?.hasPrefix($0) == true })
        {
            return false
        }
        if let desiredStates = filters["desired-state"], !desiredStates.isEmpty,
            !desiredStates.contains(task.state)
        {
            return false
        }
        return true
    }

    private func matchesPlugin(_ plugin: Plugin, filters: [String: [String]]?) -> Bool {
        guard let filters else { return true }
        if let enabled = filters["enable"], !enabled.isEmpty {
            let wantsEnabled = enabled.contains { $0 == "1" || $0.lowercased() == "true" }
            let wantsDisabled = enabled.contains { $0 == "0" || $0.lowercased() == "false" }
            if wantsEnabled == wantsDisabled || (wantsEnabled && !plugin.enabled) || (wantsDisabled && plugin.enabled) {
                return false
            }
        }
        if let capabilities = filters["capability"], !capabilities.isEmpty {
            let pluginCapabilities = plugin.config["Linux"]
            guard
                capabilities.allSatisfy({ capability in
                    guard case .object(let linux) = pluginCapabilities,
                        case .array(let values) = linux["Capabilities"]
                    else { return false }
                    return values.contains { value in
                        if case .string(let text) = value { return text == capability }
                        return false
                    }
                })
            else { return false }
        }
        return true
    }

    private func resolveServiceID(_ id: String) -> String {
        services[id] != nil ? id : services.keys.first { $0.hasPrefix(id) } ?? id
    }

    private func resolveTaskID(_ id: String) -> String {
        tasks[id] != nil ? id : tasks.keys.first { $0.hasPrefix(id) } ?? id
    }

    private func resolvePluginName(_ name: String) -> String {
        plugins[name] != nil ? name : plugins.keys.first { $0.hasPrefix(name) } ?? name
    }

    private func create(spec: Spec, in storage: inout [String: StoredObject]) -> Object {
        let now = Date()
        let stored = StoredObject(
            id: Self.identifier(), version: 1, createdAt: now, updatedAt: now, spec: spec
        )
        storage[stored.id] = stored
        return object(stored)
    }

    private func list(in storage: [String: StoredObject], filters: [String: [String]]?) -> [Object] {
        storage.values
            .filter { matches($0, filters: filters) }
            .sorted { $0.createdAt < $1.createdAt }
            .map(object)
    }

    private func object(in storage: [String: StoredObject], id: String) -> Object? {
        guard let stored = storage[resolve(id, in: storage)] else { return nil }
        return object(stored)
    }

    private func object(_ stored: StoredObject) -> Object {
        Object(
            id: stored.id,
            version: stored.version,
            createdAt: stored.createdAt,
            updatedAt: stored.updatedAt,
            spec: stored.spec
        )
    }

    private func update(id: String, spec: Spec, in storage: inout [String: StoredObject]) -> Object? {
        let resolved = resolve(id, in: storage)
        guard var stored = storage[resolved] else { return nil }
        stored.version += 1
        stored.updatedAt = Date()
        stored.spec = spec
        storage[resolved] = stored
        return object(stored)
    }

    private func resolve(_ id: String, in storage: [String: StoredObject]) -> String {
        if storage[id] != nil { return id }
        return storage.keys.first { $0.hasPrefix(id) } ?? id
    }

    private func matches(_ object: StoredObject, filters: [String: [String]]?) -> Bool {
        guard let filters else { return true }
        if let ids = filters["id"], !ids.isEmpty,
            !ids.contains(where: { object.id.hasPrefix($0) })
        {
            return false
        }
        if let names = filters["name"], !names.isEmpty,
            !names.contains(where: { object.spec.name == $0 || object.spec.name.hasPrefix($0) })
        {
            return false
        }
        if let labels = filters["label"], !labels.isEmpty,
            !labels.allSatisfy({ label in
                let parts = label.split(separator: "=", maxSplits: 1).map(String.init)
                guard let value = object.spec.labels[parts[0]] else { return false }
                return parts.count == 1 || value == parts[1]
            })
        {
            return false
        }
        return true
    }

    private static func matchesLabels(_ expressions: [String], actual: [String: String]) -> Bool {
        expressions.allSatisfy { expression in
            let parts = expression.split(separator: "=", maxSplits: 1).map(String.init)
            guard let value = actual[parts[0]] else { return false }
            return parts.count == 1 || value == parts[1]
        }
    }

    private static func stringMap(_ value: JSONValue?) -> [String: String] {
        guard case .object(let values) = value else { return [:] }
        return values.reduce(into: [:]) { result, item in
            if case .string(let value) = item.value { result[item.key] = value }
        }
    }

    private static func serviceMode(_ spec: [String: JSONValue]) -> String {
        guard case .object(let mode) = spec["Mode"] else { return "replicated" }
        if mode["Global"] != nil { return "global" }
        return "replicated"
    }

    private static func identifier() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private func persist() {
        guard let stateURL else { return }
        let state = PersistedState(
            configs: configs, secrets: secrets, swarm: swarm, nodeVersion: nodeVersion,
            nodeSpec: nodeSpec, services: services, tasks: tasks, plugins: plugins
        )
        do {
            try FileManager.default.createDirectory(
                at: stateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try Self.stateEncoder.encode(state)
            try data.write(to: stateURL, options: .atomic)
        } catch {
            // Control-plane persistence must not make a valid Docker mutation
            // fail after the in-memory transaction has committed. The next
            // daemon start will retain the last successfully written snapshot.
        }
    }

    private static func replicaCount(spec: [String: JSONValue]) -> Int {
        guard case .object(let mode) = spec["Mode"] else { return 1 }
        if case .object(let replicated) = mode["Replicated"],
            case .number(let replicas) = replicated["Replicas"]
        {
            guard replicas.isFinite, replicas >= 0, replicas <= Double(Int.max) else { return 0 }
            return Int(replicas.rounded(.towardZero))
        }
        // A single local node is the complete set for a global service.
        if mode["Global"] != nil { return 1 }
        return 1
    }

    private static func validJoinToken(_ token: String) -> Bool {
        let parts = token.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "SWMTKN", parts[1] == "1",
            parts[2].count >= 16, parts[3].count >= 6
        else { return false }
        return parts.dropFirst(2).allSatisfy { part in
            part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == ".") }
        }
    }

    private static func validRemoteAddress(_ address: String) -> Bool {
        guard !address.isEmpty, !address.contains(where: { $0.isWhitespace || $0 == "/" }) else { return false }
        if address.first == "[" {
            guard let closing = address.firstIndex(of: "]"), address[closing...].hasPrefix("]:"),
                let port = Int(address[address.index(closing, offsetBy: 2)...])
            else { return false }
            return address.index(after: closing) < address.endIndex && (1...65535).contains(port)
        }
        guard let separator = address.lastIndex(of: ":"), separator != address.startIndex,
            separator < address.index(before: address.endIndex), !address[..<separator].contains(":"),
            let port = Int(address[address.index(after: separator)...])
        else { return false }
        return (1...65535).contains(port)
    }
}

struct DockerControlPlaneRoutes: RouteCollection {
    let controlPlane: DockerControlPlane
    let runtime: (any DockerControlPlaneRuntime)?

    init(controlPlane: DockerControlPlane, runtime: (any DockerControlPlaneRuntime)? = nil) {
        self.controlPlane = controlPlane
        self.runtime = runtime
    }

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/configs/create", use: createConfig)
        try routes.registerVersionedRoute(.GET, pattern: "/configs", use: listConfigs)
        try routes.registerVersionedRoute(.GET, pattern: "/configs/{id:.*}", use: inspectConfig)
        try routes.registerVersionedRoute(.POST, pattern: "/configs/{id:.*}/update", use: updateConfig)
        try routes.registerVersionedRoute(.DELETE, pattern: "/configs/{id:.*}", use: deleteConfig)
        try routes.registerVersionedRoute(.POST, pattern: "/secrets/create", use: createSecret)
        try routes.registerVersionedRoute(.GET, pattern: "/secrets", use: listSecrets)
        try routes.registerVersionedRoute(.GET, pattern: "/secrets/{id:.*}", use: inspectSecret)
        try routes.registerVersionedRoute(.POST, pattern: "/secrets/{id:.*}/update", use: updateSecret)
        try routes.registerVersionedRoute(.DELETE, pattern: "/secrets/{id:.*}", use: deleteSecret)
        try routes.registerVersionedRoute(.GET, pattern: "/swarm", use: inspectSwarm)
        try routes.registerVersionedRoute(.POST, pattern: "/swarm/init", use: initSwarm)
        try routes.registerVersionedRoute(.POST, pattern: "/swarm/join", use: joinSwarm)
        try routes.registerVersionedRoute(.POST, pattern: "/swarm/leave", use: leaveSwarm)
        try routes.registerVersionedRoute(.POST, pattern: "/swarm/unlock", use: unlockSwarm)
        try routes.registerVersionedRoute(.GET, pattern: "/swarm/unlockkey", use: unlockKey)
        try routes.registerVersionedRoute(.POST, pattern: "/swarm/update", use: updateSwarm)
        try routes.registerVersionedRoute(.GET, pattern: "/nodes", use: listNodes)
        try routes.registerVersionedRoute(.GET, pattern: "/nodes/{id:.*}", use: inspectNode)
        try routes.registerVersionedRoute(.POST, pattern: "/nodes/{id:.*}/update", use: updateNode)
        try routes.registerVersionedRoute(.DELETE, pattern: "/nodes/{id:.*}", use: deleteNode)
        try routes.registerVersionedRoute(.POST, pattern: "/services/create", use: createService)
        try routes.registerVersionedRoute(.GET, pattern: "/services", use: listServices)
        try routes.registerVersionedRoute(.GET, pattern: "/services/{id:.*}/logs", use: serviceLogs)
        try routes.registerVersionedRoute(.GET, pattern: "/services/{id:.*}", use: inspectService)
        try routes.registerVersionedRoute(.POST, pattern: "/services/{id:.*}/update", use: updateService)
        try routes.registerVersionedRoute(.DELETE, pattern: "/services/{id:.*}", use: deleteService)
        try routes.registerVersionedRoute(.GET, pattern: "/tasks", use: listTasks)
        try routes.registerVersionedRoute(.GET, pattern: "/tasks/{id:.*}/logs", use: taskLogs)
        try routes.registerVersionedRoute(.GET, pattern: "/tasks/{id:.*}", use: inspectTask)
        try routes.registerVersionedRoute(.GET, pattern: "/plugins", use: listPlugins)
        try routes.registerVersionedRoute(.GET, pattern: "/plugins/privileges", use: pluginPrivileges)
        try routes.registerVersionedRoute(.POST, pattern: "/plugins/create", use: createPlugin)
        try routes.registerVersionedRoute(.POST, pattern: "/plugins/pull", use: pullPlugin)
        try routes.registerVersionedRoute(.GET, pattern: "/plugins/{name:.*}/json", use: inspectPlugin)
        try routes.registerVersionedRoute(.POST, pattern: "/plugins/{name:.*}/disable", use: disablePlugin)
        try routes.registerVersionedRoute(.POST, pattern: "/plugins/{name:.*}/enable", use: enablePlugin)
        try routes.registerVersionedRoute(.POST, pattern: "/plugins/{name:.*}/push", use: pushPlugin)
        try routes.registerVersionedRoute(.POST, pattern: "/plugins/{name:.*}/set", use: setPlugin)
        try routes.registerVersionedRoute(.POST, pattern: "/plugins/{name:.*}/upgrade", use: upgradePlugin)
        try routes.registerVersionedRoute(.DELETE, pattern: "/plugins/{name:.*}", use: deletePlugin)
    }

    private func createConfig(_ req: Request) async throws -> Response {
        let spec = try await decodeSpec(req, secret: false)
        guard !(await controlPlane.configExists(name: spec.name)) else {
            throw Abort(.conflict, reason: "config (spec.name) already exists")
        }
        let object = await controlPlane.createConfig(spec: spec)
        return try jsonResponse(.created, CreateResponse(id: object.id))
    }

    private func listConfigs(_ req: Request) async throws -> Response {
        let objects = await controlPlane.listConfigs(
            filters: try filters(req, allowed: ["id", "name", "label"])
        )
        return try jsonResponse(.ok, objects.map { ObjectResponse($0, secret: false) })
    }

    private func inspectConfig(_ req: Request) async throws -> Response {
        let object = await controlPlane.inspectConfig(id: try parameter("id", req))
        guard let object else { throw Abort(.notFound, reason: "config not found") }
        return try jsonResponse(.ok, ObjectResponse(object, secret: false))
    }

    private func updateConfig(_ req: Request) async throws -> Response {
        let id = try parameter("id", req)
        guard let version = await controlPlane.configVersion(id: id) else {
            throw Abort(.notFound, reason: "config not found")
        }
        try Self.validateVersion(req, current: version)
        let object = await controlPlane.updateConfig(
            id: id, spec: try await decodeSpec(req, secret: false)
        )
        guard object != nil else { throw Abort(.notFound, reason: "config not found") }
        return Response(status: .ok)
    }

    private func deleteConfig(_ req: Request) async throws -> Response {
        guard await controlPlane.deleteConfig(id: try parameter("id", req)) else {
            throw Abort(.notFound, reason: "config not found")
        }
        return Response(status: .noContent)
    }

    private func createSecret(_ req: Request) async throws -> Response {
        let spec = try await decodeSpec(req, secret: true)
        guard !(await controlPlane.secretExists(name: spec.name)) else {
            throw Abort(.conflict, reason: "secret (spec.name) already exists")
        }
        let object = await controlPlane.createSecret(spec: spec)
        return try jsonResponse(.created, CreateResponse(id: object.id))
    }

    private func listSecrets(_ req: Request) async throws -> Response {
        let objects = await controlPlane.listSecrets(
            filters: try filters(req, allowed: ["id", "name", "label"])
        )
        return try jsonResponse(.ok, objects.map { ObjectResponse($0, secret: true) })
    }

    private func inspectSecret(_ req: Request) async throws -> Response {
        let object = await controlPlane.inspectSecret(id: try parameter("id", req))
        guard let object else { throw Abort(.notFound, reason: "secret not found") }
        return try jsonResponse(.ok, ObjectResponse(object, secret: true))
    }

    private func updateSecret(_ req: Request) async throws -> Response {
        let id = try parameter("id", req)
        guard let version = await controlPlane.secretVersion(id: id) else {
            throw Abort(.notFound, reason: "secret not found")
        }
        try Self.validateVersion(req, current: version)
        let object = await controlPlane.updateSecret(
            id: id, spec: try await decodeSpec(req, secret: true)
        )
        guard object != nil else { throw Abort(.notFound, reason: "secret not found") }
        return Response(status: .ok)
    }

    private func deleteSecret(_ req: Request) async throws -> Response {
        guard await controlPlane.deleteSecret(id: try parameter("id", req)) else {
            throw Abort(.notFound, reason: "secret not found")
        }
        return Response(status: .noContent)
    }

    private func inspectSwarm(_ req: Request) async throws -> Response {
        guard let swarm = await controlPlane.currentSwarm() else {
            throw Abort(.serviceUnavailable, reason: "This node is not a swarm manager")
        }
        return try jsonResponse(.ok, SwarmResponse(swarm))
    }

    private func initSwarm(_ req: Request) async throws -> Response {
        let payload = try await decodeSwarmRequest(req)
        let swarm = await controlPlane.initializeSwarm(spec: payload.spec)
        return try jsonResponse(.ok, SwarmInitResponse(swarm))
    }

    private func joinSwarm(_ req: Request) async throws -> Response {
        let payload = try await decodeSwarmRequest(req)
        guard
            let swarm = await controlPlane.joinSwarm(
                spec: payload.spec,
                token: payload.token ?? "",
                remoteAddresses: payload.remoteAddresses
            )
        else {
            throw Abort(.badRequest, reason: "invalid swarm join token")
        }
        return try jsonResponse(.ok, JoinResponse(NodeID: swarm.nodeID))
    }

    private func leaveSwarm(_ req: Request) async throws -> Response {
        if let runtime {
            for containerID in await controlPlane.allTaskContainerIDs() {
                try? await runtime.deleteContainer(id: containerID, force: true, removeVolumes: true)
            }
        }
        await controlPlane.leaveSwarm()
        return Response(status: .ok)
    }

    private func unlockSwarm(_ req: Request) async throws -> Response {
        let payload = try await decodeSwarmRequest(req)
        guard await controlPlane.currentSwarm() != nil else {
            throw Abort(.serviceUnavailable, reason: "This node is not a swarm manager")
        }
        guard await controlPlane.unlockSwarm(key: payload.unlockKey ?? "") else {
            throw Abort(.internalServerError, reason: "swarm unlock key is invalid")
        }
        return Response(status: .ok)
    }

    private func unlockKey(_ req: Request) async throws -> Response {
        guard let swarm = await controlPlane.currentSwarm() else {
            throw Abort(.serviceUnavailable, reason: "This node is not a swarm manager")
        }
        return try jsonResponse(.ok, UnlockKeyResponse(UnlockKey: swarm.unlockKey))
    }

    private func updateSwarm(_ req: Request) async throws -> Response {
        let payload = try await decodeSwarmRequest(req)
        guard let current = await controlPlane.currentSwarm() else {
            throw Abort(.serviceUnavailable, reason: "This node is not a swarm manager")
        }
        try Self.validateVersion(req, current: current.version)
        _ = await controlPlane.updateSwarm(spec: payload.spec)
        return Response(status: .ok)
    }

    private func listNodes(_ req: Request) async throws -> Response {
        guard await controlPlane.currentSwarm() != nil else {
            throw Abort(.serviceUnavailable, reason: "This node is not a swarm manager")
        }
        let nodes = await controlPlane.listNodes(
            filters: try filters(req, allowed: ["id", "name", "role", "availability", "label"])
        )
        return try jsonResponse(.ok, nodes.map(NodeResponse.init))
    }

    private func inspectNode(_ req: Request) async throws -> Response {
        let node = await controlPlane.inspectNode(id: try parameter("id", req))
        guard let node else { throw Abort(.notFound, reason: "node not found") }
        return try jsonResponse(.ok, NodeResponse(node))
    }

    private func updateNode(_ req: Request) async throws -> Response {
        let nodeID = try parameter("id", req)
        guard let version = await controlPlane.nodeVersion(id: nodeID) else {
            throw Abort(.notFound, reason: "node not found")
        }
        try Self.validateVersion(req, current: version)
        let request = try await decodeObject(req, message: "node specification")
        let spec: [String: DockerControlPlane.JSONValue]
        if case .object(let nested) = request["Spec"] {
            spec = nested
        } else {
            spec = request
        }
        var normalizedSpec = spec
        normalizedSpec.removeValue(forKey: "Version")
        let node = await controlPlane.updateNode(
            id: nodeID, spec: normalizedSpec
        )
        guard let node else { throw Abort(.notFound, reason: "node not found") }
        return try jsonResponse(.ok, NodeResponse(node))
    }

    private func deleteNode(_ req: Request) async throws -> Response {
        guard await controlPlane.removeNode(id: try parameter("id", req)) else {
            throw Abort(.notFound, reason: "node not found")
        }
        return try jsonResponse(.ok, WarningsResponse())
    }

    private func createService(_ req: Request) async throws -> Response {
        let spec = try await decodeObject(req, message: "service specification")
        guard case .string(let name) = spec["Name"], !name.isEmpty else {
            throw Abort(.badRequest, reason: "service Name is required")
        }
        guard let service = await controlPlane.createService(spec: spec) else {
            if await controlPlane.currentSwarm() != nil {
                throw Abort(.conflict, reason: "service (name) already exists")
            }
            throw Abort(.serviceUnavailable, reason: "This node is not a swarm manager")
        }
        guard let runtime else {
            _ = await controlPlane.removeService(id: service.id)
            throw Abort(.serviceUnavailable, reason: "service scheduler is unavailable")
        }
        do {
            var createdContainers: [String] = []
            for taskID in service.taskIDs {
                do {
                    let container = try await runtime.createContainer(
                        try containerRequest(serviceName: name, specification: spec)
                    )
                    createdContainers.append(container.id)
                    try await runtime.startContainer(id: container.id)
                    guard
                        await controlPlane.attachTaskContainer(
                            taskID: taskID, containerID: container.id
                        )
                    else {
                        throw Abort(.internalServerError, reason: "service task was not retained")
                    }
                } catch {
                    for containerID in createdContainers {
                        try? await runtime.deleteContainer(
                            id: containerID, force: true, removeVolumes: true
                        )
                    }
                    throw error
                }
            }
        } catch let abort as Abort {
            _ = await controlPlane.removeService(id: service.id)
            throw abort
        } catch {
            _ = await controlPlane.removeService(id: service.id)
            throw Abort(.serviceUnavailable, reason: "service task could not be started: \(error)")
        }
        return try jsonResponse(.created, ServiceCreateResponse(id: service.id))
    }

    private func listServices(_ req: Request) async throws -> Response {
        guard await controlPlane.currentSwarm() != nil else {
            throw Abort(.serviceUnavailable, reason: "This node is not a swarm manager")
        }
        let services = await controlPlane.listServices(
            filters: try filters(req, allowed: ["id", "name", "label", "mode"])
        )
        let includeStatus = Self.mobyBool(req.query[String.self, at: "status"])
        var responses: [ServiceResponse] = []
        responses.reserveCapacity(services.count)
        for service in services {
            let status = includeStatus ? await controlPlane.serviceTaskStatus(for: service) : nil
            responses.append(ServiceResponse(service, status: status))
        }
        return try jsonResponse(.ok, responses)
    }

    private func inspectService(_ req: Request) async throws -> Response {
        let service = await controlPlane.inspectService(id: try parameter("id", req))
        guard let service else { throw Abort(.notFound, reason: "service not found") }
        return try jsonResponse(.ok, ServiceResponse(service))
    }

    private func updateService(_ req: Request) async throws -> Response {
        guard let runtime else {
            throw Abort(.serviceUnavailable, reason: "service scheduler is unavailable")
        }
        let serviceID = try parameter("id", req)
        let specification = try await decodeObject(req, message: "service specification")
        guard let current = await controlPlane.inspectService(id: serviceID) else {
            throw Abort(.notFound, reason: "service not found")
        }
        try Self.validateVersion(req, current: current.version)
        let oldContainerIDs = await controlPlane.taskContainerIDs(for: current)
        guard case .string(let name) = specification["Name"], !name.isEmpty else {
            throw Abort(.badRequest, reason: "service Name is required")
        }

        do {
            guard let service = await controlPlane.updateService(id: serviceID, spec: specification) else {
                throw Abort(.notFound, reason: "service not found")
            }
            var replacements: [String] = []
            do {
                for taskID in service.taskIDs {
                    let replacement = try await runtime.createContainer(
                        try containerRequest(serviceName: name, specification: specification)
                    )
                    replacements.append(replacement.id)
                    try await runtime.startContainer(id: replacement.id)
                    guard
                        await controlPlane.attachTaskContainer(
                            taskID: taskID, containerID: replacement.id
                        )
                    else {
                        throw Abort(.internalServerError, reason: "service task was not retained")
                    }
                }
            } catch {
                for containerID in replacements {
                    try? await runtime.deleteContainer(
                        id: containerID, force: true, removeVolumes: true
                    )
                }
                throw error
            }
            for oldContainerID in oldContainerIDs {
                if !replacements.contains(oldContainerID) {
                    try await runtime.deleteContainer(
                        id: oldContainerID, force: true, removeVolumes: true
                    )
                }
            }
            return try jsonResponse(.ok, ServiceUpdateResponse(service: service))
        } catch let abort as Abort {
            throw abort
        } catch {
            throw Abort(.serviceUnavailable, reason: "service task could not be reconciled: \(error)")
        }
    }

    private func deleteService(_ req: Request) async throws -> Response {
        guard let runtime else {
            throw Abort(.serviceUnavailable, reason: "service scheduler is unavailable")
        }
        let serviceID = try parameter("id", req)
        guard let service = await controlPlane.inspectService(id: serviceID) else {
            throw Abort(.notFound, reason: "service not found")
        }
        let containerIDs = await controlPlane.taskContainerIDs(for: service)
        for containerID in containerIDs {
            do {
                try await runtime.deleteContainer(id: containerID, force: true, removeVolumes: true)
            } catch {
                throw Abort(.serviceUnavailable, reason: "service task could not be removed: \(error)")
            }
        }
        guard await controlPlane.removeService(id: service.id) else {
            throw Abort(.notFound, reason: "service not found")
        }
        return try jsonResponse(.ok, WarningsResponse())
    }

    private func serviceLogs(_ req: Request) async throws -> Response {
        guard let service = await controlPlane.inspectService(id: try parameter("id", req)) else {
            throw Abort(.notFound, reason: "service not found")
        }
        let containerIDs = await controlPlane.taskContainerIDs(for: service)
        guard !containerIDs.isEmpty else {
            throw Abort(.serviceUnavailable, reason: "service has no running tasks")
        }
        return try await logsResponse(containerIDs: containerIDs, request: req)
    }

    private func listTasks(_ req: Request) async throws -> Response {
        guard await controlPlane.currentSwarm() != nil else {
            throw Abort(.serviceUnavailable, reason: "This node is not a swarm manager")
        }
        let tasks = await refreshTasks(
            await controlPlane.listTasks(
                filters: try filters(
                    req,
                    allowed: ["id", "name", "service", "node", "desired-state", "label"]
                )
            )
        )
        return try jsonResponse(.ok, tasks.map(TaskResponse.init))
    }

    private func inspectTask(_ req: Request) async throws -> Response {
        let task = await controlPlane.inspectTask(id: try parameter("id", req))
        guard let task else { throw Abort(.notFound, reason: "task not found") }
        return try jsonResponse(.ok, TaskResponse(await refreshTask(task)))
    }

    private func refreshTasks(_ tasks: [DockerControlPlane.Task]) async -> [DockerControlPlane.Task] {
        var refreshed: [DockerControlPlane.Task] = []
        refreshed.reserveCapacity(tasks.count)
        for task in tasks {
            refreshed.append(await refreshTask(task))
        }
        return refreshed
    }

    private func refreshTask(_ task: DockerControlPlane.Task) async -> DockerControlPlane.Task {
        guard let runtime, let containerID = task.containerID,
            let container = try? await runtime.inspectContainer(id: containerID),
            let refreshed = await controlPlane.updateTaskRuntime(id: task.id, container: container)
        else { return task }
        return refreshed
    }

    private func taskLogs(_ req: Request) async throws -> Response {
        let taskID = try parameter("id", req)
        guard await controlPlane.inspectTask(id: taskID) != nil else {
            throw Abort(.notFound, reason: "task not found")
        }
        return try await logsResponse(taskID: taskID, request: req)
    }

    private func listPlugins(_ req: Request) async throws -> Response {
        let filters = try pluginFilters(req)
        let plugins = await controlPlane.listPlugins(filters: filters)
        return try jsonResponse(.ok, plugins.map(PluginResponse.init))
    }

    private func pluginPrivileges(_ req: Request) async throws -> Response {
        try jsonResponse(.ok, [PluginPrivilege()])
    }

    private func createPlugin(_ req: Request) async throws -> Response {
        guard let name = req.query[String.self, at: "name"], !name.isEmpty else {
            throw Abort(.badRequest, reason: "plugin name is required")
        }
        guard !(await controlPlane.pluginExists(name: name)) else {
            throw Abort(.conflict, reason: "plugin (name) already exists")
        }
        _ = try await bodyData(req, allowEmpty: true)
        _ = await controlPlane.createPlugin(name: name, reference: name)
        return Response(status: .noContent)
    }

    private func pullPlugin(_ req: Request) async throws -> Response {
        guard let reference = req.query[String.self, at: "remote"], !reference.isEmpty else {
            throw Abort(.badRequest, reason: "plugin remote reference is required")
        }
        let name = req.query[String.self, at: "name"] ?? Self.pluginName(from: reference)
        guard !name.isEmpty else { throw Abort(.badRequest, reason: "plugin name is required") }
        guard !(await controlPlane.pluginExists(name: name)) else {
            throw Abort(.conflict, reason: "plugin (name) already exists")
        }
        _ = try await bodyData(req, allowEmpty: true)
        _ = await controlPlane.pullPlugin(name: name, reference: reference)
        return Response(status: .noContent)
    }

    private func inspectPlugin(_ req: Request) async throws -> Response {
        let plugin = await controlPlane.inspectPlugin(name: try parameter("name", req))
        guard let plugin else { throw Abort(.notFound, reason: "plugin not found") }
        return try jsonResponse(.ok, PluginResponse(plugin))
    }

    private func disablePlugin(_ req: Request) async throws -> Response {
        guard
            await controlPlane.setPluginEnabled(
                name: try parameter("name", req), enabled: false
            ) != nil
        else { throw Abort(.notFound, reason: "plugin not found") }
        return Response(status: .ok)
    }

    private func enablePlugin(_ req: Request) async throws -> Response {
        guard
            await controlPlane.setPluginEnabled(
                name: try parameter("name", req), enabled: true
            ) != nil
        else { throw Abort(.notFound, reason: "plugin not found") }
        return Response(status: .ok)
    }

    private func pushPlugin(_ req: Request) async throws -> Response {
        guard await controlPlane.inspectPlugin(name: try parameter("name", req)) != nil else {
            throw Abort(.notFound, reason: "plugin not found")
        }
        return Response(status: .ok)
    }

    private func setPlugin(_ req: Request) async throws -> Response {
        let settings = try await decodePluginSettings(req)
        let plugin = await controlPlane.setPluginSettings(
            name: try parameter("name", req), settings: settings
        )
        guard let plugin else { throw Abort(.notFound, reason: "plugin not found") }
        _ = plugin
        return Response(status: .noContent)
    }

    private func upgradePlugin(_ req: Request) async throws -> Response {
        guard let remote = req.query[String.self, at: "remote"], !remote.isEmpty else {
            throw Abort(.badRequest, reason: "plugin remote reference is required")
        }
        guard
            await controlPlane.upgradePlugin(
                name: try parameter("name", req), reference: remote
            ) != nil
        else { throw Abort(.notFound, reason: "plugin not found") }
        _ = try await bodyData(req, allowEmpty: true)
        return Response(status: .noContent)
    }

    private func deletePlugin(_ req: Request) async throws -> Response {
        let name = try parameter("name", req)
        guard let plugin = await controlPlane.inspectPlugin(name: name) else {
            throw Abort(.notFound, reason: "plugin not found")
        }
        guard await controlPlane.deletePlugin(name: name) else {
            throw Abort(.notFound, reason: "plugin not found")
        }
        return try jsonResponse(.ok, PluginResponse(plugin))
    }

    private func decodeSpec(_ req: Request, secret: Bool) async throws -> DockerControlPlane.Spec {
        let body = try await bodyData(req)
        let value: SpecRequest
        do {
            value = try JSONDecoder().decode(SpecRequest.self, from: body)
        } catch {
            throw Abort(.badRequest, reason: "Invalid \(secret ? "secret" : "config") specification")
        }
        guard let name = value.name, !name.isEmpty else {
            throw Abort(.badRequest, reason: "Name is required")
        }
        return .init(name: name, labels: value.labels ?? [:], data: value.data)
    }

    private func decodeObject(_ req: Request, message: String) async throws -> [String: DockerControlPlane.JSONValue] {
        let body = try await bodyData(req)
        do {
            return try JSONDecoder().decode([String: DockerControlPlane.JSONValue].self, from: body)
        } catch {
            throw Abort(.badRequest, reason: "Invalid \(message)")
        }
    }

    private func decodePluginSettings(_ req: Request) async throws -> [String: DockerControlPlane.JSONValue] {
        let body = try await bodyData(req, allowEmpty: true)
        guard !body.isEmpty else { return [:] }
        if let values = try? JSONDecoder().decode([String].self, from: body) {
            var settings: [String: DockerControlPlane.JSONValue] = [:]
            for value in values {
                let parts = value.split(separator: "=", maxSplits: 1).map(String.init)
                guard let key = parts.first, !key.isEmpty else {
                    throw Abort(.badRequest, reason: "Invalid plugin setting")
                }
                settings[key] = .string(parts.count == 2 ? parts[1] : "")
            }
            return settings
        }
        do {
            return try JSONDecoder().decode(
                [String: DockerControlPlane.JSONValue].self, from: body
            )
        } catch {
            throw Abort(.badRequest, reason: "Invalid plugin settings")
        }
    }

    private func pluginFilters(_ req: Request) throws -> [String: [String]]? {
        guard let filters = try filters(req) else { return nil }
        let allowed = Set(["capability", "enable"])
        if let unknown = filters.keys.first(where: { !allowed.contains($0) }) {
            throw Abort(.badRequest, reason: "invalid plugin filter '\(unknown)'")
        }
        if let values = filters["enable"],
            values.isEmpty
                || values.contains(where: {
                    !["0", "1", "true", "false"].contains($0.lowercased())
                })
        {
            throw Abort(.badRequest, reason: "invalid plugin filter 'enable'")
        }
        return filters
    }

    private static func pluginName(from reference: String) -> String {
        let last = reference.split(separator: "/").last.map(String.init) ?? reference
        if let colon = last.lastIndex(of: ":") {
            return String(last[..<colon])
        }
        if let at = last.firstIndex(of: "@") {
            return String(last[..<at])
        }
        return last
    }

    private static func stringValue(_ value: DockerControlPlane.JSONValue) -> String? {
        guard case .string(let string) = value else { return nil }
        return string
    }

    private func decodeSwarmRequest(_ req: Request) async throws -> SwarmRequest {
        let body = try await bodyData(req, allowEmpty: true)
        guard body.isEmpty == false else { return SwarmRequest() }
        do {
            return try JSONDecoder().decode(SwarmRequest.self, from: body)
        } catch {
            throw Abort(.badRequest, reason: "Invalid swarm request")
        }
    }

    private func bodyData(_ req: Request, allowEmpty: Bool = false) async throws -> Data {
        guard let buffer = try await req.body.collect(max: req.application.routes.defaultMaxBodySize.value).get() else {
            if allowEmpty { return Data() }
            throw Abort(.badRequest, reason: "Request body is required")
        }
        guard let data = buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes) else {
            if allowEmpty { return Data() }
            throw Abort(.badRequest, reason: "Request body is required")
        }
        guard allowEmpty || !data.isEmpty else {
            throw Abort(.badRequest, reason: "Request body is required")
        }
        return data
    }

    private func filters(_ req: Request) throws -> [String: [String]]? {
        try filters(req, allowed: nil)
    }

    private func filters(
        _ req: Request, allowed: Set<String>?
    ) throws -> [String: [String]]? {
        guard let raw = req.query[String.self, at: "filters"],
            let data = raw.data(using: .utf8)
        else { return nil }
        do {
            let decoded = try JSONDecoder().decode([String: [String]].self, from: data)
            if let allowed, let unknown = decoded.keys.first(where: { !allowed.contains($0) }) {
                throw Abort(.badRequest, reason: "invalid filter '\(unknown)'")
            }
            return decoded
        } catch let abort as Abort {
            throw abort
        } catch {
            throw Abort(.badRequest, reason: "invalid filters")
        }
    }

    private static func validateVersion(_ req: Request, current: UInt64) throws {
        guard let raw = req.query[String.self, at: "version"] else {
            throw Abort(.badRequest, reason: "version is required")
        }
        guard let requested = UInt64(raw) else {
            throw Abort(.badRequest, reason: "version must be a non-negative integer")
        }
        guard requested == current else {
            throw Abort(.conflict, reason: "update conflict: object version is (current)")
        }
    }

    private func parameter(_ name: String, _ req: Request) throws -> String {
        guard let value = req.parameters.get(name), !value.isEmpty else {
            throw Abort(.badRequest, reason: "Missing \(name)")
        }
        return value
    }

    private func jsonResponse<T: Encodable>(_ status: HTTPResponseStatus, _ value: T) throws -> Response {
        let response = Response(status: status, body: .init(data: try JSONEncoder().encode(value)))
        response.headers.contentType = .json
        return response
    }

    private func logsResponse(taskID: String, request: Request) async throws -> Response {
        guard let containerID = await controlPlane.taskContainerID(id: taskID) else {
            throw Abort(.serviceUnavailable, reason: "service task has not been scheduled")
        }
        return try await logsResponse(containerIDs: [containerID], request: request)
    }

    private func logsResponse(containerIDs: [String], request: Request) async throws -> Response {
        guard !containerIDs.isEmpty else {
            throw Abort(.serviceUnavailable, reason: "service has no scheduled tasks")
        }
        guard let runtime else {
            throw Abort(.serviceUnavailable, reason: "service scheduler is unavailable")
        }
        let hasStreamSelection =
            request.query[String.self, at: "stdout"] != nil
            || request.query[String.self, at: "stderr"] != nil
        let stdout =
            hasStreamSelection
            ? Self.mobyBool(request.query[String.self, at: "stdout"])
            : true
        let stderr =
            hasStreamSelection
            ? Self.mobyBool(request.query[String.self, at: "stderr"])
            : true
        guard stdout || stderr else {
            throw Abort(.badRequest, reason: "Bad parameters: you must choose at least one stream")
        }
        let options = try Self.logOptions(request)
        if Self.mobyBool(request.query[String.self, at: "follow"]) {
            var collectedStreams: [AsyncThrowingStream<DockerRuntimeProcessFrame, Error>] = []
            for containerID in containerIDs {
                collectedStreams.append(
                    try await runtime.streamLogs(
                        id: containerID, stdout: stdout, stderr: stderr, options: options
                    ))
            }
            let streams = collectedStreams
            let response = Response(
                status: .ok,
                body: .init(managedAsyncStream: { writer in
                    for stream in streams {
                        for try await frame in stream {
                            let data = Self.rawStreamFrame(
                                frame.data, stream: frame.stream == .stderr ? 2 : 1
                            )
                            try await writer.writeBuffer(ByteBuffer(data: data))
                        }
                    }
                })
            )
            response.headers.contentType = HTTPMediaType(
                type: "application", subType: "vnd.docker.raw-stream"
            )
            return response
        }
        var data = Data()
        for containerID in containerIDs {
            var output = try await runtime.logs(
                id: containerID, stdout: stdout, stderr: stderr, options: options
            )
            if !(await runtime.supportsLogOptions()), let tail = request.query[String.self, at: "tail"] {
                output = try Self.applyTail(output, value: tail)
            }
            if stdout { data.append(Self.rawStreamFrame(output.stdout, stream: 1)) }
            if stderr { data.append(Self.rawStreamFrame(output.stderr, stream: 2)) }
        }
        let response = Response(status: .ok, body: .init(data: data))
        response.headers.contentType = HTTPMediaType(
            type: "application", subType: "vnd.docker.raw-stream"
        )
        return response
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

    private static func applyTail(
        _ output: DockerRuntimeProcessOutput, value: String
    ) throws -> DockerRuntimeProcessOutput {
        guard value != "all" else { return output }
        guard let count = Int(value), count >= 0 else {
            throw Abort(.badRequest, reason: "Invalid tail value: \(value)")
        }
        func tail(_ data: Data) -> Data {
            guard count > 0 else { return Data() }
            let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
            let start = max(0, lines.count - count - (lines.last?.isEmpty == true ? 1 : 0))
            return Data(lines[start...].joined(separator: [0x0A]))
        }
        return DockerRuntimeProcessOutput(
            stdout: tail(output.stdout), stderr: tail(output.stderr), exitCode: output.exitCode
        )
    }

    private func containerRequest(
        serviceName: String, specification: [String: DockerControlPlane.JSONValue]
    ) throws -> DockerRuntimeContainerCreate {
        guard
            case .object(let taskTemplate) = specification["TaskTemplate"],
            case .object(let containerSpec) = taskTemplate["ContainerSpec"],
            case .string(let image) = containerSpec["Image"], !image.isEmpty
        else {
            throw Abort(.badRequest, reason: "TaskTemplate.ContainerSpec.Image is required")
        }
        let command = Self.strings(containerSpec["Command"])
        let arguments = Self.strings(containerSpec["Args"])
        let labels = Self.stringMap(containerSpec["Labels"])
        let environment = Self.strings(containerSpec["Env"])
        let mounts = try Self.mounts(containerSpec["Mounts"])
        let ports = try Self.ports(specification["EndpointSpec"])
        let restartPolicy = Self.restartPolicy(taskTemplate["RestartPolicy"])
        let resources = Self.resources(taskTemplate["Resources"])
        return DockerRuntimeContainerCreate(
            name: "swarm-\(serviceName)-\(UUID().uuidString.prefix(8).lowercased())",
            image: image,
            command: command + arguments,
            entrypoint: command.isEmpty ? nil : command,
            cmd: arguments.isEmpty ? nil : arguments,
            environment: environment,
            workingDirectory: Self.string(containerSpec["Dir"]),
            user: Self.string(containerSpec["User"]),
            hostname: Self.string(containerSpec["Hostname"]),
            labels: labels,
            tty: Self.bool(containerSpec["TTY"]) ?? false,
            autoRemove: false,
            stopTimeout: nil,
            mounts: mounts,
            ports: ports,
            restartPolicy: restartPolicy,
            resources: resources,
            stopSignal: Self.string(containerSpec["StopSignal"])
        )
    }

    private static func string(_ value: DockerControlPlane.JSONValue?) -> String? {
        guard case .string(let value) = value else { return nil }
        return value
    }

    private static func bool(_ value: DockerControlPlane.JSONValue?) -> Bool? {
        guard case .bool(let value) = value else { return nil }
        return value
    }

    private static func number(_ value: DockerControlPlane.JSONValue?) -> Double? {
        guard case .number(let value) = value else { return nil }
        return value
    }

    private static func ports(
        _ value: DockerControlPlane.JSONValue?
    ) throws -> [DockerRuntimePortBinding] {
        guard case .object(let endpoint) = value,
            case .array(let values) = endpoint["Ports"]
        else { return [] }
        return try values.map { value in
            guard case .object(let port) = value,
                let target = Self.number(port["TargetPort"]), target > 0,
                target <= Double(Int.max),
                let published = Self.number(port["PublishedPort"]), published > 0,
                published <= Double(Int.max)
            else {
                throw Abort(.badRequest, reason: "EndpointSpec.Ports contains an invalid port")
            }
            let proto = Self.string(port["Protocol"]) ?? "tcp"
            guard ["tcp", "udp", "sctp"].contains(proto.lowercased()) else {
                throw Abort(.badRequest, reason: "unsupported service port protocol")
            }
            return DockerRuntimePortBinding(
                containerPort: Int(target), proto: proto.lowercased(), hostIP: "0.0.0.0",
                hostPort: Int(published)
            )
        }
    }

    private static func restartPolicy(
        _ value: DockerControlPlane.JSONValue?
    ) -> DockerRuntimeRestartPolicy {
        guard case .object(let policy) = value else { return .init() }
        let condition = (Self.string(policy["Condition"]) ?? "none").lowercased()
        let name: String
        switch condition {
        case "any": name = "always"
        case "on-failure": name = "on-failure"
        default: name = "no"
        }
        let attempts = Int(Self.number(policy["MaxAttempts"]) ?? 0)
        return DockerRuntimeRestartPolicy(name: name, maximumRetryCount: max(attempts, 0))
    }

    private static func resources(
        _ value: DockerControlPlane.JSONValue?
    ) -> DockerRuntimeResources {
        guard case .object(let resources) = value,
            case .object(let limits) = resources["Limits"]
        else { return .init() }
        return DockerRuntimeResources(
            memory: Int64(Self.number(limits["MemoryBytes"]) ?? 0),
            nanoCPUs: Int64(Self.number(limits["NanoCPUs"]) ?? 0),
            pidsLimit: Int64(Self.number(limits["PidsLimit"]) ?? 0)
        )
    }

    private static func strings(_ value: DockerControlPlane.JSONValue?) -> [String] {
        guard case .array(let values) = value else { return [] }
        return values.compactMap(string)
    }

    private static func stringMap(_ value: DockerControlPlane.JSONValue?) -> [String: String] {
        guard case .object(let values) = value else { return [:] }
        return values.reduce(into: [:]) { result, item in
            if let value = string(item.value) { result[item.key] = value }
        }
    }

    private static func mounts(
        _ value: DockerControlPlane.JSONValue?
    ) throws -> [DockerRuntimeMount] {
        guard case .array(let values) = value else { return [] }
        return try values.map { value in
            guard case .object(let mount) = value,
                let source = string(mount["Source"]),
                let target = string(mount["Target"]),
                !source.isEmpty, !target.isEmpty
            else {
                throw Abort(.badRequest, reason: "Invalid service mount")
            }
            return DockerRuntimeMount(
                source: source,
                target: target,
                readOnly: bool(mount["ReadOnly"]) ?? false
            )
        }
    }

    private static func rawStreamFrame(_ payload: Data, stream: UInt8) -> Data {
        guard !payload.isEmpty else { return Data() }
        var frame = Data([stream, 0, 0, 0])
        var length = UInt32(payload.count).bigEndian
        frame.append(Data(bytes: &length, count: MemoryLayout<UInt32>.size))
        frame.append(payload)
        return frame
    }

    private struct SpecRequest: Decodable {
        let name: String?
        let labels: [String: String]?
        let data: String?

        enum CodingKeys: String, CodingKey {
            case name = "Name"
            case labels = "Labels"
            case data = "Data"
        }
    }

    private struct SwarmRequest: Decodable {
        let name: String?
        let labels: [String: String]?
        let token: String?
        let unlockKey: String?
        let remoteAddresses: [String]
        let nestedSpec: [String: DockerControlPlane.JSONValue]?

        enum CodingKeys: String, CodingKey {
            case name = "Name"
            case labels = "Labels"
            case token = "JoinToken"
            case unlockKey = "UnlockKey"
            case remoteAddresses = "RemoteAddrs"
            case spec = "Spec"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            labels = try container.decodeIfPresent([String: String].self, forKey: .labels)
            token = try container.decodeIfPresent(String.self, forKey: .token)
            unlockKey = try container.decodeIfPresent(String.self, forKey: .unlockKey)
            remoteAddresses = try container.decodeIfPresent([String].self, forKey: .remoteAddresses) ?? []
            nestedSpec = try container.decodeIfPresent(
                [String: DockerControlPlane.JSONValue].self, forKey: .spec
            )
        }

        init(
            name: String? = nil,
            labels: [String: String]? = nil,
            token: String? = nil,
            unlockKey: String? = nil,
            remoteAddresses: [String] = [],
            nestedSpec: [String: DockerControlPlane.JSONValue]? = nil
        ) {
            self.name = name
            self.labels = labels
            self.token = token
            self.unlockKey = unlockKey
            self.remoteAddresses = remoteAddresses
            self.nestedSpec = nestedSpec
        }

        var spec: DockerControlPlane.SwarmSpec {
            let source = nestedSpec ?? [:]
            var result = DockerControlPlane.SwarmSpec(
                name: name ?? Self.stringValue(source["Name"]) ?? "",
                labels: labels ?? Self.stringMap(source["Labels"])
            )
            result.orchestration = Self.objectValue(source["Orchestration"])
            result.raft = Self.objectValue(source["Raft"])
            result.dispatcher = Self.objectValue(source["Dispatcher"])
            result.certificates = Self.objectValue(source["CAConfig"])
            result.encryption = Self.objectValue(source["EncryptionConfig"])
            return result
        }

        private static func objectValue(
            _ value: DockerControlPlane.JSONValue?
        ) -> [String: DockerControlPlane.JSONValue] {
            guard case .object(let value) = value else { return [:] }
            return value
        }

        private static func stringMap(
            _ value: DockerControlPlane.JSONValue?
        ) -> [String: String] {
            guard case .object(let values) = value else { return [:] }
            return values.reduce(into: [:]) { result, entry in
                if case .string(let string) = entry.value {
                    result[entry.key] = string
                }
            }
        }

        private static func stringValue(
            _ value: DockerControlPlane.JSONValue?
        ) -> String? {
            guard case .string(let value) = value else { return nil }
            return value
        }
    }

    private struct CreateResponse: Encodable {
        let ID: String
        let Warning: String = ""

        init(id: String) { ID = id }
    }

    private struct ServiceCreateResponse: Encodable {
        let ID: String
        let Warnings: [String]

        init(id: String, warnings: [String] = []) {
            ID = id
            Warnings = warnings
        }
    }

    private struct ObjectResponse: Encodable {
        let ID: String
        let Version: VersionResponse
        let CreatedAt: String
        let UpdatedAt: String
        let Spec: SpecResponse

        init(_ object: DockerControlPlane.Object, secret: Bool) {
            ID = object.id
            Version = .init(index: object.version)
            CreatedAt = Self.timestamp(object.createdAt)
            UpdatedAt = Self.timestamp(object.updatedAt)
            Spec = .init(object.spec, secret: secret)
        }

        private static func timestamp(_ date: Date) -> String {
            ISO8601DateFormatter().string(from: date)
        }
    }

    private struct SpecResponse: Encodable {
        let Name: String
        let Labels: [String: String]
        let Data: String?

        init(_ spec: DockerControlPlane.Spec, secret: Bool) {
            Name = spec.name
            Labels = spec.labels
            Data = secret ? nil : spec.data
        }
    }

    private struct VersionResponse: Encodable {
        let Index: UInt64

        init(index: UInt64) { Index = index }
    }

    private struct SwarmResponse: Encodable {
        let ID: String
        let Version: VersionResponse
        let CreatedAt: String
        let UpdatedAt: String
        let Spec: DockerControlPlane.SwarmSpec
        let TLSInfo: TLSInfoResponse?
        let RootRotationInProgress: Bool
        let DefaultAddrPool: [String]
        let SubnetSize: UInt32
        let DataPathPort: UInt32
        let JoinTokens: JoinTokensResponse
        let ManagerStatus: ManagerStatusResponse

        init(_ swarm: DockerControlPlane.Swarm) {
            ID = swarm.id
            Version = .init(index: swarm.version)
            CreatedAt = ISO8601DateFormatter().string(from: swarm.createdAt)
            UpdatedAt = ISO8601DateFormatter().string(from: swarm.updatedAt)
            Spec = swarm.spec
            TLSInfo = nil
            RootRotationInProgress = false
            DefaultAddrPool = []
            SubnetSize = 24
            DataPathPort = 4789
            JoinTokens = .init(worker: swarm.workerToken, manager: swarm.managerToken)
            ManagerStatus = .init(nodeID: swarm.nodeID)
        }
    }

    private struct SwarmInitResponse: Encodable {
        let NodeID: String
        let Error: String
        let Warning: String
        let UnlockKey: String
        let ManagerStatus: ManagerStatusResponse

        init(_ swarm: DockerControlPlane.Swarm) {
            NodeID = swarm.nodeID
            Error = ""
            Warning = ""
            UnlockKey = swarm.unlockKey
            ManagerStatus = .init(nodeID: swarm.nodeID)
        }
    }

    private struct JoinResponse: Encodable {
        let NodeID: String
    }

    private struct UnlockKeyResponse: Encodable {
        let UnlockKey: String
    }

    private struct JoinTokensResponse: Encodable {
        let Worker: String
        let Manager: String

        init(worker: String, manager: String) {
            Worker = worker
            Manager = manager
        }
    }

    private struct ManagerStatusResponse: Encodable {
        let Leader: Bool
        let Reachability: String
        let Addr: String
        let RemoteManagers: [String]

        init(nodeID: String) {
            Leader = true
            Reachability = "reachable"
            Addr = "127.0.0.1:2377"
            RemoteManagers = [nodeID]
        }
    }

    private struct TLSInfoResponse: Encodable {
        let TrustRoot: String
        let CertIssuerSubject: String
        let CertIssuerPublicKey: String
    }

    private struct WarningsResponse: Encodable {
        let Warnings: [String]

        init() { Warnings = [] }
    }

    private struct NodeResponse: Encodable {
        let ID: String
        let Version: VersionResponse
        let CreatedAt: String
        let UpdatedAt: String
        let Spec: [String: DockerControlPlane.JSONValue]
        let Description: [String: DockerControlPlane.JSONValue]
        let Status: [String: DockerControlPlane.JSONValue]
        let ManagerStatus: [String: DockerControlPlane.JSONValue]

        init(_ node: DockerControlPlane.Node) {
            ID = node.id
            Version = .init(index: node.version)
            CreatedAt = ISO8601DateFormatter().string(from: node.createdAt)
            UpdatedAt = ISO8601DateFormatter().string(from: node.updatedAt)
            Spec = node.spec
            Description = [
                "Hostname": .string("glassdock"),
                "Platform": .object(["Architecture": .string("arm64"), "OS": .string("linux")]),
                "Resources": .object([
                    "NanoCPUs": .number(Double(ProcessInfo.processInfo.activeProcessorCount) * 1_000_000_000),
                    "MemoryBytes": .number(Double(ProcessInfo.processInfo.physicalMemory)),
                ]),
                "Engine": .object(["EngineVersion": .string(getBuildVersion())]),
            ]
            Status = [
                "State": .string("ready"),
                "Addr": .string("127.0.0.1"),
            ]
            ManagerStatus = [
                "Leader": .bool(true),
                "Reachability": .string("reachable"),
                "Addr": .string("127.0.0.1:2377"),
            ]
        }
    }

    private struct ServiceResponse: Encodable {
        let ID: String
        let Version: VersionResponse
        let CreatedAt: String
        let UpdatedAt: String
        let Spec: [String: DockerControlPlane.JSONValue]
        let Endpoint: [String: DockerControlPlane.JSONValue]
        let UpdateStatus: DockerControlPlane.JSONValue?
        let ServiceStatus: [String: DockerControlPlane.JSONValue]?

        init(
            _ service: DockerControlPlane.Service,
            status: (running: UInt64, desired: UInt64, completed: UInt64)? = nil
        ) {
            ID = service.id
            Version = .init(index: service.version)
            CreatedAt = ISO8601DateFormatter().string(from: service.createdAt)
            UpdatedAt = ISO8601DateFormatter().string(from: service.updatedAt)
            Spec = service.spec
            let endpointSpec = service.spec["EndpointSpec"] ?? .object([:])
            let ports: DockerControlPlane.JSONValue
            if case .object(let endpoint) = endpointSpec, let configured = endpoint["Ports"] {
                ports = configured
            } else {
                ports = .array([])
            }
            Endpoint = ["Spec": endpointSpec, "Ports": ports, "VirtualIPs": .array([])]
            UpdateStatus = nil
            ServiceStatus = status.map {
                [
                    "RunningTasks": .number(Double($0.running)),
                    "DesiredTasks": .number(Double($0.desired)),
                    "CompletedTasks": .number(Double($0.completed)),
                ]
            }
        }
    }

    private struct ServiceUpdateResponse: Encodable {
        let Warnings: [String]
        let ID: String

        init(service: DockerControlPlane.Service) {
            Warnings = []
            ID = service.id
        }
    }

    private struct TaskResponse: Encodable {
        let ID: String
        let Version: VersionResponse
        let CreatedAt: String
        let UpdatedAt: String
        let Name: String
        let Labels: [String: String]
        let Spec: [String: DockerControlPlane.JSONValue]
        let ServiceAnnotations: [String: DockerControlPlane.JSONValue]
        let ServiceID: String
        let Slot: Int
        let NodeID: String
        let Status: [String: DockerControlPlane.JSONValue]
        let DesiredState: String

        init(_ task: DockerControlPlane.Task) {
            ID = task.id
            Version = .init(index: task.version)
            CreatedAt = ISO8601DateFormatter().string(from: task.createdAt)
            UpdatedAt = ISO8601DateFormatter().string(from: task.updatedAt)
            Name = "\(task.serviceID).\(task.slot ?? 1)"
            Labels = Self.labels(from: task.spec)
            Spec = task.spec
            ServiceAnnotations = [:]
            ServiceID = task.serviceID
            Slot = task.slot ?? 1
            NodeID = task.nodeID ?? ""
            var status: [String: DockerControlPlane.JSONValue] = [
                "Timestamp": .string(ISO8601DateFormatter().string(from: task.updatedAt)),
                "State": .string(task.state),
                "Message": .string(Self.message(for: task.state)),
            ]
            if let exitCode = task.exitCode {
                status["ContainerStatus"] = .object([
                    "ContainerID": .string(task.containerID ?? ""),
                    "PID": .number(0),
                    "ExitCode": .number(Double(exitCode)),
                ])
            } else if let containerID = task.containerID {
                status["ContainerStatus"] = .object([
                    "ContainerID": .string(containerID),
                    "PID": .number(0),
                    "ExitCode": .number(0),
                ])
            }
            if task.state == "failed" {
                status["Err"] = .string(Self.message(for: task.state))
            }
            Status = status
            DesiredState = "running"
        }

        private static func labels(from spec: [String: DockerControlPlane.JSONValue]) -> [String: String] {
            guard case .object(let containerSpec) = spec["ContainerSpec"],
                case .object(let labels) = containerSpec["Labels"]
            else { return [:] }
            return labels.reduce(into: [:]) { result, entry in
                if case .string(let value) = entry.value { result[entry.key] = value }
            }
        }

        private static func message(for state: String) -> String {
            switch state {
            case "new": return "service task is awaiting reconciliation"
            case "complete": return "service task completed in the guest runtime"
            case "failed": return "service task failed in the guest runtime"
            case "starting": return "service task is starting in the guest runtime"
            default: return "service task is running in the guest runtime"
            }
        }
    }

    private struct PluginPrivilege: Encodable {
        let Name: String
        let Description: String
        let Value: [String]

        init() {
            Name = "network"
            Description = "Glass Dock does not grant host network privileges to plugins."
            Value = []
        }
    }

    private struct PluginResponse: Encodable {
        let Id: String
        let Name: String
        let PluginReference: String
        let Enabled: Bool
        let Config: [String: DockerControlPlane.JSONValue]
        let Settings: [String: DockerControlPlane.JSONValue]
        let Version: VersionResponse
        let CreatedAt: String
        let UpdatedAt: String
        let Warnings: [String]

        init(_ plugin: DockerControlPlane.Plugin) {
            Id = plugin.id
            Name = plugin.name
            PluginReference = plugin.reference
            Enabled = plugin.enabled
            Config = plugin.config
            Settings = plugin.settings
            Version = .init(index: plugin.version)
            CreatedAt = ISO8601DateFormatter().string(from: plugin.createdAt)
            UpdatedAt = ISO8601DateFormatter().string(from: plugin.updatedAt)
            Warnings = [
                "Plugin execution is metadata-only; Glass Dock does not run Docker managed plugins."
            ]
        }
    }
}
