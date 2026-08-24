import Foundation
import Testing

@testable import GlassDock

/// Pins the cooperative-thread safety of the VMM helper process exit wait.
///
/// The exit wait used to call `Process.waitUntilExit()` inside a detached
/// task, which blocked a Swift-concurrency cooperative thread for the VM's
/// whole lifetime and starved every other resumed Task — including Vapor's
/// streaming-response continuations, which made `docker run` hang forever.
@Suite("Runtime machine process exit")
struct RuntimeMachineProcessExitTests {
    private func makeLauncherConfig(helper: URL, directory: URL) throws -> RuntimeMachineConfiguration {
        try RuntimeMachineConfiguration(
            helperExecutable: helper,
            stateDirectory: directory.appendingPathComponent("state"),
            kernel: directory.appendingPathComponent("kernel"),
            rootDisk: directory.appendingPathComponent("root-disk"),
            dataDisk: directory.appendingPathComponent("state/data.ext4"),
            bindSource: directory.appendingPathComponent("home"),
            cpuCount: 1,
            memoryBytes: 96 * 1024 * 1024
        )
    }

    @Test("waitForExit reports a finished helper without blocking indefinitely")
    func waitForExitFinishes() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("st-rmp-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let launcher = FoundationRuntimeMachineProcessLauncher()
        let configuration = try makeLauncherConfig(helper: URL(fileURLWithPath: "/usr/bin/true"), directory: directory)
        let generation = UUID()
        let process = try launcher.launch(
            configuration: configuration,
            generation: generation,
            runtimeDirectory: directory
        )
        let status = await process.waitForExit()
        #expect(status == 0)
    }

    @Test("waitForExit observes a helper killed after launch")
    func waitForExitObservesTermination() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("st-rmp-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // A long-running helper must be observable through waitForExit once
        // stop() tears it down; the exit continuation bridges Foundation's
        // termination callback instead of blocking a cooperative thread.
        let launcher = FoundationRuntimeMachineProcessLauncher()
        let configuration = try makeLauncherConfig(helper: URL(fileURLWithPath: "/usr/bin/true"), directory: directory)
        let process = try launcher.launch(
            configuration: configuration,
            generation: UUID(),
            runtimeDirectory: directory.appendingPathComponent("second")
        )
        try await process.stop()
        let status = await process.waitForExit()
        // stop() terminates the helper with SIGTERM (15).
        #expect(status == 15)
    }
}
