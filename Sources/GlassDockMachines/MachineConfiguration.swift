import Foundation

public enum MachineOS: String, Codable, CaseIterable, Sendable { case linux, windows }
public enum MachineGraphics: String, Codable, CaseIterable, Sendable { case basic, virgl, neptune }

public struct MachineConfiguration: Codable, Identifiable, Equatable, Sendable {
    public var schemaVersion = 1
    public var id: UUID
    public var name: String
    public var operatingSystem: MachineOS
    public var cpuCount: Int
    public var memoryMiB: Int
    public var diskGiB: Int
    public var sshPort: Int?
    public var graphics: MachineGraphics = .basic
    public var macAddress: String
    // Media is copied into the machine bundle. No host path survives export.
    public var installationMedia: Bool = false
    public var seedMedia: Bool = false
    public var audioEnabled: Bool?
    public var usbEnabled: Bool?
    public var createdAt: Date = Date()

    public init(name: String, operatingSystem: MachineOS, cpuCount: Int = 4, memoryMiB: Int = 4096, diskGiB: Int = 64) {
        id = UUID()
        self.name = name
        self.operatingSystem = operatingSystem
        self.cpuCount = cpuCount
        self.memoryMiB = memoryMiB
        self.diskGiB = diskGiB
        macAddress = Self.newMAC()
    }

    public func validate() throws {
        guard schemaVersion == 1 else { throw MachineError.invalid("Unsupported machine schema") }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 128 else {
            throw MachineError.invalid("Machine name must contain 1–128 characters")
        }
        guard (1...64).contains(cpuCount), (512...262144).contains(memoryMiB), (8...2048).contains(diskGiB) else {
            throw MachineError.invalid("Invalid CPU, memory, or disk size")
        }
        guard macAddress.range(of: "^02(:[0-9a-fA-F]{2}){5}$", options: .regularExpression) != nil else {
            throw MachineError.invalid("Invalid locally administered MAC address")
        }
        if let sshPort, !(1024...65535).contains(sshPort) { throw MachineError.invalid("Invalid SSH port") }
        if operatingSystem == .linux && graphics == .neptune { throw MachineError.invalid("Neptune is a Windows graphics profile") }
        if operatingSystem == .windows && graphics == .virgl {
            throw MachineError.invalid("The VirGL profile currently supports Linux only")
        }
        if operatingSystem == .windows && (memoryMiB < 4096 || cpuCount < 2 || diskGiB < 64) {
            throw MachineError.invalid("Windows requires at least 2 CPUs, 4096 MiB RAM, and 64 GiB disk")
        }
    }

    public static func newMAC() -> String {
        "02:" + (0..<5).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined(separator: ":")
    }
}

public enum MachineError: LocalizedError {
    case invalid(String)
    case busy
    case runtimeMissing(String)
    case command(String)
    public var errorDescription: String? {
        switch self {
        case .invalid(let message), .runtimeMissing(let message), .command(let message): message
        case .busy: "Machine is running or another operation is in progress. Shut it down first."
        }
    }
}
