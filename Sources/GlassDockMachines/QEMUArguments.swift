import Foundation

public enum QEMUArguments {
    public static func socketDirectory(id: UUID) -> URL {
        URL(fileURLWithPath: "/tmp/glassdock-vm-\(getuid())/\(id.uuidString)")
    }
    public static func escaped(_ value: String) -> String { value.replacingOccurrences(of: ",", with: ",,") }

    public static func build(_ config: MachineConfiguration, bundle: URL, runtime: MachineRuntime) throws -> [String] {
        try config.validate()
        guard config.operatingSystem != .macos else { throw MachineError.invalid("macOS uses Apple Virtualization.framework, not QEMU") }
        let socket = socketDirectory(id: config.id)
        func path(_ name: String) -> String { escaped(bundle.appendingPathComponent("state").appendingPathComponent(name).path) }
        var arguments = [
            "-L", runtime.firmware.path, "-nodefaults", "-no-user-config",
            "-name", config.name, "-uuid", config.id.uuidString,
            "-machine", "virt,highmem=on", "-accel", config.graphics == .neptune ? "hvf,ipa-granule-size=0x1000" : "hvf", "-cpu",
            config.operatingSystem == .omarchy ? "host,pmu=off" : "host",
            "-smp", String(config.cpuCount), "-m", String(config.memoryMiB),
            "-drive", "if=pflash,format=raw,readonly=on,file=\(path("uefi-code.fd"))",
            "-drive", "if=pflash,format=qcow2,file=\(path("uefi-vars.qcow2"))",
            "-drive", "if=none,id=system,format=qcow2,file=\(path("disk.qcow2"))",
            "-device", "virtio-blk-pci,drive=system,bootindex=0",
            "-netdev", "user,id=network" + (config.sshPort.map { ",hostfwd=tcp:127.0.0.1:\($0)-:22" } ?? ""), "-device", "virtio-net-pci,netdev=network,mac=\(config.macAddress)",
            "-device", "virtio-scsi-pci,id=scsi",
            "-device", "qemu-xhci", "-device", "usb-kbd", "-device", "usb-tablet",
            "-device", "virtio-serial-pci",
            "-chardev", "spicevmc,id=vdagent,name=vdagent", "-device", "virtserialport,chardev=vdagent,name=com.redhat.spice.0",
            "-chardev", "socket,id=qga,path=\(escaped(socket.appendingPathComponent("agent.sock").path)),server=on,wait=off",
            "-device", "virtserialport,chardev=qga,name=org.qemu.guest_agent.0",
            "-qmp", "unix:\(socket.appendingPathComponent("qmp.sock").path),server=on,wait=off",
            "-vga", "none", "-spice",
            "unix=on,addr=\(escaped(socket.appendingPathComponent("spice.sock").path)),disable-ticketing=on,gl=\(config.graphics != .basic ? "es" : "off")",
            "-device",
            config.graphics == .neptune
                ? "virtio-ramfb-gl,hostmem=8G,blob=true,neptune=true"
                : config.operatingSystem == .windows ? "virtio-ramfb" : (config.graphics == .virgl ? "virtio-gpu-gl-pci" : "virtio-gpu-pci"),
        ]
        if config.operatingSystem == .omarchy {
            guard let boot = config.omarchyBoot else { throw MachineError.invalid("Omarchy machine is missing its paired boot metadata") }
            for filename in ["vmlinuz-linux", "initramfs-linux.img"] {
                guard FileManager.default.fileExists(atPath: bundle.appendingPathComponent("state/" + filename).path) else {
                    throw MachineError.invalid("Missing Omarchy boot artifact: \(filename)")
                }
            }
            // Direct-boot kernel arguments are separate argv values, not QEMU
            // comma-separated option strings. Preserve commas in these paths.
            arguments += [
                "-chardev", "file,id=omarchy-console,path=\(path("omarchy-console.log"))",
                "-device", "virtconsole,chardev=omarchy-console",
                "-kernel", bundle.appendingPathComponent("state/vmlinuz-linux").path,
                "-initrd", bundle.appendingPathComponent("state/initramfs-linux.img").path,
                "-append", boot.kernelCommandLine + " console=ttyAMA0 omarchy.qemu_virgl=1" + (config.sshPort != nil ? " tryomarchy.ssh_access=1" : ""),
            ]
        }
        arguments += ["-chardev", "spiceport,id=webdav,name=org.spice-space.webdav.0", "-device", "virtserialport,chardev=webdav,name=org.spice-space.webdav.0"]
        if config.audioEnabled == true { arguments += ["-audiodev", "coreaudio,id=audio0", "-device", "intel-hda", "-device", "hda-output,audiodev=audio0"] }
        if config.usbEnabled == true {
            for index in 0..<3 { arguments += ["-chardev", "spicevmc,id=usbredir\(index),name=usbredir", "-device", "usb-redir,chardev=usbredir\(index),id=usbredirdev\(index)"] }
        }
        if config.operatingSystem.isLinux { arguments += ["-serial", "file:\(path("console.log"))"] }
        if config.operatingSystem == .windows {
            arguments += ["-S"]  // Attach SPICE before firmware draws and before the ISO boot prompt.
            arguments += [
                "-chardev", "socket,id=tpm,path=\(escaped(socket.appendingPathComponent("tpm.sock").path))",
                // The ARM virt platform exposes a CRB TPM interface to Windows.
                "-tpmdev", "emulator,id=tpm0,chardev=tpm", "-device", "tpm-crb-device,tpmdev=tpm0",
            ]
        }
        if config.installationMedia {
            arguments += [
                "-drive", "if=none,id=install,media=cdrom,readonly=on,file=\(path("install.iso"))",
                "-device", (config.operatingSystem == .windows ? "usb-storage,drive=install,bootindex=1" : "scsi-cd,bus=scsi.0,drive=install,bootindex=1"),
            ]
        }
        if config.seedMedia {
            arguments += [
                "-drive", "if=none,id=seed,media=cdrom,readonly=on,file=\(path("seed.iso"))", "-device",
                (config.operatingSystem == .windows ? "usb-storage,drive=seed" : "scsi-cd,bus=scsi.0,drive=seed"),
            ]
        }
        return arguments
    }
}
