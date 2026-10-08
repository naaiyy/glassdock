import CryptoKit
import Foundation

/// The kernel and initramfs are paired with the factory disk and travel with
/// snapshots, clones, and exports. Guest package updates must not replace them.
public struct OmarchyBoot: Codable, Equatable, Sendable {
    public var release: String
    public var upstreamCommit: String
    public var kernelCommandLine: String

    public func validate() throws {
        guard release.hasPrefix("4."), upstreamCommit.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil,
            kernelCommandLine.utf8.count <= 4096,
            kernelCommandLine.split(separator: " ").contains("root=/dev/vda"),
            !kernelCommandLine.contains("\n"), !kernelCommandLine.contains("\0")
        else { throw MachineError.invalid("Unsupported Omarchy Quattro boot metadata") }
    }
}

public enum OmarchyGuest {
    public static let bootFiles = ["vmlinuz-linux", "initramfs-linux.img", "guest-manifest.json", "build-spec.json", "provenance.json", "LICENSE.omarchy"]

    private struct Manifest: Decodable {
        struct Guest: Decodable {
            var architecture: String
            var profile: String
            var kernelCommandLine: String
        }
        struct Upstream: Decodable {
            var release: String
            var commit: String
            var channel: String
        }
        struct Artifact: Decodable {
            var path: String
            var bytes: UInt64
            var sha256: String
        }
        var schemaVersion: Int
        var kind: String
        var guest: Guest
        var upstream: Upstream
        var artifacts: [Artifact]
    }

    /// Accept only the ARM64 factory profile, checking every file we consume.
    /// The download script pins the enclosing DMG digest; this also detects
    /// damaged or mismatched local factory inputs before publishing a machine.
    public static func inspect(_ directory: URL) throws -> OmarchyBoot {
        let manifestURL = directory.appendingPathComponent("guest-manifest.json")
        let values = try manifestURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) <= 2 * 1024 * 1024 else {
            throw MachineError.invalid("Invalid Omarchy guest manifest")
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.schemaVersion == 1, manifest.kind == "try-omarchy-guest-artifacts",
            manifest.guest.architecture == "aarch64", manifest.guest.profile == "factory", manifest.upstream.channel == "quattro"
        else { throw MachineError.invalid("Choose an ARM64 Omarchy Quattro factory guest") }
        for filename in ["rootfs.ext4"] + bootFiles.filter({ $0 != "guest-manifest.json" }) {
            let matches = manifest.artifacts.filter { $0.path == filename }
            guard matches.count == 1, let artifact = matches.first,
                artifact.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
            else { throw MachineError.invalid("Missing Omarchy artifact: \(filename)") }
            let url = directory.appendingPathComponent(filename)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, UInt64(values.fileSize ?? 0) == artifact.bytes else {
                throw MachineError.invalid("Invalid Omarchy artifact: \(filename)")
            }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var hash = SHA256()
            while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
            guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == artifact.sha256 else {
                throw MachineError.invalid("Omarchy checksum mismatch: \(filename)")
            }
        }
        let boot = OmarchyBoot(release: manifest.upstream.release, upstreamCommit: manifest.upstream.commit, kernelCommandLine: manifest.guest.kernelCommandLine)
        try boot.validate()
        return boot
    }
}
