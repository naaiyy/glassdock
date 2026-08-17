import Foundation
import NIOCore
import Testing
import Vapor
import VaporTesting

@testable import GlassDock

@Suite("Plugin-compatible control-plane routes")
struct PluginControlPlaneRoutesTests {
    @Test("plugin mutations persist Docker-compatible metadata")
    func pluginLifecycle() async throws {
        let controlPlane = DockerControlPlane()
        try await withApp(configure: { _ in }) { app in
            let router = app.regexRouter(with: app.logger)
            app.setRegexRouter(router)
            try app.register(collection: DockerControlPlaneRoutes(controlPlane: controlPlane))

            try await app.testing().test(
                .POST,
                "/v1.51/plugins/create?name=demo",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: #"{"Name":"demo","Description":"local"}"#)
            ) { response async in
                #expect(response.status == .noContent)
            }
            try await app.testing().test(.GET, "/v1.51/plugins") { response async throws in
                #expect(response.status == .ok)
                let value = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [[String: Any]]
                #expect(value?.count == 1)
            }
            try await app.testing().test(.GET, "/v1.51/plugins/demo/json") { response async in
                #expect(response.status == .ok)
            }
            try await app.testing().test(.GET, "/v1.51/plugins/privileges") { response async throws in
                #expect(response.status == .ok)
                let value = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [[String: Any]]
                #expect(value?.count == 1)
            }
            try await app.testing().test(.POST, "/v1.51/plugins/demo/enable") { response async in
                #expect(response.status == .ok)
            }
            try await app.testing().test(
                .POST,
                "/v1.51/plugins/demo/set",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: #"{"Env":["MODE=local"]}"#)
            ) { response async in
                #expect(response.status == .noContent)
            }
            try await app.testing().test(.POST, "/v1.51/plugins/demo/push") { response async in
                #expect(response.status == .ok)
            }
            try await app.testing().test(
                .POST,
                "/v1.51/plugins/demo/upgrade?remote=demo:v2"
            ) { response async in
                #expect(response.status == .noContent)
            }
            try await app.testing().test(.POST, "/v1.51/plugins/demo/disable") { response async in
                #expect(response.status == .ok)
            }
            try await app.testing().test(
                .POST,
                "/v1.51/plugins/pull?remote=other/plugin:latest&name=other"
            ) { response async in
                #expect(response.status == .noContent)
            }
            try await app.testing().test(.DELETE, "/v1.51/plugins/demo") { response async in
                #expect(response.status == .ok)
            }
        }
    }
}
