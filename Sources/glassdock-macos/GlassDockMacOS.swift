import AppKit
import Darwin
import Foundation
import GlassDockMachines
import Virtualization

#if arch(arm64)
@MainActor final class MacPreparation: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do { try await run() } catch { fail(error) }
        }
    }
    func run() async throws {
        let args = CommandLine.arguments
        guard args.count >= 2 else { throw MachineError.invalid("Expected prepare, latest, or probe") }
        if args[1] == "latest" || args[1] == "probe" {
            let image = try await VZMacOSRestoreImage.latestSupported
            guard let requirements = image.mostFeaturefulSupportedConfiguration else { throw MachineError.invalid("No supported macOS restore image") }
            print(image.url.absoluteString)
            print(
                "macOS \(image.operatingSystemVersion.majorVersion).\(image.operatingSystemVersion.minorVersion).\(image.operatingSystemVersion.patchVersion) build \(image.buildVersion)"
            )
            if args[1] == "probe" {
                // Exercise the real Apple configuration without downloading an IPSW.
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: root) }
                let state = root.appendingPathComponent("state")
                try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
                try requirements.hardwareModel.dataRepresentation.write(to: state.appendingPathComponent("hardware-model.bin"))
                try MacOSGuest.newIdentity(at: state)
                _ = try VZMacAuxiliaryStorage(creatingStorageAt: state.appendingPathComponent("auxiliary-storage"), hardwareModel: requirements.hardwareModel)
                FileManager.default.createFile(atPath: state.appendingPathComponent("disk.raw").path, contents: nil)
                let disk = try FileHandle(forWritingTo: state.appendingPathComponent("disk.raw"))
                try disk.truncate(atOffset: 64 * 1024 * 1024 * 1024)
                try disk.close()
                try Data("installed".utf8).write(to: state.appendingPathComponent(MacOSGuest.installedMarker))
                let config = MachineConfiguration(
                    name: "probe", operatingSystem: .macos, cpuCount: max(4, requirements.minimumSupportedCPUCount),
                    memoryMiB: max(4096, Int(requirements.minimumSupportedMemorySize / 1024 / 1024)))
                _ = try MacOSGuest.configuration(config, bundle: root)
                print("Native Apple Silicon configuration validates")
            }
            fflush(stdout)
            exit(0)
        }
        if args[1] == "prepare" {
            guard args.count == 4 else { throw MachineError.invalid("usage: glassdock-macos prepare bundle ipsw") }
            let bundle = URL(fileURLWithPath: args[2])
            let config = try JSONDecoder().decode(MachineConfiguration.self, from: Data(contentsOf: bundle.appendingPathComponent("machine.json")))
            try await MacOSGuest.prepare(config, bundle: bundle, restoreImage: URL(fileURLWithPath: args[3]))
            exit(0)
        }
        throw MachineError.invalid("Expected prepare, latest, or probe; native sessions run inside GlassDock Machines")
    }
    func fail(_ error: Error) {
        FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
        exit(1)
    }
}
#endif

@main struct NativeMacOSRunner {
    @MainActor static func main() {
        #if arch(arm64)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let session = MacPreparation()
        app.delegate = session
        withExtendedLifetime(session) { app.run() }
        #else
        FileHandle.standardError.write(Data("macOS guests require Apple Silicon\n".utf8))
        exit(1)
        #endif
    }
}
