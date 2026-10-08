import ArgumentParser
import Foundation
import GlassDockMachines

struct Machines: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "machines", abstract: "Manage Linux, Omarchy Quattro, and Windows ARM virtual machines.",
        subcommands: [
            List.self, Create.self, Configure.self, Start.self, Stop.self, PowerOff.self, Pause.self, Resume.self, Clone.self, Snapshot.self, Restore.self, Snapshots.self,
            Export.self, Import.self, Exec.self, Logs.self, Media.self, Memory.self,
        ])

    struct Location: ParsableArguments {
        @Option(help: "Machine library location.") var library: String = MachineStore.defaultRoot.path
        func store() throws -> MachineStore { try MachineStore(root: URL(fileURLWithPath: library), runtime: MachineRuntime.discover()) }
    }
    struct Target: ParsableArguments {
        @OptionGroup var location: Location
        @Argument(help: "Machine UUID or exact name.") var machine: String
        func resolved() throws -> (MachineStore, UUID) {
            let store = try location.store()
            return (store, try store.resolve(machine))
        }
    }
    struct List: ParsableCommand {
        @OptionGroup var location: Location
        func run() throws {
            let store = try location.store()
            for config in try store.list() { print("\(config.id)\t\(config.name)\t\(config.operatingSystem.rawValue)\t\(store.status(config.id))") }
        }
    }
    struct Create: ParsableCommand {
        @OptionGroup var location: Location
        @Argument var name: String
        @Option(help: "linux, windows, or omarchy (Quattro ARM64)") var os: String = "linux"
        @Option var cpus: Int = 4
        @Option var memory: Int = 4096
        @Option var sshPort: Int?
        @Option var diskSize: Int = 64
        @Option(help: "Existing disk image to import and flatten.") var disk: String?
        @Option(help: "ARM64 installation ISO.") var iso: String?
        @Option(help: "Cloud-init seed ISO.") var seed: String?
        @Option(help: "Prepared Omarchy ARM64 factory guest folder (scripts/machines/prepare-omarchy.sh).") var omarchyGuest: String?
        func run() throws {
            guard let operatingSystem = MachineOS(rawValue: os) else { throw ValidationError("Choose linux, windows, or omarchy") }
            var config = MachineConfiguration(name: name, operatingSystem: operatingSystem, cpuCount: cpus, memoryMiB: memory, diskGiB: diskSize)
            config.sshPort = sshPort
            let created = try location.store().create(
                config, disk: disk.map { URL(fileURLWithPath: $0) }, media: iso.map { URL(fileURLWithPath: $0) }, seed: seed.map { URL(fileURLWithPath: $0) },
                omarchyGuest: omarchyGuest.map { URL(fileURLWithPath: $0) })
            print(created.id.uuidString)
        }
    }
    struct Configure: ParsableCommand {
        @OptionGroup var target: Target
        @Option var cpus: Int?
        @Option var memory: Int?
        @Option(help: "basic, virgl (Linux), or neptune (Windows experimental)") var graphics: String?
        @Option var audio: Bool?
        @Option var usb: Bool?
        func run() throws {
            let (store, id) = try target.resolved()
            let profile = graphics.flatMap(MachineGraphics.init(rawValue:))
            if graphics != nil && profile == nil { throw ValidationError("Choose basic, virgl, or neptune") }
            try store.configure(id, cpuCount: cpus, memoryMiB: memory, graphics: profile, audioEnabled: audio, usbEnabled: usb)
        }
    }
    struct Media: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Mount or eject existing ISO media on a stopped machine.")
        @OptionGroup var target: Target
        @Option(help: "true to mount, false to eject the installation ISO") var installation: Bool?
        @Option(help: "true to mount, false to eject the guest tools or cloud-init ISO") var seed: Bool?
        func run() throws {
            let (store, id) = try target.resolved()
            try store.setMediaMounted(id, installation: installation, seed: seed)
        }
    }
    struct Start: ParsableCommand {
        @OptionGroup var target: Target
        @Option(help: "Resume a saved RAM checkpoint instead of cold booting.") var memorySnapshot: String?
        func run() throws {
            let (store, id) = try target.resolved()
            try store.start(id, memorySnapshot: memorySnapshot)
            print("Started \(id)")
        }
    }
    struct Stop: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Request an orderly guest shutdown.")
        @OptionGroup var target: Target
        func run() throws {
            let (store, id) = try target.resolved()
            try store.shutdown(id)
            print("Shutdown requested")
        }
    }
    struct PowerOff: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Power off immediately; unsaved guest data can be lost.")
        @OptionGroup var target: Target
        func run() throws {
            let (store, id) = try target.resolved()
            try store.powerOff(id)
            print("Power off requested")
        }
    }
    struct Pause: ParsableCommand {
        @OptionGroup var target: Target
        func run() throws {
            let (store, id) = try target.resolved()
            try store.control(id).command("stop")
        }
    }
    struct Resume: ParsableCommand {
        @OptionGroup var target: Target
        func run() throws {
            let (store, id) = try target.resolved()
            try store.control(id).command("cont")
        }
    }
    struct Clone: ParsableCommand {
        @OptionGroup var target: Target
        @Argument var name: String
        func run() throws {
            let (store, id) = try target.resolved()
            print(try store.clone(id, name: name).id.uuidString)
        }
    }
    struct Snapshot: ParsableCommand {
        @OptionGroup var target: Target
        @Argument var name: String
        func run() throws {
            let (store, id) = try target.resolved()
            try store.snapshot(id, name: name)
            print("Created stopped snapshot \(name)")
        }
    }
    struct Restore: ParsableCommand {
        @OptionGroup var target: Target
        @Argument var name: String
        func run() throws {
            let (store, id) = try target.resolved()
            try store.restore(id, name: name)
            print("Restored \(name)")
        }
    }
    struct Snapshots: ParsableCommand {
        @OptionGroup var target: Target
        func run() throws {
            let (store, id) = try target.resolved()
            for name in try store.snapshots(id) { print(name) }
        }
    }
    struct Export: ParsableCommand {
        @OptionGroup var target: Target
        @Argument var destination: String
        @Flag(help: "Export a checksummed folder preserving sparse files, instead of ZIP.") var directory = false
        @Flag(help: "Compress QCOW2 clusters for a smaller extracted machine.") var compact: Bool = false
        func run() throws {
            let (store, id) = try target.resolved()
            if directory {
                try store.exportDirectory(id, to: URL(fileURLWithPath: destination))
            } else {
                try store.export(id, to: URL(fileURLWithPath: destination), compact: compact)
            }
            print(destination)
        }
    }
    struct Import: ParsableCommand {
        @OptionGroup var location: Location
        @Argument var source: String
        @Option var name: String?
        func run() throws { print(try location.store().importArchive(URL(fileURLWithPath: source), name: name).id.uuidString) }
    }
    struct Exec: ParsableCommand {
        @OptionGroup var target: Target
        @Argument(parsing: .remaining, help: "Guest executable followed by its arguments.") var command: [String]
        func run() throws {
            let (_, id) = try target.resolved()
            guard let path = command.first else { throw ValidationError("Specify a guest executable") }
            let result = try GuestAgent(id: id).execute(path: path, arguments: Array(command.dropFirst()))
            FileHandle.standardOutput.write(Data(result.stdout.utf8))
            FileHandle.standardError.write(Data(result.stderr.utf8))
            if result.exitCode != 0 { throw ExitCode(Int32(result.exitCode)) }
        }
    }
    struct Memory: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Save, restore, list, or delete local RAM checkpoints (basic graphics only).")
        @OptionGroup var target: Target
        @Argument var operation: String
        @Argument var name: String?
        func run() throws {
            let (store, id) = try target.resolved()
            if operation == "list" {
                for checkpoint in try store.memorySnapshots(id) { print(checkpoint) }
                return
            }
            guard let name else { throw ValidationError("Specify a checkpoint name") }
            switch operation {
            case "save": try store.saveMemorySnapshot(id, name: name)
            case "restore": try store.restoreMemorySnapshot(id, name: name)
            case "delete": try store.deleteMemorySnapshot(id, name: name)
            default: throw ValidationError("Choose save, restore, list, or delete")
            }
        }
    }
    struct Logs: ParsableCommand {
        @OptionGroup var target: Target
        func run() throws {
            let (store, id) = try target.resolved()
            for name in ["supervisor.log", "state/console.log", "state/omarchy-console.log"] {
                let data = (try? Data(contentsOf: store.bundle(id).appendingPathComponent(name))) ?? Data()
                print("== \(name) ==\n\(String(decoding: data.suffix(32768), as: UTF8.self))")
            }
        }
    }
}
