import CryptoKit
import Foundation
import Testing

@testable import GlassDockMachines

@Suite("Omarchy Quattro machines")
struct OmarchyGuestTests {
    @Test func existingLinuxConfigurationDecodesWithoutOmarchyMetadata() throws {
        let linux = MachineConfiguration(name: "Ubuntu", operatingSystem: .linux)
        let decoded = try JSONDecoder().decode(MachineConfiguration.self, from: JSONEncoder().encode(linux))
        #expect(decoded.omarchyBoot == nil)
        #expect(decoded.graphics == .basic)
        try decoded.validate()
    }

    @Test func validatesDesktopGraphicsAndMinimumResources() throws {
        var config = MachineConfiguration(name: "Omarchy", operatingSystem: .omarchy)
        #expect(config.graphics == .virgl)
        #expect(config.audioEnabled == true)
        #expect(config.operatingSystem.isLinux)
        try config.validate()
        for graphics in [MachineGraphics.basic, .neptune] {
            config.graphics = graphics
            #expect(throws: MachineError.self) { try config.validate() }
        }
        config.graphics = .virgl
        config.cpuCount = 2
        #expect(throws: MachineError.self) { try config.validate() }
        config.cpuCount = 4
        config.memoryMiB = 2048
        #expect(throws: MachineError.self) { try config.validate() }
    }

    @Test func validatesFactoryChecksumsAndRejectsChangedOrSymlinkedFiles() throws {
        let guest = try factory()
        defer { try? FileManager.default.removeItem(at: guest) }
        let boot = try OmarchyGuest.inspect(guest)
        #expect(boot.release == "4.0.4")
        let kernel = guest.appendingPathComponent("vmlinuz-linux")
        let original = try Data(contentsOf: kernel)
        try Data(repeating: 42, count: original.count).write(to: kernel)
        #expect(throws: MachineError.self) { try OmarchyGuest.inspect(guest) }
        try FileManager.default.removeItem(at: kernel)
        try FileManager.default.createSymbolicLink(at: kernel, withDestinationURL: guest.appendingPathComponent("rootfs.ext4"))
        #expect(throws: MachineError.self) { try OmarchyGuest.inspect(guest) }
    }

    @Test func rejectsWrongArchitectureAndMissingArtifacts() throws {
        let guest = try factory(architecture: "x86_64")
        defer { try? FileManager.default.removeItem(at: guest) }
        #expect(throws: MachineError.self) { try OmarchyGuest.inspect(guest) }
        let valid = try factory()
        defer { try? FileManager.default.removeItem(at: valid) }
        try FileManager.default.removeItem(at: valid.appendingPathComponent("initramfs-linux.img"))
        #expect(throws: (any Error).self) { try OmarchyGuest.inspect(valid) }
    }

    @Test func directBootUsesPairedFilesAndEnablesSSHOnlyWithAForward() throws {
        let guest = try factory()
        defer { try? FileManager.default.removeItem(at: guest) }
        let bundle = guest.appendingPathComponent("machine,with,commas")
        let state = bundle.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        for filename in ["vmlinuz-linux", "initramfs-linux.img"] {
            try FileManager.default.copyItem(at: guest.appendingPathComponent(filename), to: state.appendingPathComponent(filename))
        }
        var config = MachineConfiguration(name: "Omarchy", operatingSystem: .omarchy)
        config.omarchyBoot = try OmarchyGuest.inspect(guest)
        let runtime = MachineRuntime(app: guest, launcher: guest, supervisor: guest)
        let arguments = try QEMUArguments.build(config, bundle: bundle, runtime: runtime)
        #expect(arguments.contains("virtio-gpu-gl-pci"))
        #expect(arguments.contains("host,pmu=off"))
        let kernelIndex = try #require(arguments.firstIndex(of: "-kernel"))
        #expect(arguments[kernelIndex + 1] == state.appendingPathComponent("vmlinuz-linux").path)
        #expect(!arguments.contains { $0.contains("tryomarchy.ssh_access=1") })
        config.sshPort = 22223
        let ssh = try QEMUArguments.build(config, bundle: bundle, runtime: runtime)
        #expect(ssh.contains { $0.contains("tryomarchy.ssh_access=1") })
        #expect(ssh.contains("user,id=network,hostfwd=tcp:127.0.0.1:22223-:22"))
        try FileManager.default.removeItem(at: state.appendingPathComponent("vmlinuz-linux"))
        #expect(throws: MachineError.self) { try QEMUArguments.build(config, bundle: bundle, runtime: runtime) }
    }

