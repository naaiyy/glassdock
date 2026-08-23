import Foundation
import Testing

@testable import GlassDock

@Suite("Glass Dock directories")
struct GlassDockDirectoriesTests {
    @Test("host home uses the task-specific override without changing HOME")
    func hostHomeOverride() {
        let fallback = URL(fileURLWithPath: "/fallback", isDirectory: true)
        #expect(
            GlassDockDirectories.hostHome(
                environment: ["HOME": "/do-not-use", "GLASSDOCK_HOST_HOME_DIRECTORY": "/isolated"],
                fallback: fallback
            ).path == "/isolated"
        )
        #expect(GlassDockDirectories.hostHome(environment: [:], fallback: fallback) == fallback)
    }

    @Test("glassdock directory sits inside the host home")
    func glassdockDirectory() {
        let home = URL(fileURLWithPath: "/isolated", isDirectory: true)
        #expect(
            GlassDockDirectories.glassdockDirectory(home: home).path == "/isolated/.glassdock"
        )
    }

    @Test("empty environment overrides fall back to defaults")
    func emptyOverridesFallBack() {
        let fallback = URL(fileURLWithPath: "/fallback", isDirectory: true)
        #expect(
            GlassDockDirectories.hostHome(
                environment: ["GLASSDOCK_HOST_HOME_DIRECTORY": ""],
                fallback: fallback
            ) == fallback
        )
        let state = GlassDockDirectories.engineStateDirectory(
            environment: ["GLASSDOCK_ENGINE_STATE_DIRECTORY": ""], userID: 501
        )
        #expect(state.path == "/Users/Shared/.glassdock-501")
    }
}
