import Vapor

// NOTE: Doesn't attempt to mimic fully the schema
//       https://docs.docker.com/reference/api/engine/version/v1.51/#tag/System/operation/SystemAuth
//       Things that should be revisited in the future
//       - Driver + Driver Status (storage)
//       - Plugins
//       - Registry config
//       - Init binary + commit
//       - Default network address pool
struct SystemInfo: Content {
    var ID: String? = nil
    var Containers: Int
    var ContainersRunning: Int
    /// NOTE: Apple container doesn't support pausing containers
    var ContainersPaused: Int
    var ContainersStopped: Int
    var Images: Int
    var Driver: String? = nil
    var DriverStatus: [[String]]? = nil
    var DockerRootDir: String
    var Plugins: PluginsInfo? = nil
    var MemoryLimit: Bool? = nil
    var SwapLimit: Bool? = nil
    var KernelMemoryTCP: Bool? = nil
    var CpuCfsPeriod: Bool? = nil
    var CpuCfsQuota: Bool? = nil
    var CPUShares: Bool? = nil
    var CPUSet: Bool? = nil
    var PidsLimit: Bool? = nil
    var OomKillDisable: Bool? = nil
    var IPv4Forwarding: Bool? = nil
    var Debug: Bool
    var KernelVersion: String
    var OSVersion: String?
    var OSType: String
    var OperatingSystem: String? = nil
    var Architecture: String
    var NCPU: Int
    var MemTotal: Int64
    var HttpProxy: String?
    var HttpsProxy: String?
    var NoProxy: String?
    var Name: String
    // NOTE: Consider enabling user to define labels
    var Labels: [String]?
    var ExperimentalBuild: Bool
    var ServerVersion: String
    var IndexServerAddress: String? = nil
    var LoggingDriver: String? = nil
    var CgroupDriver: String? = nil
    var CgroupVersion: String? = nil
    var SecurityOptions: [String]? = nil
    // NOTE: In Apple container, each container uses a dedicated runtime
    // var Runtimes: [String: Runtime]
    // var DefaultRuntime: String
    var ProductLicense: String
    var SystemTime: String
    var Warnings: [String]
}

struct PluginsInfo: Content {
    var Volume: [String] = []
    var Network: [String] = []
    var Authorization: [String] = []
    var Log: [String] = []
}

// NOTE: In Apple container, each container uses a dedicated runtime
// struct Runtime: Content {
//     var path: String
// }

// NOTE: Doesn't attempt to mimic fully the schema
// https://docs.docker.com/reference/api/engine/version/v1.51/#tag/System/operation/SystemVersion
struct VersionInfo: Content {
    var Platform: ServerPlatform
    var Components: [Component]
    var Version: String
    var ApiVersion: String
    var MinAPIVersion: String
    var GitCommit: String
    var Os: String
    var Arch: String
    var KernelVersion: String
    var Experimental: Bool
    var BuildTime: String

}

struct ServerPlatform: Content {
    var Name: String
}

struct Component: Content {
    var Name: String
    var Version: String
}
