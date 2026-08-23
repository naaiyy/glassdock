import Foundation
import Testing

@testable import GlassDock

/// Decodes committed golden fixtures captured from a live guest agent
/// (scripts/capture-guest-fixtures.py) through the host payload structs.
/// The fixtures pin the guest's real wire format: `omitempty` fields vanish
/// and nil Go slices and maps arrive as JSON null, so any drift between the
/// guest schema and the host decoders surfaces here instead of at runtime.
@Suite("Guest golden fixtures")
struct GuestFixtureDecodingTests {
    private func fixtureData(_ name: String) throws -> Data {
        // SPM flattens processed resources into the bundle root.
        let url = Bundle.module.bundleURL.appendingPathComponent("\(name).json")
        return try Data(contentsOf: url)
    }

    private func decodeFixture<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: try fixtureData(name))
    }

    @Test("version fixture reports the expected protocol")
    func version() throws {
        let payload = try decodeFixture(GuestVersionFixture.self, "version")
        #expect(payload.protocol == PersistentEngine.expectedGuestProtocolVersion)
    }

    @Test("network list fixture decodes with nullable maps")
    func networkList() throws {
        let payload = try decodeFixture(GuestNetworkListPayload.self, "network-list")
        #expect(!payload.networks.isEmpty)
        for network in payload.networks {
            #expect(!network.id.isEmpty)
            #expect(!network.name.isEmpty)
            // Live payloads carry extra keys (subnet, gateway); the decoder
            // ignores them, and nil maps decode as empty.
            #expect(network.options.isEmpty || !network.options.isEmpty)
            #expect(network.labels.isEmpty || !network.labels.isEmpty)
        }
    }

    @Test("container list fixture decodes")
    func containerList() throws {
        let payload = try decodeFixture(GuestContainerListPayload.self, "container-list")
        for container in payload.containers {
            #expect(!container.id.isEmpty)
            #expect(!container.image.isEmpty)
            #expect(!container.status.isEmpty)
        }
    }

    @Test("image list fixture decodes with omitempty fields absent")
    func imageList() throws {
        let payload = try decodeFixture(GuestImageListPayload.self, "image-list")
        for image in payload.images {
            #expect(!image.id.isEmpty)
            #expect(!image.digest.isEmpty)
        }
    }

    /// A container-list payload with every `omitempty` metadata field absent,
    /// matching what the agent sends for a minimal container.
    @Test("minimal container payload tolerates omitted metadata")
    func minimalContainer() throws {
        let json = Data(
            """
            {"containers": [{
                "id": "abc123",
                "image": "docker.io/library/alpine:3.20",
                "status": "running",
                "createdAt": "2026-08-23T00:00:00Z"
            }]}
            """.utf8
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(GuestContainerListPayload.self, from: json)
        #expect(payload.containers.count == 1)
        let container = try #require(payload.containers.first)
        #expect(container.exitCode == nil)
        #expect(container.sizeRw == nil)
    }

    /// Nil Go slices arrive as JSON null; the decoders must map them to
    /// empty collections instead of failing.
    @Test("null lists and maps decode as defaults")
    func nullCollectionsDecodeAsDefaults() throws {
        let json = Data(
            """
            {
              "networks": [{
                "id": "bridge", "name": "bridge", "createdAt": "2026-08-23T00:00:00Z",
                "scope": "local", "driver": "bridge",
                "enableIPv4": true, "enableIPv6": false,
                "internal": false, "attachable": false, "ingress": false,
                "ipam": {"driver": "default", "config": null},
                "options": null, "containers": null, "labels": null
              }]
            }
            """.utf8
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(GuestNetworkListPayload.self, from: json)
        let network = try #require(payload.networks.first)
        #expect(network.ipam.config.isEmpty)
        #expect(network.options.isEmpty)
        #expect(network.containers.isEmpty)
        #expect(network.labels.isEmpty)
    }
}

/// The version handshake payload as the agent sends it.
private struct GuestVersionFixture: Decodable {
    let `protocol`: String
    let agent: String
    let containerd: String
}
