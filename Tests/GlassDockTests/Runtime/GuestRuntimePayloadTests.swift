import Foundation
import Testing

@testable import GlassDock

@Suite("Guest runtime payloads")
struct GuestRuntimePayloadTests {
    @Test("build responses decode the compact image identity returned by the guest")
    func buildResponseUsesImageIdentity() throws {
        let payload = try? JSONDecoder().decode(
            GuestImageBuildPayload.self,
            from: Data(
                #"{"image":{"name":"example.test/built:latest","digest":"sha256:built"}}"#
                    .utf8
            )
        )

        #expect(payload != nil)
    }

    @Test("invalid guest resource errors map to Docker bad requests")
    func invalidResourceErrorMapsToBadRequest() {
        let error = GuestProtocolError(
            code: "invalid_argument",
            message: "MemorySwap must be greater than or equal to Memory"
        )

        #expect(
            GuestRuntime.routeError(for: error)
                == .invalidRequest("MemorySwap must be greater than or equal to Memory")
        )
    }

    @Test("Docker socket relay mounts keep their guest-only marker")
    func dockerSocketRelayMountPayload() {
        let mount = DockerRuntimeMount(
            source: DockerSocketRelayConfiguration.guestSocketPath,
            target: "/var/run/docker.sock",
            readOnly: false,
            relay: true
        )

        #expect(
            GuestRuntime.mountJSON(mount)
                == .object([
                    "source": .string(DockerSocketRelayConfiguration.guestSocketPath),
                    "target": .string("/var/run/docker.sock"),
                    "type": .string("bind"),
                    "readonly": .bool(false),
                    "options": .array([]),
                    "relay": .bool(true),
                ])
        )
    }
}
