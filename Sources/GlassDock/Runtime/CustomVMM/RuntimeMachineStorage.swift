import ContainerizationEXT4
import Foundation
import SystemPackage

protocol RuntimeMachineStoragePreparing: Sendable {
    func prepareDataDisk(at url: URL) throws
}

struct FoundationRuntimeMachineStoragePreparer: RuntimeMachineStoragePreparing {
    func prepareDataDisk(at url: URL) throws {
        try RuntimeMachineStorage.prepareDataDisk(at: url)
    }
}

enum RuntimeMachineStorage {
    static let dataDiskSize: UInt64 = 1024 * 1024 * 1024

    static func prepareDataDisk(at url: URL, size: UInt64 = dataDiskSize) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if fileManager.fileExists(atPath: url.path) {
            do {
                let reader = try EXT4.EXT4Reader(blockDevice: FilePath(url.path))
                let hasOrderedJournal =
                    reader.superBlock.featureCompat & 0x4 != 0
                    && reader.superBlock.journalInum == 8
                    && reader.superBlock.defaultMountOpts == 0x40
                let isUnjournaled = reader.superBlock.featureCompat & 0x4 == 0
                if hasOrderedJournal || isUnjournaled {
                    try restoreFilesystemGeometry(of: reader, at: url)
                    return
                }
                throw RuntimeMachineStorageError.incompatibleDataDisk
            } catch RuntimeMachineStorageError.incompatibleDataDisk {
                let quarantine = url.deletingLastPathComponent()
                    .appendingPathComponent("data.ext4.incompatible-\(UUID().uuidString)")
                try fileManager.moveItem(at: url, to: quarantine)
            }
        }
        let staging = url.deletingLastPathComponent()
            .appendingPathComponent(".data-\(UUID().uuidString).ext4")
        do {
            let formatter = try EXT4.Formatter(
                FilePath(staging.path),
                minDiskSize: size
            )
            try formatter.close()
            try fileManager.moveItem(at: staging, to: url)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    private static func restoreFilesystemGeometry(of reader: EXT4.EXT4Reader, at url: URL) throws {
        let blockCount =
            UInt64(reader.superBlock.blocksCountLow)
            | (UInt64(reader.superBlock.blocksCountHigh) << 32)
        let (requiredSize, overflow) = blockCount.multipliedReportingOverflow(
            by: UInt64(reader.superBlock.blockSize)
        )
        guard !overflow else { return }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let currentSize = (attributes[.size] as? NSNumber)?.uint64Value,
            currentSize < requiredSize
        else { return }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: requiredSize)
    }
}

private enum RuntimeMachineStorageError: Error {
    case incompatibleDataDisk
}
