import Foundation
import Testing

@Suite("Linux display refresh")
struct DisplayRefreshTests {
    @Test func repairsMalformedSPICETimingAndPreservesHealthyModes() throws {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/machines/tests/display_refresh_test.py")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
