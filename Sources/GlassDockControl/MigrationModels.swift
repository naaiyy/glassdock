import Foundation

public struct MigrationOptions: Sendable, Equatable {
    public var sourceSocketPath: String
    public var includeImages: Bool
    public var includeVolumes: Bool
    public var includeNetworks: Bool
    public var includeContainers: Bool
    public var includeStoppedContainers: Bool
    public var dryRun: Bool
    public var helperImage: String
    public var dockerCLI: String
    /// Migrate only items carrying this Docker label ("key" or "key=value").
    /// When set, items without the label are skipped. nil migrates everything.
    public var filterLabel: String?

    public init(
        sourceSocketPath: String? = nil,
        includeImages: Bool = true,
        includeVolumes: Bool = true,
        includeNetworks: Bool = true,
        includeContainers: Bool = true,
        includeStoppedContainers: Bool = true,
        dryRun: Bool = false,
        helperImage: String = "busybox:1.37.0",
        dockerCLI: String = "/usr/local/bin/docker",
        filterLabel: String? = nil
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.sourceSocketPath =
            sourceSocketPath
            ?? "\(home)/.docker/run/docker.sock"
        self.includeImages = includeImages
        self.includeVolumes = includeVolumes
        self.includeNetworks = includeNetworks
        self.includeContainers = includeContainers
        self.includeStoppedContainers = includeStoppedContainers
        self.dryRun = dryRun
        self.helperImage = helperImage
        self.dockerCLI = dockerCLI
        self.filterLabel = filterLabel
    }
}

public enum MigrationPhase: String, Codable, Sendable {
    case inventory
    case images
    case volumes
    case networks
    case containers
    case complete
}

public struct MigrationEvent: Codable, Sendable, Equatable {
    public let phase: MigrationPhase
    public let detail: String

    public init(phase: MigrationPhase, detail: String) {
        self.phase = phase
        self.detail = detail
    }
}

public struct MigrationInventory: Codable, Sendable, Equatable {
    public var imageReferences: [String]
    public var containerNames: [String]
    public var volumeNames: [String]
    public var networkNames: [String]

    public init(
        imageReferences: [String] = [],
        containerNames: [String] = [],
        volumeNames: [String] = [],
        networkNames: [String] = []
    ) {
        self.imageReferences = imageReferences
        self.containerNames = containerNames
        self.volumeNames = volumeNames
        self.networkNames = networkNames
    }
}

public struct MigrationItemResult: Codable, Sendable, Equatable {
    public let name: String
    public let action: MigrationItemAction
    public let detail: String?

    public init(name: String, action: MigrationItemAction, detail: String? = nil) {
        self.name = name
        self.action = action
        self.detail = detail
    }
}

public enum MigrationItemAction: String, Codable, Sendable {
    case migrated
    case skipped
    case failed
}

public struct MigrationCategoryReport: Codable, Sendable, Equatable {
    public var migrated: [MigrationItemResult]
    public var skipped: [MigrationItemResult]
    public var failed: [MigrationItemResult]

    public init() {
        self.migrated = []
        self.skipped = []
        self.failed = []
    }

    public var isEmpty: Bool {
        migrated.isEmpty && skipped.isEmpty && failed.isEmpty
    }
}

public struct MigrationReport: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let generatedAt: Date
    public let sourceSocketPath: String
    public let targetSocketPath: String
    public let dryRun: Bool
    public let inventory: MigrationInventory
    public var images: MigrationCategoryReport
    public var volumes: MigrationCategoryReport
    public var networks: MigrationCategoryReport
    public var containers: MigrationCategoryReport
    public var warnings: [String]

    public init(
        generatedAt: Date = Date(),
        sourceSocketPath: String,
        targetSocketPath: String,
        dryRun: Bool,
        inventory: MigrationInventory
    ) {
        self.schemaVersion = MigrationReport.currentSchemaVersion
        self.generatedAt = generatedAt
        self.sourceSocketPath = sourceSocketPath
        self.targetSocketPath = targetSocketPath
        self.dryRun = dryRun
        self.inventory = inventory
        self.images = MigrationCategoryReport()
        self.volumes = MigrationCategoryReport()
        self.networks = MigrationCategoryReport()
        self.containers = MigrationCategoryReport()
        self.warnings = []
    }

    public var succeeded: Bool {
        images.failed.isEmpty && volumes.failed.isEmpty
            && networks.failed.isEmpty && containers.failed.isEmpty
    }

    public func text() -> String {
        var lines = [
            "Migration \(dryRun ? "plan" : "report")",
            "Source: \(sourceSocketPath)",
            "Target: \(targetSocketPath)",
            "",
            "Inventory",
            "  Images: \(inventory.imageReferences.count)",
            "  Containers: \(inventory.containerNames.count)",
            "  Volumes: \(inventory.volumeNames.count)",
            "  Networks: \(inventory.networkNames.count)",
            "",
        ]
        for (label, report) in [("Images", images), ("Volumes", volumes), ("Networks", networks), ("Containers", containers)] {
            if report.isEmpty { continue }
            lines.append("\(label)")
            for item in report.migrated {
                lines.append("  migrated: \(item.name)\(item.detail.map { " — \($0)" } ?? "")")
            }
            for item in report.skipped {
                lines.append("  skipped:  \(item.name)\(item.detail.map { " — \($0)" } ?? "")")
            }
            for item in report.failed {
                lines.append("  FAILED:   \(item.name)\(item.detail.map { " — \($0)" } ?? "")")
            }
            lines.append("")
        }
        if !warnings.isEmpty {
            lines.append("Warnings")
            for warning in warnings {
                lines.append("  ! \(warning)")
            }
            lines.append("")
        }
        lines.append(succeeded ? "Result: completed without failures." : "Result: completed with failures. Review the FAILED entries above.")
        return lines.joined(separator: "\n")
    }
}

public enum MigrationError: LocalizedError, Sendable {
    case sourceEngineUnavailable(String)
    case targetEngineUnavailable(String)
    case dockerCLIMissing(String)
    case volumeCopyFailed(volume: String, stage: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .sourceEngineUnavailable(let message):
            return "The source Docker engine is unreachable: \(message)"
        case .targetEngineUnavailable(let message):
            return "The Glass Dock engine is unreachable: \(message)"
        case .dockerCLIMissing(let path):
            return "The docker CLI is required to migrate volume data but was not found at \(path)."
        case .volumeCopyFailed(let volume, let stage, let message):
            return "Volume '\(volume)' data copy failed during \(stage): \(message)"
        }
    }
}
