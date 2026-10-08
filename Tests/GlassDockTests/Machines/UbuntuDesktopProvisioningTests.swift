import Foundation
import Testing

@Suite("Ubuntu desktop provisioning")
struct UbuntuDesktopProvisioningTests {
    @Test func generatedDesktopSeedInstallsABrowser() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("scripts/machines/create-ubuntu.sh"), encoding: .utf8)
        let start = try #require(script.range(of: "python3 - \"$key.pub\" \"$seed_dir\" <<'PY'\n"))
        let end = try #require(script.range(of: "\nPY\n", range: start.upperBound..<script.endIndex))
        let renderer = String(script[start.upperBound..<end.lowerBound])
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let key = fixture.appendingPathComponent("test-key.pub")
        try Data("ssh-ed25519 AAAA provisioning-test".utf8).write(to: key)
        let input = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-", key.path, fixture.path]
        process.standardInput = input
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data(renderer.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let userData = try String(contentsOf: fixture.appendingPathComponent("user-data"), encoding: .utf8)
        let packageLine = try #require(userData.split(separator: "\n").first { $0.hasPrefix("packages: [") })
        let packages = packageLine.dropFirst("packages: [".count).dropLast()
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        // XFCE includes a generic browser launcher, but does not itself install a browser.
        #expect(packages.contains("firefox"))
    }
}
