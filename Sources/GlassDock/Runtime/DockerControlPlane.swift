import Foundation
import NIOCore
import Vapor

protocol DockerControlPlaneRuntime: Sendable {
    func createContainer(_ request: DockerRuntimeContainerCreate) async throws -> DockerRuntimeContainer
    func startContainer(id: String) async throws
    func deleteContainer(id: String, force: Bool, removeVolumes: Bool) async throws
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

    struct Swarm: Sendable, Equatable {
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
    }

    struct Node: Sendable, Equatable {
        let id: String
        let version: UInt64
        let createdAt: Date
        let updatedAt: Date
        let spec: [String: JSONValue]
    }

    struct Service: Sendable, Equatable {
        let id: String
        let version: UInt64
        let createdAt: Date
        let updatedAt: Date
        let spec: [String: JSONValue]
        let taskID: String
    }

    struct Task: Sendable, Equatable {
        let id: String
        let version: UInt64
        let createdAt: Date
        let updatedAt: Date
        let serviceID: String
        let spec: [String: JSONValue]
        let state: String
        let containerID: String?
    }

    struct Plugin: Sendable, Equatable {
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

    private struct StoredObject: Sendable {
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

    func createConfig(spec: Spec) -> Object {
        create(spec: spec, in: &configs)
    }

    func listConfigs(filters: [String: [String]]?) -> [Object] {
        list(in: configs, filters: filters)
    }

    func inspectConfig(id: String) -> Object? {
        object(in: configs, id: id)
    }

    func updateConfig(id: String, spec: Spec) -> Object? {
        update(id: id, spec: spec, in: &configs)
    }

    func deleteConfig(id: String) -> Bool {
        configs.removeValue(forKey: resolve(id, in: configs)) != nil
    }

    func createSecret(spec: Spec) -> Object {
        create(spec: spec, in: &secrets)
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
        return Object(
            id: object.id,
            version: object.version,
            createdAt: object.createdAt,
            updatedAt: object.updatedAt,
            spec: Spec(name: object.spec.name, labels: object.spec.labels)
        )
    }

    func deleteSecret(id: String) -> Bool {
        secrets.removeValue(forKey: resolve(id, in: secrets)) != nil
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
        return updated
    }

    func leaveSwarm() {
        swarm = nil
        nodeVersion = 1
        nodeSpec = [:]
        services.removeAll()
        tasks.removeAll()
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
        return updated
    }

    func removeNode(id: String) -> Bool {
        guard inspectNode(id: id) != nil else { return false }
        leaveSwarm()
        return true
    }

    func createService(spec: [String: JSONValue]) -> Service? {
        guard swarm != nil else { return nil }
        let now = Date()
        let serviceID = Self.identifier()
        let taskID = Self.identifier()
        let service = Service(
            id: serviceID,
            version: 1,
            createdAt: now,
            updatedAt: now,
            spec: spec,
            taskID: taskID
        )
        let taskSpec: [String: JSONValue] = {
            guard case .object(let value) = spec["TaskTemplate"] else { return [:] }
            return value
        }()
        let task = Task(
            id: taskID,
            version: 1,
            createdAt: now,
            updatedAt: now,
            serviceID: serviceID,
            spec: taskSpec,
            state: "new",
            containerID: nil
        )
        services[serviceID] = service
        tasks[taskID] = task
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
        let updated = Service(
            id: current.id,
            version: current.version + 1,
            createdAt: current.createdAt,
            updatedAt: Date(),
            spec: spec,
            taskID: current.taskID
        )
        services[resolved] = updated
        return updated
    }

    func removeService(id: String) -> Bool {
        let resolved = resolveServiceID(id)
        guard let service = services.removeValue(forKey: resolved) else { return false }
        tasks.removeValue(forKey: service.taskID)
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
            containerID: containerID
        )
        return true
    }

    func taskContainerID(id: String) -> String? {
        tasks[resolveTaskID(id)]?.containerID
    }

    func listPlugins() -> [Plugin] {
        plugins.values.sorted { $0.name < $1.name }
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
        return plugin
    }

    func pullPlugin(name: String, reference: String) -> Plugin {
        createPlugin(name: name, reference: reference)
    }

