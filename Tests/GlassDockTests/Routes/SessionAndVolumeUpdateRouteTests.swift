import Foundation
import NIOCore
import Testing
import Vapor
import VaporTesting

@testable import GlassDock

@Suite("Session and volume update routes")
struct SessionAndVolumeUpdateRouteTests {
    @Test("session requires and accepts Docker upgrade headers")
    func sessionUpgrade() async throws {
        try await withApp(configure: { _ in }) { app in
            let router = app.regexRouter(with: app.logger)
            app.setRegexRouter(router)
            try app.register(collection: SessionRoute())

            try await app.testing().test(.POST, "/v1.51/session") { response async in
                #expect(response.status == .badRequest)
            }
            try await app.testing().test(
                .POST,
                "/v1.51/session",
                headers: ["Connection": "Upgrade", "Upgrade": "tcp"]
            ) { response async in
                #expect(response.status == .switchingProtocols)
                #expect(response.headers.first(name: "Upgrade") == "tcp")
            }
        }
    }

    @Test("volume update returns Moby's 503 cluster-volume error on a non-swarm daemon")
    func volumeUpdate() async throws {
        try await withApp(configure: { _ in }) { app in
            app.middleware.use(DockerErrorMiddleware(), at: .beginning)
            let router = app.regexRouter(with: app.logger)
            app.setRegexRouter(router)
            try app.register(collection: VolumeUpdateRoute())

            try await app.testing().test(.PUT, "/v1.51/volumes/data?version=1") { response async throws in
                #expect(response.status == .serviceUnavailable)
                let value =
                    try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
                #expect(
                    (value?["message"] as? String)
                        == VolumeUpdateRoute.unavailableMessage
                )
            }
        }
    }
}
