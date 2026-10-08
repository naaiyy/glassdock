import Foundation
import Virtualization

/// Files needed to cold boot an Apple Silicon Mac. The hardware model, machine
/// identifier and auxiliary storage are a single persistent platform identity.
public enum MacOSGuest {
    public static let bootFiles = ["disk.raw", "hardware-model.bin", "machine-identifier.bin", "auxiliary-storage"]
    public static let installedMarker = "macos-installed"

    public static func validateState(at state: URL, installed: Bool) throws {
        let required = bootFiles + (installed ? [installedMarker] : ["restore.ipsw"])
        for name in required {
            let values = try state.appendingPathComponent(name).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) > 0 else {
                throw MachineError.invalid("Missing or unsafe macOS state: \(name)")
            }
        }
        for name in ["hardware-model.bin", "machine-identifier.bin", installedMarker] {
            let file = state.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) {
                guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 1024 * 1024 else {
                    throw MachineError.invalid("macOS platform metadata exceeds its size limit")
                }
            }
        }
        #if arch(arm64)
        guard let model = VZMacHardwareModel(dataRepresentation: try Data(contentsOf: state.appendingPathComponent("hardware-model.bin"))), model.isSupported,
            VZMacMachineIdentifier(dataRepresentation: try Data(contentsOf: state.appendingPathComponent("machine-identifier.bin"))) != nil
        else { throw MachineError.invalid("This Mac cannot run the archived macOS platform identity") }
        #else
        throw MachineError.invalid("macOS guests require Apple Silicon")
        #endif
    }

    public static func newIdentity(at state: URL) throws {
        #if arch(arm64)
        try VZMacMachineIdentifier().dataRepresentation.write(to: state.appendingPathComponent("machine-identifier.bin"), options: .atomic)
        #else
        throw MachineError.invalid("macOS guests require Apple Silicon")
        #endif
    }

    #if arch(arm64)
    @MainActor public static func prepare(_ config: MachineConfiguration, bundle: URL, restoreImage: URL) async throws {
        try config.validate()
        guard config.operatingSystem == .macos, VZVirtualMachine.isSupported, restoreImage.isFileURL else {
            throw MachineError.invalid("macOS virtualization requires an Apple Silicon Mac and a local IPSW restore image")
        }
        let image = try await VZMacOSRestoreImage.image(from: restoreImage)
        guard let requirements = image.mostFeaturefulSupportedConfiguration else {
            throw MachineError.invalid("This IPSW does not support macOS virtualization on this host")
        }
        guard config.cpuCount >= requirements.minimumSupportedCPUCount,
            UInt64(config.memoryMiB) * 1024 * 1024 >= requirements.minimumSupportedMemorySize
        else {
            throw MachineError.invalid(
                "This IPSW needs at least \(requirements.minimumSupportedCPUCount) CPUs and \(requirements.minimumSupportedMemorySize / 1024 / 1024) MiB RAM")
        }
        let state = bundle.appendingPathComponent("state")
        let fm = FileManager.default
        try fm.createDirectory(at: state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try requirements.hardwareModel.dataRepresentation.write(to: state.appendingPathComponent("hardware-model.bin"))
        try newIdentity(at: state)
        _ = try VZMacAuxiliaryStorage(creatingStorageAt: state.appendingPathComponent("auxiliary-storage"), hardwareModel: requirements.hardwareModel)
        let disk = state.appendingPathComponent("disk.raw")
        guard fm.createFile(atPath: disk.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw MachineError.command("Cannot create macOS disk") }
        let handle = try FileHandle(forWritingTo: disk)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(config.diskGiB) * 1024 * 1024 * 1024)
        try fm.copyItem(at: restoreImage, to: state.appendingPathComponent("restore.ipsw"))
        _ = try configuration(config, bundle: bundle)
    }

    @MainActor public static func configuration(_ config: MachineConfiguration, bundle: URL) throws -> VZVirtualMachineConfiguration {
        try config.validate()
        guard config.operatingSystem == .macos else { throw MachineError.invalid("Expected a macOS machine") }
        let state = bundle.appendingPathComponent("state")
        try validateState(at: state, installed: FileManager.default.fileExists(atPath: state.appendingPathComponent(installedMarker).path))
        let result = VZVirtualMachineConfiguration()
        result.cpuCount = config.cpuCount
        result.memorySize = UInt64(config.memoryMiB) * 1024 * 1024
        result.bootLoader = VZMacOSBootLoader()
        let platform = VZMacPlatformConfiguration()
        guard let model = VZMacHardwareModel(dataRepresentation: try Data(contentsOf: state.appendingPathComponent("hardware-model.bin"))),
            let identifier = VZMacMachineIdentifier(dataRepresentation: try Data(contentsOf: state.appendingPathComponent("machine-identifier.bin")))
        else {
            throw MachineError.invalid("Invalid macOS platform identity")
        }
        platform.hardwareModel = model
        platform.machineIdentifier = identifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: state.appendingPathComponent("auxiliary-storage"))
        result.platform = platform
        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 1920, heightInPixels: 1200, pixelsPerInch: 144)]
        result.graphicsDevices = [graphics]
        result.keyboards = [VZMacKeyboardConfiguration()]
        result.pointingDevices = [VZMacTrackpadConfiguration()]
        let disk = try VZDiskImageStorageDeviceAttachment(url: state.appendingPathComponent("disk.raw"), readOnly: false, cachingMode: .automatic, synchronizationMode: .full)
        result.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]
        let network = VZVirtioNetworkDeviceConfiguration()
        network.macAddress = VZMACAddress(string: config.macAddress)!
        network.attachment = VZNATNetworkDeviceAttachment()
        result.networkDevices = [network]
        if config.audioEnabled == true {
            let audio = VZVirtioSoundDeviceConfiguration()
            let output = VZVirtioSoundDeviceOutputStreamConfiguration()
            output.sink = VZHostAudioOutputStreamSink()
            audio.streams = [output]
            result.audioDevices = [audio]
        }
        let sharing = VZVirtioFileSystemDeviceConfiguration(tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
        result.directorySharingDevices = [sharing]
        try result.validate()
        return result
    }
    #endif
}