    func deletePlugin(name: String) -> Bool {
        plugins.removeValue(forKey: resolvePluginName(name)) != nil
    }

    func setPluginEnabled(name: String, enabled: Bool) -> Plugin? {
        let resolved = resolvePluginName(name)
        guard var plugin = plugins[resolved] else { return nil }
        plugin.enabled = enabled
        plugin.updatedAt = Date()
        plugin.version += 1
        plugins[resolved] = plugin
        return plugin
    }

    func setPluginSettings(name: String, settings: [String: JSONValue]) -> Plugin? {
        let resolved = resolvePluginName(name)
        guard var plugin = plugins[resolved] else { return nil }
        plugin.settings = settings
        plugin.updatedAt = Date()
        plugin.version += 1
        plugins[resolved] = plugin
        return plugin
    }

    func upgradePlugin(name: String, reference: String?) -> Plugin? {
        let resolved = resolvePluginName(name)
        guard var plugin = plugins[resolved] else { return nil }
        if let reference, !reference.isEmpty { plugin.reference = reference }
        plugin.updatedAt = Date()
        plugin.version += 1
        plugins[resolved] = plugin
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
        if let desiredStates = filters["desired-state"], !desiredStates.isEmpty,
            !desiredStates.contains("running")
        {
            return false
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

    private static func identifier() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
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
        let object = await controlPlane.createConfig(spec: spec)
        return try jsonResponse(.created, CreateResponse(id: object.id))
    }

    private func listConfigs(_ req: Request) async throws -> Response {
        let objects = await controlPlane.listConfigs(filters: filters(req))
        return try jsonResponse(.ok, objects.map { ObjectResponse($0, secret: false) })
    }

    private func inspectConfig(_ req: Request) async throws -> Response {
        let object = await controlPlane.inspectConfig(id: try parameter("id", req))
        guard let object else { throw Abort(.notFound, reason: "config not found") }
        return try jsonResponse(.ok, ObjectResponse(object, secret: false))
    }

    private func updateConfig(_ req: Request) async throws -> Response {
        let object = await controlPlane.updateConfig(
            id: try parameter("id", req), spec: try await decodeSpec(req, secret: false)
        )
        guard let object else { throw Abort(.notFound, reason: "config not found") }
        return try jsonResponse(.ok, ObjectResponse(object, secret: false))
    }

    private func deleteConfig(_ req: Request) async throws -> Response {
        guard await controlPlane.deleteConfig(id: try parameter("id", req)) else {
            throw Abort(.notFound, reason: "config not found")
        }
        return Response(status: .noContent)
    }

    private func createSecret(_ req: Request) async throws -> Response {
        let spec = try await decodeSpec(req, secret: true)
        let object = await controlPlane.createSecret(spec: spec)
        return try jsonResponse(.created, CreateResponse(id: object.id))
    }

    private func listSecrets(_ req: Request) async throws -> Response {
        let objects = await controlPlane.listSecrets(filters: filters(req))
        return try jsonResponse(.ok, objects.map { ObjectResponse($0, secret: true) })
    }

    private func inspectSecret(_ req: Request) async throws -> Response {
        let object = await controlPlane.inspectSecret(id: try parameter("id", req))
        guard let object else { throw Abort(.notFound, reason: "secret not found") }
        return try jsonResponse(.ok, ObjectResponse(object, secret: true))
    }

    private func updateSecret(_ req: Request) async throws -> Response {
        let object = await controlPlane.updateSecret(
            id: try parameter("id", req), spec: try await decodeSpec(req, secret: true)
        )
        guard let object else { throw Abort(.notFound, reason: "secret not found") }
        return try jsonResponse(.ok, ObjectResponse(object, secret: true))
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
        await controlPlane.leaveSwarm()
        return Response(status: .noContent)
    }

    private func unlockSwarm(_ req: Request) async throws -> Response {
        let payload = try await decodeSwarmRequest(req)
        guard await controlPlane.unlockSwarm(key: payload.unlockKey ?? "") else {
            throw Abort(.unauthorized, reason: "swarm unlock key is invalid")
        }
        return Response(status: .noContent)
    }

    private func unlockKey(_ req: Request) async throws -> Response {
        guard let swarm = await controlPlane.currentSwarm() else {
            throw Abort(.serviceUnavailable, reason: "This node is not a swarm manager")
        }
        return try jsonResponse(.ok, swarm.unlockKey)
    }

    private func updateSwarm(_ req: Request) async throws -> Response {
        let payload = try await decodeSwarmRequest(req)
        guard await controlPlane.updateSwarm(spec: payload.spec) != nil else {
            throw Abort(.serviceUnavailable, reason: "This node is not a swarm manager")
        }
        return Response(status: .noContent)
    }

    private func listNodes(_ req: Request) async throws -> Response {
        guard await controlPlane.currentSwarm() != nil else {
            throw Abort(.serviceUnavailable, reason: "This node is not a swarm manager")
        }
        let nodes = await controlPlane.listNodes(filters: filters(req))
        return try jsonResponse(.ok, nodes.map(NodeResponse.init))
    }

    private func inspectNode(_ req: Request) async throws -> Response {
        let node = await controlPlane.inspectNode(id: try parameter("id", req))
        guard let node else { throw Abort(.notFound, reason: "node not found") }
        return try jsonResponse(.ok, NodeResponse(node))
    }

    private func updateNode(_ req: Request) async throws -> Response {
        let node = await controlPlane.updateNode(
            id: try parameter("id", req), spec: try await decodeObject(req, message: "node specification")
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
            throw Abort(.serviceUnavailable, reason: "This node is not a swarm manager")
        }
        guard let runtime else {
            _ = await controlPlane.removeService(id: service.id)
            throw Abort(.serviceUnavailable, reason: "service scheduler is unavailable")
        }
        do {
            let container = try await runtime.createContainer(
                try containerRequest(serviceName: name, specification: spec)
            )
            do {
                try await runtime.startContainer(id: container.id)
            } catch {
                try? await runtime.deleteContainer(id: container.id, force: true, removeVolumes: true)
                throw error
            }
            guard
                await controlPlane.attachTaskContainer(
                    taskID: service.taskID, containerID: container.id
                )
            else {
                throw Abort(.internalServerError, reason: "service task was not retained")
            }
        } catch let abort as Abort {
            _ = await controlPlane.removeService(id: service.id)
            throw abort
        } catch {
            _ = await controlPlane.removeService(id: service.id)
            throw Abort(.serviceUnavailable, reason: "service task could not be started: \(error)")
        }
        return try jsonResponse(.created, CreateResponse(id: service.id))
    }

    private func listServices(_ req: Request) async throws -> Response {
        guard await controlPlane.currentSwarm() != nil else {
            throw Abort(.serviceUnavailable, reason: "This node is not a swarm manager")
        }
        let services = await controlPlane.listServices(filters: filters(req))
        return try jsonResponse(.ok, services.map(ServiceResponse.init))
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
        let oldContainerID = await controlPlane.taskContainerID(id: current.taskID)
        guard case .string(let name) = specification["Name"], !name.isEmpty else {
            throw Abort(.badRequest, reason: "service Name is required")
        }

        let replacement: DockerRuntimeContainer
        do {
            replacement = try await runtime.createContainer(
                try containerRequest(serviceName: name, specification: specification)
            )
            do {
                try await runtime.startContainer(id: replacement.id)
            } catch {
                try? await runtime.deleteContainer(id: replacement.id, force: true, removeVolumes: true)
                throw error
            }
            guard let service = await controlPlane.updateService(id: serviceID, spec: specification) else {
                try? await runtime.deleteContainer(id: replacement.id, force: true, removeVolumes: true)
                throw Abort(.notFound, reason: "service not found")
            }
            guard await controlPlane.attachTaskContainer(taskID: service.taskID, containerID: replacement.id) else {
                try? await runtime.deleteContainer(id: replacement.id, force: true, removeVolumes: true)
                throw Abort(.internalServerError, reason: "service task was not retained")
            }
            if let oldContainerID, oldContainerID != replacement.id {
                try await runtime.deleteContainer(id: oldContainerID, force: true, removeVolumes: true)
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
        if let containerID = await controlPlane.taskContainerID(id: service.taskID) {
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
        return try await logsResponse(taskID: service.taskID, request: req)
    }

    private func listTasks(_ req: Request) async throws -> Response {
        guard await controlPlane.currentSwarm() != nil else {
            throw Abort(.serviceUnavailable, reason: "This node is not a swarm manager")
        }
        let tasks = await controlPlane.listTasks(filters: filters(req))
        return try jsonResponse(.ok, tasks.map(TaskResponse.init))
    }

    private func inspectTask(_ req: Request) async throws -> Response {
        let task = await controlPlane.inspectTask(id: try parameter("id", req))
        guard let task else { throw Abort(.notFound, reason: "task not found") }
        return try jsonResponse(.ok, TaskResponse(task))
    }

    private func taskLogs(_ req: Request) async throws -> Response {
        let taskID = try parameter("id", req)
        guard await controlPlane.inspectTask(id: taskID) != nil else {
            throw Abort(.notFound, reason: "task not found")
        }
        return try await logsResponse(taskID: taskID, request: req)
    }

    private func listPlugins(_ req: Request) async throws -> Response {
        try jsonResponse(.ok, await controlPlane.listPlugins().map(PluginResponse.init))
    }

    private func pluginPrivileges(_ req: Request) async throws -> Response {
        try jsonResponse(.ok, [PluginPrivilege]())
    }

    private func createPlugin(_ req: Request) async throws -> Response {
        throw Abort(.notImplemented, reason: "Docker plugins require an unavailable plugin manager")
    }

    private func pullPlugin(_ req: Request) async throws -> Response {
        throw Abort(.notImplemented, reason: "Docker plugins require an unavailable plugin manager")
    }

    private func inspectPlugin(_ req: Request) async throws -> Response {
        let plugin = await controlPlane.inspectPlugin(name: try parameter("name", req))
        guard let plugin else { throw Abort(.notFound, reason: "plugin not found") }
        return try jsonResponse(.ok, PluginResponse(plugin))
    }

    private func disablePlugin(_ req: Request) async throws -> Response {
        throw Abort(.notImplemented, reason: "Docker plugins require an unavailable plugin manager")
    }

    private func enablePlugin(_ req: Request) async throws -> Response {
        throw Abort(.notImplemented, reason: "Docker plugins require an unavailable plugin manager")
    }

    private func pushPlugin(_ req: Request) async throws -> Response {
        throw Abort(.notImplemented, reason: "Docker plugins require an unavailable plugin manager")
    }

    private func setPlugin(_ req: Request) async throws -> Response {
        let settings = try await decodeObject(req, message: "plugin settings")
        let plugin = await controlPlane.setPluginSettings(
            name: try parameter("name", req), settings: settings
        )
        guard let plugin else { throw Abort(.notFound, reason: "plugin not found") }
        return try jsonResponse(.ok, PluginResponse(plugin))
    }

    private func upgradePlugin(_ req: Request) async throws -> Response {
        throw Abort(.notImplemented, reason: "Docker plugins require an unavailable plugin manager")
    }

    private func deletePlugin(_ req: Request) async throws -> Response {
        guard await controlPlane.deletePlugin(name: try parameter("name", req)) else {
            throw Abort(.notFound, reason: "plugin not found")
        }
        return try jsonResponse(.ok, WarningsResponse())
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
        guard let buffer = try await req.body.collect(max: req.application.routes.defaultMaxBodySize.value).get(),
            let data = buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes),
            allowEmpty || !data.isEmpty
        else {
            throw Abort(.badRequest, reason: "Request body is required")
        }
        return data
    }

    private func filters(_ req: Request) -> [String: [String]]? {
        guard let raw = req.query[String.self, at: "filters"],
            let data = raw.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode([String: [String]].self, from: data)
    }

    private func parameter(_ name: String, _ req: Request) throws -> String {
        guard let value = req.parameters.get(name), !value.isEmpty else {
            throw Abort(.badRequest, reason: "Missing (name)")
        }
        return value
    }

    private func jsonResponse<T: Encodable>(_ status: HTTPResponseStatus, _ value: T) throws -> Response {
        let response = Response(status: status, body: .init(data: try JSONEncoder().encode(value)))
        response.headers.contentType = .json
        return response
    }

    private func logsResponse(taskID: String, request: Request) async throws -> Response {
        guard let runtime else {
            throw Abort(.serviceUnavailable, reason: "service scheduler is unavailable")
        }
        guard let containerID = await controlPlane.taskContainerID(id: taskID) else {
            throw Abort(.serviceUnavailable, reason: "service task has not been scheduled")
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
            let stream = try await runtime.streamLogs(
                id: containerID, stdout: stdout, stderr: stderr, options: options
            )
            let response = Response(
                status: .ok,
                body: .init(managedAsyncStream: { writer in
                    for try await frame in stream {
                        let data = Self.rawStreamFrame(
                            frame.data, stream: frame.stream == .stderr ? 2 : 1
                        )
                        try await writer.writeBuffer(ByteBuffer(data: data))
                    }
                })
            )
            response.headers.contentType = HTTPMediaType(
                type: "application", subType: "vnd.docker.raw-stream"
            )
            return response
        }
        var output = try await runtime.logs(
            id: containerID, stdout: stdout, stderr: stderr, options: options
        )
        if let tail = request.query[String.self, at: "tail"] {
            output = try Self.applyTail(output, value: tail)
        }
        var data = Data()
        if stdout { data.append(Self.rawStreamFrame(output.stdout, stream: 1)) }
        if stderr { data.append(Self.rawStreamFrame(output.stderr, stream: 2)) }
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
            mounts: mounts,
            ports: []
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

        enum CodingKeys: String, CodingKey {
            case name = "Name"
            case labels = "Labels"
            case token = "JoinToken"
            case unlockKey = "UnlockKey"
            case remoteAddresses = "RemoteAddrs"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            labels = try container.decodeIfPresent([String: String].self, forKey: .labels)
            token = try container.decodeIfPresent(String.self, forKey: .token)
            unlockKey = try container.decodeIfPresent(String.self, forKey: .unlockKey)
            remoteAddresses = try container.decodeIfPresent([String].self, forKey: .remoteAddresses) ?? []
        }

        init(
            name: String? = nil,
            labels: [String: String]? = nil,
            token: String? = nil,
            unlockKey: String? = nil,
            remoteAddresses: [String] = []
        ) {
            self.name = name
            self.labels = labels
            self.token = token
            self.unlockKey = unlockKey
            self.remoteAddresses = remoteAddresses
        }

        var spec: DockerControlPlane.SwarmSpec {
            .init(name: name ?? "", labels: labels ?? [:])
        }
    }

    private struct CreateResponse: Encodable {
        let Id: String
        let Warning: String = ""

        init(id: String) { Id = id }
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

        init(_ service: DockerControlPlane.Service) {
            ID = service.id
            Version = .init(index: service.version)
            CreatedAt = ISO8601DateFormatter().string(from: service.createdAt)
            UpdatedAt = ISO8601DateFormatter().string(from: service.updatedAt)
            Spec = service.spec
            Endpoint = [:]
            UpdateStatus = nil
        }
    }

    private struct ServiceUpdateResponse: Encodable {
        let Warnings: [String]
        let ID: String

        init(service: DockerControlPlane.Service) {
            Warnings = ["Service tasks remain in the pending state until a compatible scheduler is available."]
            ID = service.id
        }
    }

    private struct TaskResponse: Encodable {
        let ID: String
        let Version: VersionResponse
        let CreatedAt: String
        let UpdatedAt: String
        let Spec: [String: DockerControlPlane.JSONValue]
        let ServiceAnnotations: [String: DockerControlPlane.JSONValue]
        let Status: [String: DockerControlPlane.JSONValue]
        let DesiredState: String

        init(_ task: DockerControlPlane.Task) {
            ID = task.id
            Version = .init(index: task.version)
            CreatedAt = ISO8601DateFormatter().string(from: task.createdAt)
            UpdatedAt = ISO8601DateFormatter().string(from: task.updatedAt)
            Spec = task.spec
            ServiceAnnotations = [:]
            Status = [
                "Timestamp": .string(ISO8601DateFormatter().string(from: task.updatedAt)),
                "State": .string(task.state),
                "Message": .string(
                    task.containerID == nil
                        ? "service task is awaiting a compatible scheduler"
                        : "service task is running in the guest runtime"
                ),
            ]
            DesiredState = "running"
        }
    }

    private struct PluginPrivilege: Encodable {
        let Name: String
        let Description: String

        init() {
            Name = "network"
            Description = "Glass Dock does not grant host network privileges to plugins."
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
