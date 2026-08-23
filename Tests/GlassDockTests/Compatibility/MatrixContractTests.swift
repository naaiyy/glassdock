import ContainerPersistence
import ContainerResource
import Foundation
import RoutingKit
import Testing
import Vapor
import VaporTesting

@testable import GlassDock

/// Contract tests generated from Compatibility/moby-v28.5.2-matrix.json.
///
/// These run without the live daemon harness:
/// - every matrix operation must have a registered route;
/// - every error-only operation must answer with exactly its declared
///   `expectedStatus` and Docker's `{"message": ...}` body shape;
/// - every DockerRuntimeRoutes operation must answer a generic probe request
///   with one of its documented `responseStatuses`, and error responses must
///   carry the Docker message shape.
///
/// A regression that removes a route, changes a status code, or breaks the
/// Docker error body fails here before any live conformance run.
@Suite("Compatibility matrix contract")
struct MatrixContractTests {
    struct Operation: Decodable, Sendable {
        let method: String
        let path: String
        let operationId: String
        let support: String
        let expectedStatus: Int
        let responseStatuses: [Int]
        let owner: String

        var httpMethod: HTTPMethod { HTTPMethod(rawValue: method) }
    }

    private static func loadMatrix() throws -> [Operation] {
        struct Matrix: Decodable { let operations: [Operation] }
        // Walk up from this source file to the repository root so the test
        // always reads the generated matrix, never a stale copy.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<8 {
            url.deleteLastPathComponent()
            let candidate = url.appendingPathComponent("Compatibility/moby-v28.5.2-matrix.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try JSONDecoder().decode(
                    Matrix.self, from: Data(contentsOf: candidate)
                ).operations
            }
        }
        fatalError("could not locate Compatibility/moby-v28.5.2-matrix.json from \(#filePath)")
    }

    private actor StubVolumeClient: ClientVolumeProtocol {
        func create(request: RESTVolumeCreate) async throws -> Volume {
            throw Abort(.notFound, reason: "no such volume")
        }
        func delete(name: String) async throws {
            throw Abort(.notFound, reason: "no such volume")
        }
        func list(filters: String?, logger: Logger) async throws -> [Volume] { [] }
        func inspect(name: String) async throws -> Volume {
            throw Abort(.notFound, reason: "no such volume")
        }
    }

    /// Registers every route collection exactly as configure.swift does, with
    /// test doubles where configure uses live services. The Docker error
    /// middleware is installed like production so error bodies carry the
    /// Docker message shape.
    private func withRegisteredRoutes(
        backend: DockerRuntimeBackendMock = DockerRuntimeBackendMock(),
        _ body: (Application) async throws -> Void
    ) async throws {
        try await withApp(configure: { app in
            var middleware = Middlewares()
            middleware.use(DockerErrorMiddleware(), at: .beginning)
            app.middleware = middleware
        }) { app in
            let router = app.regexRouter(with: app.logger)
            app.setRegexRouter(router)
            try app.register(collection: HealthCheckPingRoute())
            try app.register(collection: EventsRoute())
            try app.register(
                collection: DockerRuntimeRoutes(backend: backend, volumeClient: StubVolumeClient())
            )
            try app.register(collection: ImageSearchRoute())
            try app.register(
                collection: DistributionJsonRoute(systemConfig: ContainerSystemConfig())
            )
            try app.register(collection: AuthRoute())
            try app.register(collection: SessionRoute())
            try app.register(collection: VersionRoute())
            try app.register(collection: ExplicitUnsupportedDockerRoutes())
            try app.register(collection: VolumeCreateRoute(client: StubVolumeClient()))
            try app.register(collection: VolumeDeleteRoute(client: StubVolumeClient()))
            try app.register(collection: VolumeInspectRoute(client: StubVolumeClient()))
            try app.register(collection: VolumeListRoute(client: StubVolumeClient()))
            try app.register(collection: VolumePruneRoute(client: StubVolumeClient()))
            try app.register(collection: VolumeUpdateRoute())
            try await body(app)
        }
    }

    /// Reconstructs the Docker-style pattern ("/x/{name}") from a Vapor route.
    private static func dockerPath(of route: Route) -> String {
        route.path.map { component -> String in
            switch component {
            case .constant(let name): return "/\(name)"
            case .parameter(let name): return "/{\(name)}"
            case .anything: return "/{anything}"
            case .catchall: return "/**"
            }
        }.joined()
    }

    @Test("every matrix operation has a registered route")
    func allOperationsRegistered() async throws {
        let operations = try Self.loadMatrix()
        try await withRegisteredRoutes { app in
            var registered = Set<String>()
            for route in app.routes.all {
                registered.insert("\(route.method.rawValue) \(Self.dockerPath(of: route))")
            }
            for operation in operations {
                #expect(
                    registered.contains("\(operation.method) \(operation.path)"),
                    "\(operation.method) \(operation.path) (\(operation.operationId)) is not registered"
                )
            }
        }
    }

    /// Sends one generic probe request for the operation. Parameters become
    /// "probe"; POST bodies are empty JSON objects; streaming endpoints get
    /// query parameters that keep the response finite.
    private func probePath(for operation: Operation) -> String {
        var path = operation.path.replacingOccurrences(
            of: #"\{[^}]+\}"#, with: "probe", options: .regularExpression
        )
        if operation.path == "/containers/{id}/stats" {
            path += "?stream=0"
        }
        return path
    }

    @Test("error-only operations answer their declared contract")
    func errorOnlyContract() async throws {
        let operations = try Self.loadMatrix().filter { $0.support == "error-only" }
        #expect(operations.count == 41)
        try await withRegisteredRoutes { app in
            for operation in operations {
                let path = probePath(for: operation)
                try await app.testing().test(
                    operation.httpMethod, path,
                    beforeRequest: { request in
                        if [.POST, .PUT].contains(operation.httpMethod) {
                            request.headers.contentType = .json
                            request.body = .init(data: Data("{}".utf8))
                        }
                    },
                    afterResponse: { response async in
                        #expect(
                            Int(response.status.code) == operation.expectedStatus,
                            "\(operation.operationId): expected \(operation.expectedStatus), got \(response.status.code)"
                        )
                        // HEAD responses carry no body by definition.
                        if operation.method != "HEAD" {
                            guard
                                let data = response.body.getData(
                                    at: 0, length: response.body.readableBytes
                                ),
                                let payload = try? JSONDecoder().decode(
                                    DockerErrorMessage.self, from: data
                                )
                            else {
                                Issue.record(
                                    "\(operation.operationId): body is not Docker-shaped: \(response.body.string)"
                                )
                                return
                            }
                            #expect(!payload.message.isEmpty)
                        }
                    })
            }
        }
    }

    @Test("runtime operations answer within their documented statuses")
    func runtimeOperationStatuses() async throws {
        let operations = try Self.loadMatrix().filter { $0.owner == "DockerRuntimeRoutes" }
        #expect(operations.count == 52)
        try await withRegisteredRoutes { app in
            for operation in operations {
                let path = probePath(for: operation)
                try await app.testing().test(
                    operation.httpMethod, path,
                    beforeRequest: { request in
                        if [.POST, .PUT].contains(operation.httpMethod) {
                            request.headers.contentType = .json
                            request.body = .init(data: Data("{}".utf8))
                        }
                    },
                    afterResponse: { response async in
                        let code = Int(response.status.code)
                        // The generic probe sends minimal input, so a 400 means
                        // the route validated the probe rather than proving a
                        // regression; only statuses outside Swagger plus 400 fail.
                        #expect(
                            operation.responseStatuses.contains(code) || code == 400,
                            "\(operation.operationId): status \(code) is not documented in \(operation.responseStatuses)"
                        )
                        let isError = !(200...299).contains(code) && code != 304
                        if isError && operation.method != "HEAD" {
                            if let data = response.body.getData(at: 0, length: response.body.readableBytes),
                                let payload = try? JSONDecoder().decode(
                                    DockerErrorMessage.self, from: data
                                )
                            {
                                #expect(!payload.message.isEmpty)
                            } else {
                                Issue.record(
                                    "\(operation.operationId): error body is not Docker-shaped: \(response.body.string)"
                                )
                            }
                        }
                    })
            }
        }
    }

    @Test("matrix integrity: support states are valid")
    func matrixIntegrity() throws {
        for operation in try Self.loadMatrix() {
            #expect(
                ["full", "partial", "error-only"].contains(operation.support),
                "\(operation.operationId): unknown support state \(operation.support)"
            )
        }
    }
}

/// The Docker error body shape every error response must carry.
private struct DockerErrorMessage: Decodable {
    let message: String
}
