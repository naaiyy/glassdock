import Foundation
import NIOCore
import Testing
import Vapor
import VaporTesting

@testable import GlassDock

@Suite("Swarm-compatible control-plane routes")
struct SwarmControlPlaneRoutesTests {
    @Test("configs and secrets have Docker CRUD semantics")
    func configsAndSecrets() async throws {
        let controlPlane = DockerControlPlane()
        try await withApp(configure: { _ in }) { app in
            let router = app.regexRouter(with: app.logger)
            app.setRegexRouter(router)
            try app.register(collection: DockerControlPlaneRoutes(controlPlane: controlPlane))

            let configBody = #"{"Name":"app-config","Labels":{"tier":"web"},"Data":"Y29uZmln"}"#
            try await app.testing().test(
                .POST,
                "/v1.51/configs/create",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: configBody)
            ) { response async throws in
                #expect(response.status == .created)
                let value = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
                #expect((value?["Id"] as? String)?.isEmpty == false)
            }
            try await app.testing().test(.GET, "/v1.51/configs") { response async throws in
                #expect(response.status == .ok)
                let value = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [[String: Any]]
                #expect(value?.count == 1)
                #expect(value?.first?["Spec"] is [String: Any])
            }
            let configID = try await controlPlane.firstConfigID()
            try await app.testing().test(.GET, "/v1.51/configs/\(configID)") { response async throws in
                #expect(response.status == .ok)
                let value = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
                #expect(value?["ID"] as? String == configID)
            }
            try await app.testing().test(
                .POST,
                "/v1.51/configs/\(configID)/update",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: #"{"Name":"app-config-v2","Labels":{"tier":"api"},"Data":"bmV3"}"#)
            ) { response async in
                #expect(response.status == .ok)
            }
            try await app.testing().test(.DELETE, "/v1.51/configs/\(configID)") { response async in
                #expect(response.status == .noContent)
            }
            try await app.testing().test(
                .POST,
                "/v1.51/secrets/create",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: #"{"Name":"app-secret","Data":"c2VjcmV0"}"#)
            ) { response async in
                #expect(response.status == .created)
            }
            try await app.testing().test(.GET, "/v1.51/secrets") { response async throws in
                #expect(response.status == .ok)
                let value = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [[String: Any]]
                #expect(value?.count == 1)
            }
        }
    }

    @Test("single-node swarm lifecycle returns Docker response shapes")
    func swarmLifecycle() async throws {
        let controlPlane = DockerControlPlane()
        try await withApp(configure: { _ in }) { app in
            let router = app.regexRouter(with: app.logger)
            app.setRegexRouter(router)
            try app.register(collection: DockerControlPlaneRoutes(controlPlane: controlPlane))

            try await app.testing().test(
                .POST,
                "/v1.51/swarm/init",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: #"{"ListenAddr":"127.0.0.1:2377"}"#)
            ) { response async throws in
                #expect(response.status == .ok)
                let value = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
                #expect((value?["NodeID"] as? String)?.isEmpty == false)
                #expect((value?["ManagerStatus"] as? [String: Any])?["Leader"] as? Bool == true)
            }
            try await app.testing().test(.GET, "/v1.51/swarm") { response async throws in
                #expect(response.status == .ok)
                let value = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
                #expect((value?["ID"] as? String)?.isEmpty == false)
                #expect((value?["JoinTokens"] as? [String: Any])?["Worker"] as? String != nil)
            }
            try await app.testing().test(
                .POST,
                "/v1.51/swarm/update",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: #"{"Name":"local-swarm"}"#)
            ) { response async in
                #expect(response.status == .noContent)
            }
            try await app.testing().test(.POST, "/v1.51/swarm/leave?force=1") { response async in
                #expect(response.status == .noContent)
            }
        }
    }

    @Test("nodes, services, and tasks share single-node control-plane state")
    func nodesServicesAndTasks() async throws {
        let controlPlane = DockerControlPlane()
        try await withApp(configure: { _ in }) { app in
            let router = app.regexRouter(with: app.logger)
            app.setRegexRouter(router)
            try app.register(collection: DockerControlPlaneRoutes(controlPlane: controlPlane))

            try await app.testing().test(
                .POST,
                "/v1.51/swarm/init",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: #"{"ListenAddr":"127.0.0.1:2377"}"#)
            ) { response async in
                #expect(response.status == .ok)
            }
            try await app.testing().test(.GET, "/v1.51/nodes") { response async throws in
                #expect(response.status == .ok)
                let nodes = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [[String: Any]]
                #expect(nodes?.count == 1)
            }
            let nodeID = try #require(await controlPlane.listNodes(filters: nil).first?.id)
            try await app.testing().test(
                .POST,
                "/v1.51/nodes/\(nodeID)/update",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: #"{"Name":"local-node","Availability":"pause"}"#)
            ) { response async in
                #expect(response.status == .ok)
            }
            try await app.testing().test(.GET, "/v1.51/nodes/\(nodeID)") { response async throws in
                #expect(response.status == .ok)
                let node = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
                let spec = node?["Spec"] as? [String: Any]
                #expect(spec?["Name"] as? String == "local-node")
            }
            try await app.testing().test(
                .POST,
                "/v1.51/services/create",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: #"{"Name":"web","TaskTemplate":{"ContainerSpec":{"Image":"alpine"}}}"#)
            ) { response async throws in
                #expect(response.status == .created)
                let value = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
                #expect((value?["Id"] as? String)?.isEmpty == false)
            }
            let serviceID = try #require(await controlPlane.listServices(filters: nil).first?.id)
            try await app.testing().test(.GET, "/v1.51/services") { response async throws in
                #expect(response.status == .ok)
                let services = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [[String: Any]]
                #expect(services?.count == 1)
            }
            try await app.testing().test(.GET, "/v1.51/services/\(serviceID)/logs") { response async in
                #expect(response.status == .ok)
            }
            try await app.testing().test(
                .POST,
                "/v1.51/services/\(serviceID)/update",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: #"{"Name":"web-v2","TaskTemplate":{"ContainerSpec":{"Image":"alpine"}}}"#)
            ) { response async in
                #expect(response.status == .ok)
            }
            try await app.testing().test(.GET, "/v1.51/tasks") { response async throws in
                #expect(response.status == .ok)
                let tasks = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [[String: Any]]
                #expect(tasks?.count == 1)
            }
            let taskID = try #require(await controlPlane.listTasks(filters: nil).first?.id)
            try await app.testing().test(.GET, "/v1.51/tasks/\(taskID)") { response async in
                #expect(response.status == .ok)
            }
            try await app.testing().test(.GET, "/v1.51/tasks/\(taskID)/logs") { response async in
                #expect(response.status == .ok)
            }
            try await app.testing().test(.DELETE, "/v1.51/services/\(serviceID)") { response async in
                #expect(response.status == .ok)
            }
        }
    }
}

extension DockerControlPlane {
    fileprivate func firstConfigID() async throws -> String {
        try #require(await listConfigs(filters: nil).first?.id)
    }
}
