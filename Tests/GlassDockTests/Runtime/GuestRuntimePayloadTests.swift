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
}