    @Test func creationCopiesBootKitAndSnapshotsClonesAndArchivesPreserveIt() throws {
        let guest = try factory()
        defer { try? FileManager.default.removeItem(at: guest) }
        let root = guest.appendingPathComponent("library")
        let helper = guest.appendingPathComponent("qemu-fixture")
        // Exercise storage with tiny disk fixtures. Real qemu-img conversion is
        // covered by the VM smoke test; this helper reports self-contained disks.
        try Data(
            """
            #!/bin/bash
            case "$2" in
              info) echo '{"format":"qcow2"}';;
              convert) args=("$@"); n=${#args[@]}; cp "${args[n-2]}" "${args[n-1]}";;
              resize) exit 0;;
            esac
            """.utf8
        ).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let firmware = guest.appendingPathComponent("Contents/Resources/qemu")
        try FileManager.default.createDirectory(at: firmware, withIntermediateDirectories: true)
        for name in ["edk2-aarch64-code.fd", "edk2-arm-vars.fd"] { try Data("firmware".utf8).write(to: firmware.appendingPathComponent(name)) }
        let store = try MachineStore(root: root, runtime: MachineRuntime(app: guest, launcher: helper, supervisor: helper))
        let config = MachineConfiguration(name: "Omarchy", operatingSystem: .omarchy)
        #expect(throws: MachineError.self) { try store.create(config) }
        #expect(try store.list().isEmpty)
        let created = try store.create(config, omarchyGuest: guest)
        #expect(created.omarchyBoot?.release == "4.0.4")
        let kernel = store.bundle(created.id).appendingPathComponent("state/vmlinuz-linux")
        let original = try Data(contentsOf: kernel)
        try store.snapshot(created.id, name: "baseline")
        try Data("changed kernel".utf8).write(to: kernel)
        try store.restore(created.id, name: "baseline")
        #expect(try Data(contentsOf: kernel) == original)
        let clone = try store.clone(created.id, name: "clone")
        #expect(clone.omarchyBoot == created.omarchyBoot)
        #expect(try Data(contentsOf: store.bundle(clone.id).appendingPathComponent("state/vmlinuz-linux")) == original)
        let archive = guest.appendingPathComponent("export.glassvmarchive")
        try store.exportDirectory(created.id, to: archive)
        let exported = archive.appendingPathComponent("Machine")
        let recorded = try JSONDecoder().decode(MachineManifest.self, from: Data(contentsOf: exported.appendingPathComponent("manifest.json")))
        let computed = try store.hashes(at: exported)
        #expect(recorded.files == computed)
        #expect(recorded.files["state/vmlinuz-linux"] != nil)
        #expect(recorded.files["manifest.json"] == nil)
        let imported = try store.importArchive(archive, name: "imported")
        #expect(imported.omarchyBoot == created.omarchyBoot)
        #expect(imported.operatingSystem == .omarchy)
        #expect(try Data(contentsOf: store.bundle(imported.id).appendingPathComponent("state/vmlinuz-linux")) == original)
        // Even a self-consistent archive manifest cannot omit the paired boot kit.
        let exportedMachine = archive.appendingPathComponent("Machine")
        try FileManager.default.removeItem(at: exportedMachine.appendingPathComponent("state/vmlinuz-linux"))
        try store.writeManifest(at: exportedMachine)
        #expect(throws: MachineError.self) { try store.importArchive(archive) }
        #expect(try store.list().count == 3)
    }

    private func factory(architecture: String = "aarch64") throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omarchy-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var artifacts: [[String: Any]] = []
        for filename in ["rootfs.ext4"] + OmarchyGuest.bootFiles.filter({ $0 != "guest-manifest.json" }) {
            let data = Data("fixture \(filename)".utf8)
            try data.write(to: root.appendingPathComponent(filename))
            artifacts.append(["path": filename, "bytes": data.count, "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()])
        }
        let manifest: [String: Any] = [
            "schemaVersion": 1, "kind": "try-omarchy-guest-artifacts",
            "guest": ["architecture": architecture, "profile": "factory", "kernelCommandLine": "root=/dev/vda rw rootwait"],
            "upstream": ["release": "4.0.4", "commit": String(repeating: "a", count: 40), "channel": "quattro"],
            "artifacts": artifacts,
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("guest-manifest.json"))
        return root
    }
}
