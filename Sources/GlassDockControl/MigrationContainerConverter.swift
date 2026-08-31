import Foundation

/// Converts a Docker container inspect payload from the source engine into a
/// container create request payload for the target engine. Pure and testable:
/// no I/O, no engine calls. Unsupported source features become warnings and
/// are omitted from the request.
public enum MigrationContainerConverter {

    public static func makeCreateRequest(
        inspect: [String: Any],
        migratedVolumeNames: Set<String>,
        warnings: inout [String]
    ) -> [String: Any]? {
        let config = inspect["Config"] as? [String: Any] ?? [:]
        let hostConfig = inspect["HostConfig"] as? [String: Any] ?? [:]

        guard let image = config["Image"] as? String, !image.isEmpty else {
            warnings.append("Container has no image reference; it cannot be recreated.")
            return nil
        }

        var body: [String: Any] = ["Image": image]

        copyString(config, "WorkingDir", into: &body, as: "WorkingDir")
        copyString(config, "User", into: &body, as: "User")
        copyString(config, "StopSignal", into: &body, as: "StopSignal")
        copyStringArray(config, "Env", into: &body, as: "Env")
        copyStringArray(config, "Cmd", into: &body, as: "Cmd")
        copyStringArray(config, "Entrypoint", into: &body, as: "Entrypoint")

        if let tty = bool(config, "Tty") { body["Tty"] = tty }
        if let openStdin = bool(config, "OpenStdin") { body["OpenStdin"] = openStdin }

        if let labels = config["Labels"] as? [String: String], !labels.isEmpty {
            body["Labels"] = labels
        }

        if let healthcheck = config["Healthcheck"] as? [String: Any], !healthcheck.isEmpty {
            body["Healthcheck"] = healthcheck
        }

        var exposedPorts: [String: Any] = [:]
        if let sourcePorts = config["ExposedPorts"] as? [String: Any] {
            for key in sourcePorts.keys where key.contains("/") {
                exposedPorts[key] = [String: Any]()
            }
        }

        var portBindings: [String: Any] = [:]
        if let sourceBindings = hostConfig["PortBindings"] as? [String: Any] {
            for (port, rawTargets) in sourceBindings {
                guard let targets = rawTargets as? [[String: Any]], !targets.isEmpty else { continue }
                let mapped = targets.compactMap { target -> [String: String]? in
                    guard let hostPort = target["HostPort"] as? String, !hostPort.isEmpty else { return nil }
                    var entry: [String: String] = ["HostPort": hostPort]
                    if let hostIP = target["HostIp"] as? String, !hostIP.isEmpty {
                        entry["HostIp"] = hostIP
                    }
                    return entry
                }
                if !mapped.isEmpty {
                    portBindings[port] = mapped
                    exposedPorts[port] = [String: Any]()
                }
            }
        }
        if !exposedPorts.isEmpty { body["ExposedPorts"] = exposedPorts }

        var targetHostConfig: [String: Any] = [:]

        var binds: [String] = []
        if let sourceBinds = hostConfig["Binds"] as? [String] {
            binds.append(contentsOf: sourceBinds)
        }
        if let mounts = inspect["Mounts"] as? [[String: Any]] {
            var targetMounts: [[String: Any]] = []
            for mount in mounts {
                let type = mount["Type"] as? String ?? "volume"
                let destination = mount["Destination"] as? String ?? ""
                guard !destination.isEmpty else { continue }
                switch type {
                case "volume":
                    let sourceName = mount["Name"] as? String ?? ""
                    if migratedVolumeNames.contains(sourceName) {
                        var entry: [String: Any] = [
                            "Type": "volume",
                            "Source": sourceName,
                            "Target": destination,
                        ]
                        if let rw = mount["RW"] as? Bool { entry["ReadWrite"] = rw }
                        targetMounts.append(entry)
                    } else {
                        warnings.append(
                            "Volume '\(sourceName)' mounted at '\(destination)' was not migrated; the mount is omitted."
                        )
                    }
                case "bind":
                    let source = mount["Source"] as? String ?? ""
                    guard !source.isEmpty else { continue }
                    let mode = (mount["RW"] as? Bool ?? true) ? "rw" : "ro"
                    binds.append("\(source):\(destination):\(mode)")
                case "tmpfs":
                    var tmpfs = targetHostConfig["Tmpfs"] as? [String: String] ?? [:]
                    tmpfs[destination] = mount["TmpOptions"] as? String ?? ""
                    targetHostConfig["Tmpfs"] = tmpfs
                default:
                    warnings.append("Mount type '\(type)' at '\(destination)' is not supported and is omitted.")
                }
            }
            if !targetMounts.isEmpty { body["Mounts"] = targetMounts }
        }
        if !binds.isEmpty { targetHostConfig["Binds"] = binds }

        if !portBindings.isEmpty { targetHostConfig["PortBindings"] = portBindings }

        if let restartPolicy = hostConfig["RestartPolicy"] as? [String: Any],
            let name = restartPolicy["Name"] as? String, !name.isEmpty, name != "no"
        {
            var policy: [String: Any] = ["Name": name]
            if let retries = restartPolicy["MaximumRetryCount"] as? Int {
                policy["MaximumRetryCount"] = retries
            }
            targetHostConfig["RestartPolicy"] = policy
        }

        if let networkMode = hostConfig["NetworkMode"] as? String, !networkMode.isEmpty {
            if networkMode.hasPrefix("container:") {
                warnings.append(
                    "The container shares another container's network namespace (NetworkMode '\(networkMode)'); it cannot be migrated as-is."
                )
                return nil
            }
            targetHostConfig["NetworkMode"] = networkMode
            if networkMode == "host" {
                warnings.append("NetworkMode 'host' refers to the engine's Linux VM host network, not the Mac.")
            }
        }

        copyStringArray(hostConfig, "CapAdd", into: &targetHostConfig, as: "CapAdd")
        copyStringArray(hostConfig, "CapDrop", into: &targetHostConfig, as: "CapDrop")
        if let privileged = hostConfig["Privileged"] as? Bool {
            targetHostConfig["Privileged"] = privileged
        }

        for skipped in ["Links", "Devices", "SecurityOpt", "Dns", "DnsSearch", "DnsOptions", "ExtraHosts", "PidsLimit"] {
            if let value = hostConfig[skipped], !isEmptyValue(value) {
                warnings.append("HostConfig.\(skipped) is not migrated (value omitted).")
            }
        }
        if let autoRemove = hostConfig["AutoRemove"] as? Bool, autoRemove {
            warnings.append("HostConfig.AutoRemove is not migrated; the container persists after exit.")
        }
        if let pidMode = hostConfig["PidMode"] as? String, !pidMode.isEmpty {
            warnings.append("HostConfig.PidMode '\(pidMode)' is not migrated.")
        }
        if let ipcMode = hostConfig["IpcMode"] as? String, !ipcMode.isEmpty, ipcMode != "private" {
            warnings.append("HostConfig.IpcMode '\(ipcMode)' is not migrated.")
        }

        body["HostConfig"] = targetHostConfig
        return body
    }

