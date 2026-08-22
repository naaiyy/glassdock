import Foundation
import Testing
import Vapor
import VaporTesting

@testable import GlassDock

@Suite("Explicit unsupported Docker control-plane routes")
struct ExplicitUnsupportedRoutesTests {
    private static let swarmManagerMessage =
        #"This node is not a swarm manager. Use "docker swarm init" or "docker swarm join" to connect this node to swarm and try again."#
    private static let noSwarmMessage = "This node is not part of a swarm"

    private func withRoutes(_ body: (Application) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        app.middleware.use(DockerErrorMiddleware(), at: .beginning)
        let router = app.regexRouter(with: app.logger)
        app.setRegexRouter(router)
        try app.register(collection: ExplicitUnsupportedDockerRoutes())
        do {
            try await body(app)
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    @Test("swarm manager operations return Moby's 503 not-a-swarm-manager error")
    func swarmManagerOperations() async throws {
        let routes: [(HTTPMethod, String)] = [
            (.GET, "/v1.51/swarm"),
            (.POST, "/v1.51/swarm/init"),
            (.POST, "/v1.51/swarm/join"),
            (.POST, "/v1.51/swarm/update"),
            (.POST, "/v1.51/swarm/unlock"),
            (.GET, "/v1.51/swarm/unlockkey"),
            (.GET, "/v1.51/nodes"),
            (.GET, "/v1.51/nodes/node-1"),
            (.POST, "/v1.51/nodes/node-1/update"),
            (.DELETE, "/v1.51/nodes/node-1"),
            (.GET, "/v1.51/services"),
            (.POST, "/v1.51/services/create"),
            (.GET, "/v1.51/services/service-1"),
            (.POST, "/v1.51/services/service-1/update"),
            (.GET, "/v1.51/services/service-1/logs"),
            (.DELETE, "/v1.51/services/service-1"),
            (.GET, "/v1.51/tasks"),
            (.GET, "/v1.51/tasks/task-1"),
            (.GET, "/v1.51/tasks/task-1/logs"),
            (.GET, "/v1.51/secrets"),
            (.POST, "/v1.51/secrets/create"),
            (.GET, "/v1.51/secrets/secret-1"),
            (.POST, "/v1.51/secrets/secret-1/update"),
            (.DELETE, "/v1.51/secrets/secret-1"),
            (.GET, "/v1.51/configs"),
            (.POST, "/v1.51/configs/create"),
            (.GET, "/v1.51/configs/config-1"),
            (.POST, "/v1.51/configs/config-1/update"),
            (.DELETE, "/v1.51/configs/config-1"),
        ]
        try await withRoutes { app in
            for (method, path) in routes {
                try await app.testing().test(method, path) { response async throws in
                    #expect(response.status == .serviceUnavailable)
                    let value =
                        try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
                    #expect((value?["message"] as? String) == Self.swarmManagerMessage)
                }
            }
        }
    }

    @Test("leaving an uninitialized swarm returns Moby's 503 not-part-of-a-swarm error")
    func swarmLeave() async throws {
        try await withRoutes { app in
            try await app.testing().test(.POST, "/v1.51/swarm/leave") { response async throws in
                #expect(response.status == .serviceUnavailable)
                let value =
                    try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
                #expect((value?["message"] as? String) == Self.noSwarmMessage)
            }
        }
    }

    @Test("plugin listing returns an empty array like a fresh daemon")
    func pluginListIsEmpty() async throws {
        try await withRoutes { app in
            try await app.testing().test(.GET, "/v1.51/plugins") { response async throws in
                #expect(response.status == .ok)
                let value = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String]
                #expect(value?.isEmpty == true)
            }
        }
    }

    @Test("plugin operations on uninstalled plugins return Moby's 404 plugin-not-found error")
    func pluginNotFound() async throws {
        try await withRoutes { app in
            try await app.testing().test(.GET, "/v1.51/plugins/example/json") { response async throws in
                #expect(response.status == .notFound)
                let value =
                    try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
                #expect((value?["message"] as? String) == #"plugin "example" not found"#)
            }
            let routes: [(HTTPMethod, String)] = [
                (.POST, "/v1.51/plugins/example/enable"),
                (.POST, "/v1.51/plugins/example/disable"),
                (.POST, "/v1.51/plugins/example/push"),
                (.POST, "/v1.51/plugins/example/set"),
                (.POST, "/v1.51/plugins/example/upgrade"),
                (.DELETE, "/v1.51/plugins/example"),
            ]
            for (method, path) in routes {
                try await app.testing().test(method, path) { response async throws in
                    #expect(response.status == .notFound)
                    let value =
                        try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
                    #expect((value?["message"] as? String) == #"plugin "example" not found"#)
                }
            }
        }
    }

    @Test("plugin pull and privileges report the missing remote plugin")
    func pluginPullMissing() async throws {
        let paths: [(HTTPMethod, String)] = [
            (.POST, "/v1.51/plugins/pull?remote=example.test%2Ftool%3A1"),
            (.GET, "/v1.51/plugins/privileges?remote=example"),
            (.POST, "/v1.51/plugins/create?name=example"),
        ]
        try await withRoutes { app in
            for (method, path) in paths {
                try await app.testing().test(method, path) { response async throws in
                    #expect(response.status == .notFound)
                    let value =
                        try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
                    #expect((value?["message"] as? String)?.hasPrefix("plugin ") == true)
                    #expect((value?["message"] as? String)?.hasSuffix("not found") == true)
                }
            }
        }
    }
}
