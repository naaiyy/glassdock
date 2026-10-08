import Foundation
import Testing
import ZIPFoundation

@testable import GlassDockMachines

@Suite("Desktop machine state")
struct MachineStoreTests {
    @Test func restoreMetadataMoveFailureKeepsOriginalRAMMetadataAndDisk() throws {
        let fileManager = FailingMemoryMoveFileManager()
        let (store, config) = try fixture(fileManager: fileManager)
        defer { try? FileManager.default.removeItem(at: store.root) }
        try store.snapshot(config.id, name: "before-memory")
        let memory = store.bundle(config.id).appendingPathComponent("memory-snapshots")
        try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: false)
        let checkpoint = memory.appendingPathComponent("baseline.json")
        try Data("keep original metadata".utf8).write(to: checkpoint)
        let disk = store.bundle(config.id).appendingPathComponent("state/disk.qcow2")
        try Data("keep current disk".utf8).write(to: disk)
        fileManager.failNextMemoryMove = true
        #expect(throws: (any Error).self) { try store.restore(config.id, name: "before-memory") }
        #expect(try String(contentsOf: checkpoint, encoding: .utf8) == "keep original metadata")
        #expect(try String(contentsOf: disk, encoding: .utf8) == "keep current disk")
    }
    @Test func cliUsesThePackagedSignedHelpersUnlessExplicitlyOverridden() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: app) }
        let fallback = app.appendingPathComponent("development-bin")
        let helpers = app.appendingPathComponent("Contents/MacOS")
        #expect(MachineRuntime.helperDirectory(app: app, fallback: fallback, overridden: false) == fallback)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        for name in ["glassdock-qemu", "glassdock-vm-runner"] {
            let file = helpers.appendingPathComponent(name)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        #expect(MachineRuntime.helperDirectory(app: app, fallback: fallback, overridden: false).path == helpers.path)
        #expect(MachineRuntime.helperDirectory(app: app, fallback: fallback, overridden: true) == fallback)
    }
    @Test func memoryStorageBudgetsGuestRAMAndHeadroom() {
        #expect(MachineMemoryStorage.requiredSpace(memoryMiB: 4096) == 6 * 1024 * 1024 * 1024)
        #expect(MachineMemoryStorage.requiredSpace(memoryMiB: 262144) == 258 * 1024 * 1024 * 1024)
    }

    @Test func verboseRuntimeToolsCompleteWithoutAnOutputPipeDeadlockAndReturnBoundedDiagnostics() throws {
        let result = try MachineRuntime.execute(URL(fileURLWithPath: "/bin/sh"), ["-c", "dd if=/dev/zero bs=1024 count=256 2>/dev/null; printf runtime-output-finished"])
        #expect(result.utf8.count <= 65536)
        #expect(result.hasSuffix("runtime-output-finished"))
    }
    @Test func directoryCopyBudgetsSparseFilesConservativelyAcrossVolumes() throws {
        let bytes: UInt64 = 64 * 1024 * 1024 * 1024
        #expect(try MachineArchiveStorage.requiredDirectorySpace(payloadBytes: bytes, canClone: true) == MachineArchiveStorage.reserve)
        #expect(try MachineArchiveStorage.requiredDirectorySpace(payloadBytes: bytes, canClone: false) == bytes + MachineArchiveStorage.reserve)
        #expect(throws: MachineError.self) { try MachineArchiveStorage.requiredDirectorySpace(payloadBytes: .max, canClone: false) }
    }

    @Test func stoppedSnapshotsRestoreMatchingMemoryMetadataAndRemoveStaleCheckpoints() throws {
        let (store, config) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.root) }
        try store.snapshot(config.id, name: "before-memory")
        let memory = store.bundle(config.id).appendingPathComponent("memory-snapshots")
        try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: false)
        try Data("checkpoint metadata".utf8).write(to: memory.appendingPathComponent("baseline.json"))
        try store.snapshot(config.id, name: "with-memory")
        try Data("new checkpoint".utf8).write(to: memory.appendingPathComponent("newer.json"))
        try store.restore(config.id, name: "with-memory")
        #expect(try store.memorySnapshots(config.id) == ["baseline"])
        try store.restore(config.id, name: "before-memory")
        #expect(try store.memorySnapshots(config.id).isEmpty)
    }

    @Test func exportSpaceBudgetIncludesBothCompactStagesAndHeadroom() throws {
        let size: UInt64 = 10 * 1024 * 1024 * 1024
        #expect(try MachineArchiveStorage.requiredExportSpace(payloadBytes: size, compact: false) == size + MachineArchiveStorage.reserve)
        #expect(try MachineArchiveStorage.requiredExportSpace(payloadBytes: size, compact: true) == 2 * size + MachineArchiveStorage.reserve)
        #expect(throws: MachineError.self) { try MachineArchiveStorage.requiredExportSpace(payloadBytes: .max, compact: true) }
        #expect(throws: MachineError.self) { try MachineArchiveStorage.requiredExportSpace(payloadBytes: .max, compact: false) }
    }
    @Test func failedCompactExportPreservesSourceAndLeavesNoArchive() throws {
        let (store, config) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let archive = store.root.appendingPathComponent("compact.zip")
        // The fixture launcher intentionally produces no converted image.
        #expect(throws: (any Error).self) { try store.export(config.id, to: archive, compact: true) }
        #expect(!FileManager.default.fileExists(atPath: archive.path))
        #expect(try String(contentsOf: store.bundle(config.id).appendingPathComponent("state/disk.qcow2"), encoding: .utf8) == "original disk.qcow2")
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.root.path).allSatisfy { !$0.hasPrefix(".export-") })
    }
    @Test func ejectedMediaIsRetainedLocallyAndExcludedFromExport() throws {
        let (store, config) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.root) }
        #expect(throws: MachineError.self) { try store.setMediaMounted(config.id, installation: true) }
        let media = store.bundle(config.id).appendingPathComponent("state/install.iso")
        try Data("installer".utf8).write(to: media)
        try store.setMediaMounted(config.id, installation: true)
        #expect(try store.configuration(config.id).installationMedia)
        try store.setMediaMounted(config.id, installation: false)
        #expect(FileManager.default.fileExists(atPath: media.path))
        let archiveURL = store.root.appendingPathComponent("installed.zip")
        try store.export(config.id, to: archiveURL)
        let permissions = try FileManager.default.attributesOfItem(atPath: archiveURL.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        let archive = try Archive(url: archiveURL, accessMode: .read)
        #expect(archive["Machine/state/install.iso"] == nil)
        #expect(archive["Machine/state/disk.qcow2"] != nil)
        #expect(throws: MachineError.self) {
            let lock = try MachineLock(bundle: store.bundle(config.id))
            try withExtendedLifetime(lock) { try store.setMediaMounted(config.id, installation: true) }
        }
    }
    @Test func windowsUsesSecureFirmwareForTPMInitialization() {
        let root = URL(fileURLWithPath: "/tmp/test-runtime")
        let runtime = MachineRuntime(app: root, launcher: root, supervisor: root)
        let windows = runtime.firmwareTemplates(for: .windows)
        #expect(windows.code.lastPathComponent == "edk2-aarch64-secure-code.fd")
        #expect(windows.variables.lastPathComponent == "edk2-arm-secure-vars.fd")
        let linux = runtime.firmwareTemplates(for: .linux)
        #expect(linux.code.lastPathComponent == "edk2-aarch64-code.fd")
        #expect(linux.variables.lastPathComponent == "edk2-arm-vars.fd")
    }
    @Test func directoryArchiveChecksHashesAndRejectsSymlinks() throws {
        let (store, config) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let target = store.root.appendingPathComponent("machine.glassvmarchive")
        try store.exportDirectory(config.id, to: target)
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("Machine/manifest.json").path))
        #expect(throws: MachineError.self) { try store.exportDirectory(config.id, to: target) }
        let link = target.appendingPathComponent("Machine/state/escape")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/etc/passwd")
        #expect(throws: MachineError.self) { _ = try store.importArchive(target) }
        #expect(try store.list().count == 1)
    }
    @Test func memoryCheckpointRejectsGPUAndUnsafeNames() throws {
        let (store, config) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.root) }
        try store.configure(config.id, graphics: .virgl)
        #expect(throws: MachineError.self) { try store.saveMemorySnapshot(config.id, name: "gpu") }
        #expect(throws: MachineError.self) { try store.saveMemorySnapshot(config.id, name: "../escape") }
        #expect(try store.memorySnapshots(config.id).isEmpty)
        #expect(throws: MachineError.self) { _ = try MachineLock(bundle: store.bundle(config.id), name: "../operation.lock") }
    }
    @Test func integrationDevicesAreOptInAndNeptuneUsesOnlyDXMT() throws {
        var config = MachineConfiguration(name: "Windows", operatingSystem: .windows)
        let root = URL(fileURLWithPath: "/tmp/runtime")
        let runtime = MachineRuntime(app: root, launcher: root, supervisor: root)
        let basic = try QEMUArguments.build(config, bundle: root, runtime: runtime)
        #expect(basic.contains("hvf"))
        #expect(!basic.contains("coreaudio,id=audio0"))
        #expect(!basic.contains { $0.contains("usb-redir,") })
        config.graphics = .neptune
        config.audioEnabled = true
        config.usbEnabled = true
        let arguments = try QEMUArguments.build(config, bundle: root, runtime: runtime)
        #expect(arguments.contains("hvf,ipa-granule-size=0x1000"))
        #expect(arguments.contains("virtio-ramfb-gl,hostmem=8G,blob=true,neptune=true"))
        #expect(arguments.contains("coreaudio,id=audio0"))
        #expect(arguments.filter { $0.hasPrefix("usb-redir,") }.count == 3)
        #expect(arguments.contains("virtserialport,chardev=webdav,name=org.spice-space.webdav.0"))
        let environment = runtime.guestEnvironment(graphics: .neptune)
        #expect(environment["NPT_BACKEND"] == "dxmt")
        #expect(environment["NPT_D3D11_LIBRARY_PATH"]?.contains("dxmt-native.framework") == true)
        #expect(environment["D3DMETAL_FRAMEWORK_PATH"] == nil)
        config.operatingSystem = .linux
        #expect(throws: MachineError.self) { try config.validate() }
    }
    private func fixture(fileManager: FileManager = .default) throws -> (MachineStore, MachineConfiguration) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("glassdock-machines-tests-\(UUID())")
        let unused = URL(fileURLWithPath: "/usr/bin/true")
        let store = try MachineStore(root: root, runtime: MachineRuntime(app: root, launcher: unused, supervisor: unused), fileManager: fileManager)
        let config = MachineConfiguration(name: "Linux", operatingSystem: .linux)
        let bundle = store.bundle(config.id)
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("state/tpm"), withIntermediateDirectories: true)
        for name in ["disk.qcow2", "uefi-vars.qcow2", "uefi-code.fd", "tpm/tpm2-00.permall"] {
            try Data("original \(name)".utf8).write(to: bundle.appendingPathComponent("state/\(name)"))
        }
        try store.save(config, at: bundle)
        return (store, config)
    }
    @Test func validatesWindowsRequirementsAndSchema() throws {
        var config = MachineConfiguration(name: "Windows", operatingSystem: .windows, cpuCount: 1)
        #expect(throws: MachineError.self) { try config.validate() }
        config.cpuCount = 2
        try config.validate()
        config.schemaVersion = 999
        #expect(throws: MachineError.self) { try config.validate() }
    }
    @Test func rejectsTraversalAndKeepsAllStateInSnapshot() throws {
        let (store, config) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.root) }
        #expect(throws: MachineError.self) { try store.snapshot(config.id, name: "../escape") }
        try store.snapshot(config.id, name: "clean")
        let disk = store.bundle(config.id).appendingPathComponent("state/disk.qcow2")
        let tpm = store.bundle(config.id).appendingPathComponent("state/tpm/tpm2-00.permall")
        try Data("changed disk".utf8).write(to: disk)
        try Data("changed TPM".utf8).write(to: tpm)
        try store.restore(config.id, name: "clean")
        #expect(try String(contentsOf: disk, encoding: .utf8) == "original disk.qcow2")
        #expect(try String(contentsOf: tpm, encoding: .utf8) == "original tpm/tpm2-00.permall")
        #expect(try store.snapshots(config.id) == ["clean"])
    }
    @Test func lifetimeLockRejectsMutations() throws {
        let (store, config) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let lock = try MachineLock(bundle: store.bundle(config.id))
        try withExtendedLifetime(lock) {
            #expect(throws: MachineError.self) { try store.snapshot(config.id, name: "unsafe") }
            #expect(throws: MachineError.self) { try store.clone(config.id, name: "Unsafe copy") }
            #expect(store.status(config.id) == "busy")
            try Data(UUID().uuidString.utf8).write(to: store.bundle(config.id).appendingPathComponent("run-id"))
            #expect(store.status(config.id) == "starting or unavailable")
        }
    }
    @Test func cloneHasIndependentStateAndNewHostIdentity() throws {
        let (store, config) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let clone = try store.clone(config.id, name: "Clone")
        #expect(clone.id != config.id)
        #expect(clone.macAddress != config.macAddress)
        #expect(clone.sshPort == nil)
        try Data("clone data".utf8).write(to: store.bundle(clone.id).appendingPathComponent("state/disk.qcow2"))
        #expect(try String(contentsOf: store.bundle(config.id).appendingPathComponent("state/disk.qcow2"), encoding: .utf8) == "original disk.qcow2")
    }
    @Test func explicitSpiceBackendAndEscapedPaths() throws {
        let config = MachineConfiguration(name: "Linux", operatingSystem: .linux)
        let root = URL(fileURLWithPath: "/tmp/a,b")
        let runtime = MachineRuntime(app: root, launcher: root, supervisor: root)
        let args = try QEMUArguments.build(config, bundle: root, runtime: runtime)
        #expect(args.contains { $0.contains("disable-ticketing=on,gl=off") })
        var accelerated = config
        accelerated.graphics = .virgl
        let gl = try QEMUArguments.build(accelerated, bundle: root, runtime: runtime)
        #expect(gl.contains { $0.contains("disable-ticketing=on,gl=es") })
        #expect(runtime.guestEnvironment(graphics: .virgl)["ANGLE_DEFAULT_PLATFORM"] == "metal")
        #expect(runtime.guestEnvironment(graphics: .basic)["ANGLE_DEFAULT_PLATFORM"] == nil)
        #expect(args.contains { $0.contains("file=/tmp/a,,b/state/disk.qcow2") })
        #expect(!args.contains("tcg"))
    }
    @Test func exportRejectsSymlinksAndExistingDestinations() throws {
        let (store, config) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let destination = store.root.appendingPathComponent("export.zip")
        try store.export(config.id, to: destination)
        #expect(throws: MachineError.self) { try store.export(config.id, to: destination) }
        let link = store.bundle(config.id).appendingPathComponent("state/external")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        #expect(throws: MachineError.self) { try store.export(config.id, to: store.root.appendingPathComponent("unsafe.zip")) }
    }
    @Test func settingsRejectInvalidResourcesWithoutChangingState() throws {
        let (store, config) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.root) }
        #expect(throws: MachineError.self) { try store.configure(config.id, cpuCount: 0) }
        #expect(try store.configuration(config.id).cpuCount == config.cpuCount)
        try store.configure(config.id, cpuCount: 2, memoryMiB: 8192, graphics: .virgl)
        #expect(try store.configuration(config.id).graphics == .virgl)
        let lock = try MachineLock(bundle: store.bundle(config.id))
        try withExtendedLifetime(lock) {
            #expect(throws: MachineError.self) { try store.configure(config.id, memoryMiB: 4096) }
        }
    }
    @Test func windowsBootWaitsForViewerAndDoesNotRedirectFirmwareConsole() throws {
        let root = URL(fileURLWithPath: "/tmp/test-runtime")
        let runtime = MachineRuntime(app: root, launcher: root, supervisor: root)
        let config = MachineConfiguration(name: "Windows", operatingSystem: .windows)
        let args = try QEMUArguments.build(config, bundle: root, runtime: runtime)
        #expect(args.contains("-S"))
        #expect(args.contains("virtio-ramfb"))
        #expect(!args.contains("-serial"))
        #expect(args.contains("tpm-crb-device,tpmdev=tpm0"))
        #expect(!args.contains("tpm-tis-device,tpmdev=tpm0"))
    }
    @Test func importRejectsTraversalBeforeExtractingFiles() throws {
        let (store, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.root) }
        for unsafe in ["Machine/../../escape", "Machine//state/disk.qcow2", "Machine/./state/disk.qcow2"] {
            let url = store.root.appendingPathComponent(UUID().uuidString + ".zip")
            let archive = try Archive(url: url, accessMode: .create)
            try archive.addEntry(with: unsafe, type: .file, uncompressedSize: Int64(1)) { _, _ in Data([42]) }
            #expect(throws: MachineError.self) { try store.importArchive(url) }
        }
    }

}

private final class FailingMemoryMoveFileManager: FileManager, @unchecked Sendable {
    var failNextMemoryMove = false
    override func moveItem(at source: URL, to destination: URL) throws {
        if failNextMemoryMove && source.lastPathComponent == "memory-snapshots" {
            failNextMemoryMove = false
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.moveItem(at: source, to: destination)
    }
}