    /// Detects conflicting fixed host port bindings across the planned containers.
    public static func hostPortConflicts(
        inspects: [[String: Any]]
    ) -> [String] {
        var ownerByPort: [String: String] = [:]
        var conflicts: Set<String> = []
        for inspect in inspects {
            let name = (inspect["Name"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let hostConfig = inspect["HostConfig"] as? [String: Any] ?? [:]
            guard let bindings = hostConfig["PortBindings"] as? [String: Any] else { continue }
            for (_, rawTargets) in bindings {
                guard let targets = rawTargets as? [[String: Any]] else { continue }
                for target in targets {
                    guard let hostPort = target["HostPort"] as? String, !hostPort.isEmpty else { continue }
                    if let previous = ownerByPort[hostPort], previous != name {
                        conflicts.insert("Host port \(hostPort) is claimed by '\(previous)' and '\(name)'.")
                    } else {
                        ownerByPort[hostPort] = name
                    }
                }
            }
        }
        return conflicts.sorted()
    }

    /// True when the source container should be started on the target after creation.
    public static func shouldStart(inspect: [String: Any]) -> Bool {
        let state = inspect["State"] as? [String: Any] ?? [:]
        return (state["Running"] as? Bool) ?? false
    }

    public static func containerName(inspect: [String: Any]) -> String {
        let raw = inspect["Name"] as? String ?? ""
        return raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    public static func createdOrder(_ inspect: [String: Any]) -> String {
        inspect["Created"] as? String ?? ""
    }

    // MARK: - Helpers

    private static func copyString(
        _ source: [String: Any], _ key: String, into body: inout [String: Any], as target: String
    ) {
        if let value = source[key] as? String, !value.isEmpty {
            body[target] = value
        }
    }

    private static func copyStringArray(
        _ source: [String: Any], _ key: String, into body: inout [String: Any], as target: String
    ) {
        if let value = source[key] as? [String], !value.isEmpty {
            body[target] = value
        }
    }

    private static func bool(_ source: [String: Any], _ key: String) -> Bool? {
        source[key] as? Bool
    }

    private static func isEmptyValue(_ value: Any) -> Bool {
        switch value {
        case let strings as [String]:
            return strings.isEmpty
        case let string as String:
            return string.isEmpty
        case let numbers as [Any]:
            return numbers.isEmpty
        default:
            return false
        }
    }
}
