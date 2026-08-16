import Foundation
import NIOCore
import Vapor

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

    func joinSwarm(spec: SwarmSpec, token: String) -> Swarm? {
        if let swarm {
            guard token == swarm.workerToken || token == swarm.managerToken else { return nil }
            return swarm
        }
        guard token.contains("SWMTKN-") else { return nil }
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
    }

    func unlockSwarm(key: String) -> Bool {
        guard let swarm else { return false }
        return key == swarm.unlockKey
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
}

struct DockerControlPlaneRoutes: RouteCollection {
    let controlPlane: DockerControlPlane

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
        guard let swarm = await controlPlane.joinSwarm(spec: payload.spec, token: payload.token ?? "") else {
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

        enum CodingKeys: String, CodingKey {
            case name = "Name"
            case labels = "Labels"
            case token = "JoinToken"
            case unlockKey = "UnlockKey"
        }

        init(
            name: String? = nil,
            labels: [String: String]? = nil,
            token: String? = nil,
            unlockKey: String? = nil
        ) {
            self.name = name
            self.labels = labels
            self.token = token
            self.unlockKey = unlockKey
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
}
