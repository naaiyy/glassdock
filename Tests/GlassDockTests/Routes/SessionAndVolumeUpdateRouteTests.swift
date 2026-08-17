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

    @Test("local volume update persists labels and driver options")
    func volumeUpdate() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glassdock-volume-update-\(UUID().uuidString)")
        let client = RuntimeVolumeService(root: root)
        try await withApp(configure: { _ in }) { app in
            let router = app.regexRouter(with: app.logger)
            app.setRegexRouter(router)
            try app.register(collection: VolumeUpdateRoute(client: client))

            _ = try await client.create(
                request: RESTVolumeCreate(
                    Name: "data",
                    Driver: "local",
                    Options: ["sync": "fsync"],
                    Labels: ["tier": "old"]
                )
            )
            try await app.testing().test(
                .PUT,
                "/v1.51/volumes/data",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(
                    string: #"{"Labels":{"tier":"new"},"DriverOpts":{"sync":"full"}}"#
                )
            ) { response async throws in
                #expect(response.status == .ok)
                let value = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
                #expect((value?["Labels"] as? [String: String])?["tier"] == "new")
                #expect((value?["Options"] as? [String: String])?["sync"] == "full")
            }
        }
        try? FileManager.default.removeItem(at: root)
    }
}
