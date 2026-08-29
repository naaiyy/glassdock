import Darwin
import Foundation

/// Single source of truth for where Glass Dock keeps things on disk.
///
/// Three location conventions exist, each for a different reason:
///
/// 1. `~/.glassdock` — the user-facing directory under the daemon's host
///    home. It holds the public Docker socket (`container.sock`, world
///    readable but guarded by its 0700 parent), the private backend socket
///    (`daemon.sock`), the builder relay socket (`builder.sock`), and the
///    optional `glassdock` Docker client context. It lives under the user's
///    home so per-user permission scoping is possible.
/// 2. Engine state — `/Users/Shared/.glassdock-<uid>` by default. It holds
///    `data.ext4` (the guest's persistent disk) and `engine.lock`. It must
///    not sit inside the exported bind mount source (the whole home
///    directory), so it stays outside the home while remaining writable by
///    the console user.
/// 3. `/opt/glassdock` — the installer's read-only prefix for the daemon,
///    helpers, kernel, and root disk. Never written to at runtime.
///
/// Test and development instances must override locations 1 and 2 instead of
/// touching a production daemon's directories:
///
/// - `GLASSDOCK_HOST_HOME_DIRECTORY` replaces the host home (and therefore
///   `~/.glassdock`);
/// - `GLASSDOCK_ENGINE_STATE_DIRECTORY` replaces the engine state directory;
/// - `make dev-daemon` wires both to `.build/glassdock-dev` automatically.
///
/// The VMM helper also derives ephemeral control sockets from the state
/// directory generation under `/tmp/glassdock-vmm-<generation>`; those live
/// only as long as one VM boot.
enum GlassDockDirectories {
    /// Read-only runtime prefix used by the package installer.
    static let installPrefix = "/opt/glassdock"

    static var hostHome: URL {
        hostHome(environment: ProcessInfo.processInfo.environment)
    }

    static var engineStateDirectory: URL {
        engineStateDirectory(environment: ProcessInfo.processInfo.environment)
    }

    /// The `~/.glassdock` directory inside the given host home.
    static func glassdockDirectory(home: URL) -> URL {
        home.appendingPathComponent(".glassdock", isDirectory: true)
    }

    static func engineStateDirectory(
        environment: [String: String],
        userID: uid_t = getuid()
    ) -> URL {
        if let override = environment["GLASSDOCK_ENGINE_STATE_DIRECTORY"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }
        return URL(
            fileURLWithPath: "/Users/Shared/.glassdock-\(userID)",
            isDirectory: true
        )
    }

    static func hostHome(
        environment: [String: String],
        fallback: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let override = environment["GLASSDOCK_HOST_HOME_DIRECTORY"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }
        return fallback
    }
}
