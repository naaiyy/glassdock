import Foundation

/// Migrates images, volumes, networks, and containers from an existing Docker
/// engine to the Glass Dock engine over their Docker API Unix sockets.
///
/// The engine talks to both engines at the REST API level. Volume data moves
/// through a tar pipe staged on the host disk and driven by the local `docker`
/// CLI, because named volumes live inside each engine's VM and are not
/// directly reachable from the Mac filesystem.
public struct MigrationEngine: Sendable {
    public let options: MigrationOptions
    public let targetSocketPath: String
    public let onEvent: @Sendable (MigrationEvent) -> Void

    public init(
        options: MigrationOptions = MigrationOptions(),
        targetSocketPath: String? = nil,
        onEvent: @escaping @Sendable (MigrationEvent) -> Void = { _ in }
    ) {
        self.options = options
        self.targetSocketPath =
            targetSocketPath
            ?? DaemonLifecycle(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
            .paths.socket.path
        self.onEvent = onEvent
    }

    // MARK: - Docker API clients

    struct DockerClient: Sendable {
        let socketPath: String
        var timeout: TimeInterval = 60
        var maximumResponseBytes = 256 * 1024 * 1024

        func get(_ path: String) throws -> HTTPResult {
            try client().request(method: "GET", path: path)
        }

        func post(_ path: String, body: Data? = nil, contentType: String? = nil) throws -> HTTPResult {
            try client().request(method: "POST", path: path, body: body, contentType: contentType)
        }

        func json<T: Decodable>(_ type: T.Type, _ path: String) throws -> T {
            let result = try get(path)
            guard (200..<300).contains(result.status) else {
                throw ControlError.requestFailed(status: result.status, message: Self.errorText(result))
            }
            return try JSONDecoder().decode(type, from: result.body)
        }

        func ping() -> Bool {
            guard let result = try? get("/_ping") else { return false }
            return (200..<300).contains(result.status)
        }

        func withLongTimeout() -> DockerClient {
            var copy = self
            copy.timeout = 600
            return copy
        }

        private func client() -> UnixSocketHTTPClient {
            UnixSocketHTTPClient(
                socketPath: socketPath,
                timeout: timeout,
                maximumResponseBytes: maximumResponseBytes
            )
        }

        static func errorText(_ result: HTTPResult) -> String {
            if let decoded = try? JSONDecoder().decode(DockerErrorMessage.self, from: result.body) {
                return decoded.message
            }
            return String(decoding: result.body, as: UTF8.self)
        }
    }

    private struct DockerErrorMessage: Decodable {
        let message: String
    }

    struct SourceImageSummary: Decodable {
        let Id: String
        let RepoTags: [String]?
        let Labels: [String: String]?
    }

    struct SourceContainerSummary: Decodable {
        let Id: String
        let Names: [String]?
        let Image: String
        let Created: Int?
        let State: String?
        let Labels: [String: String]?
    }

    struct SourceVolume: Decodable {
        let Name: String
        let Driver: String
        let Labels: [String: String]?
    }

    struct SourceVolumeList: Decodable {
        let Volumes: [SourceVolume]?
    }

    struct SourceNetwork: Decodable {
        let Name: String
        let Driver: String
        let Scope: String?
        let Internal: Bool?
        let Options: [String: String]?
        let Labels: [String: String]?
    }

    struct CreateResponse: Decodable {
        let Id: String?
        let Warnings: [String]?
    }

    // MARK: - Entry point

    public func run() async throws -> MigrationReport {
        try await Task.detached(priority: .userInitiated) {
            try self.runSync()
        }.value
    }

    func runSync() throws -> MigrationReport {
        let source = DockerClient(socketPath: options.sourceSocketPath)
        let target = DockerClient(socketPath: targetSocketPath)

        guard source.ping() else {
            throw MigrationError.sourceEngineUnavailable(
                "no response on \(options.sourceSocketPath)"
            )
        }
        guard target.ping() else {
            throw MigrationError.targetEngineUnavailable(
                "no response on \(targetSocketPath)"
            )
        }

        let inventory = try buildInventory(from: source)
        var report = MigrationReport(
            sourceSocketPath: options.sourceSocketPath,
            targetSocketPath: targetSocketPath,
            dryRun: options.dryRun,
            inventory: inventory
        )

        if options.includeImages {
            try migrateImages(from: source, to: target, report: &report)
        }
        if options.includeVolumes {
            try migrateVolumes(from: source, to: target, report: &report)
        }
        if options.includeNetworks {
            try migrateNetworks(from: source, to: target, report: &report)
        }
        if options.includeContainers {
            try migrateContainers(from: source, to: target, report: &report)
        }

        emit(.init(phase: .complete, detail: "Migration finished."))
        return report
    }

    private func emit(_ event: MigrationEvent) {
        onEvent(event)
    }

    // MARK: - Inventory

    func buildInventory(from source: DockerClient) throws -> MigrationInventory {
        emit(.init(phase: .inventory, detail: "Reading source inventory."))
        var inventory = MigrationInventory()

        let images = try source.json([SourceImageSummary].self, "/images/json?all=1")
        var references = Set<String>()
        for image in images
        where MigrationContainerConverter.matchesLabelFilter(
            image.Labels, filter: options.filterLabel
        ) {
            for tag in image.RepoTags ?? [] where !tag.hasPrefix("<none>") {
                references.insert(tag)
            }
        }
        inventory.imageReferences = references.sorted()

        let containers = try source.json([SourceContainerSummary].self, "/containers/json?all=1")
        inventory.containerNames = containers.compactMap { container in
            guard
                MigrationContainerConverter.matchesLabelFilter(
                    container.Labels, filter: options.filterLabel
                )
            else { return nil }
            let name = container.Names?.first?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
            if name.isEmpty { return nil }
            if !options.includeStoppedContainers && container.State != "running" { return nil }
            return name
        }.sorted()

        let volumes = try source.json(SourceVolumeList.self, "/volumes").Volumes ?? []
        inventory.volumeNames =
            volumes
            .filter { $0.Driver == "local" }
            .filter { MigrationContainerConverter.matchesLabelFilter($0.Labels, filter: options.filterLabel) }
            .map(\.Name).sorted()

        let networks = try source.json([SourceNetwork].self, "/networks")
        inventory.networkNames =
            networks
            .filter { isMigratableNetwork($0) }
            .filter { MigrationContainerConverter.matchesLabelFilter($0.Labels, filter: options.filterLabel) }
            .map(\.Name).sorted()

        return inventory
    }

    private func isMigratableNetwork(_ network: SourceNetwork) -> Bool {
        let defaults: Set<String> = ["bridge", "host", "none"]
        return network.Driver == "bridge" && network.Scope != "swarm" && !defaults.contains(network.Name)
    }

    // MARK: - Images

    func migrateImages(
        from source: DockerClient, to target: DockerClient, report: inout MigrationReport
    ) throws {
        emit(.init(phase: .images, detail: "Transferring \(report.inventory.imageReferences.count) image references."))

        let presentOnTarget = targetImageReferences(target)
        let source = source.withLongTimeout()

        for reference in report.inventory.imageReferences {
            if presentOnTarget.contains(reference) {
                report.images.skipped.append(
                    .init(name: reference, action: .skipped, detail: "already present on the target")
                )
                continue
            }
            if options.dryRun {
                report.images.migrated.append(
                    .init(name: reference, action: .migrated, detail: "planned (dry run)")
                )
                continue
            }
            do {
                try transferImage(reference, from: source, to: target)
                report.images.migrated.append(.init(name: reference, action: .migrated))
                emit(.init(phase: .images, detail: "Migrated image \(reference)."))
            } catch {
                report.images.failed.append(
                    .init(name: reference, action: .failed, detail: error.localizedDescription)
                )
                emit(.init(phase: .images, detail: "Failed image \(reference): \(error.localizedDescription)"))
            }
        }
    }

    private func targetImageReferences(_ target: DockerClient) -> Set<String> {
        guard let images = try? target.json([SourceImageSummary].self, "/images/json?all=1") else {
            return []
        }
        var references = Set<String>()
        for image in images {
            for tag in image.RepoTags ?? [] where !tag.hasPrefix("<none>") {
                references.insert(tag)
            }
        }
        return references
    }

    func transferImage(_ reference: String, from source: DockerClient, to target: DockerClient) throws {
        do {
            let (repo, tag) = Self.splitReference(reference)
            var path = "/images/create?fromImage=\(Self.pathSegment(repo))"
            if let tag {
                path += "&tag=\(Self.pathSegment(tag))"
            }
            let result = try source.post(path)
            guard (200..<300).contains(result.status) else {
                throw ControlError.requestFailed(
                    status: result.status, message: DockerClient.errorText(result)
                )
            }
        } catch {
            try transferImageArchive(reference, from: source, to: target, pullError: error)
        }
    }

    private func transferImageArchive(
        _ reference: String,
        from source: DockerClient,
        to target: DockerClient,
        pullError: Error
    ) throws {
        let escaped = Self.pathSegment(reference)
        let archive: HTTPResult
        do {
            archive = try source.get("/images/\(escaped)/get")
        } catch {
            throw ControlError.requestFailed(
                status: 0,
                message: "registry pull failed (\(pullError.localizedDescription)) and archive export failed too"
            )
        }
        guard (200..<300).contains(archive.status) else {
            throw ControlError.requestFailed(
                status: 0,
                message: "registry pull failed (\(pullError.localizedDescription)) and archive export returned status \(archive.status)"
            )
        }
        let loaded = try target.post(
            "/images/load?quiet=1",
            body: archive.body,
            contentType: "application/x-tar"
        )
        guard (200..<300).contains(loaded.status) else {
            throw ControlError.requestFailed(
                status: loaded.status, message: DockerClient.errorText(loaded)
            )
        }
    }

    static func splitReference(_ reference: String) -> (repo: String, tag: String?) {
        let lastSlash = reference.lastIndex(of: "/")
        let searchStart = reference.index(after: lastSlash ?? reference.startIndex)
        if let colon = reference[searchStart...].lastIndex(of: ":") {
            return (String(reference[..<colon]), String(reference[reference.index(after: colon)...]))
        }
        return (reference, nil)
    }

    static func pathSegment(_ value: String) -> String {
        value.addingPercentEncoding(
            withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        ) ?? value
    }

    // MARK: - Volumes

    func migrateVolumes(
        from source: DockerClient, to target: DockerClient, report: inout MigrationReport
    ) throws {
        let volumes = (try? source.json(SourceVolumeList.self, "/volumes").Volumes ?? []) ?? []
        let localVolumes =
            volumes
            .filter { $0.Driver == "local" }
            .filter { MigrationContainerConverter.matchesLabelFilter($0.Labels, filter: options.filterLabel) }
        let unsupported = volumes.filter { $0.Driver != "local" }
        for volume in unsupported {
            report.volumes.skipped.append(
                .init(name: volume.Name, action: .skipped, detail: "driver '\(volume.Driver)' is not supported")
            )
        }
        emit(.init(phase: .volumes, detail: "Migrating \(localVolumes.count) local volumes."))

        for volume in localVolumes {
            do {
                try migrateVolume(named: volume.Name, from: source, to: target, report: &report)
            } catch let error as MigrationError {
                report.volumes.failed.append(
                    .init(name: volume.Name, action: .failed, detail: error.localizedDescription)
                )
                emit(.init(phase: .volumes, detail: "Failed volume \(volume.Name): \(error.localizedDescription)"))
            }
        }
    }

    func migrateVolume(
        named name: String, from source: DockerClient, to target: DockerClient, report: inout MigrationReport
    ) throws {
        let createBody = try JSONSerialization.data(
            withJSONObject: ["Name": name, "Driver": "local"]
        )
        let created = try target.post("/volumes/create", body: createBody, contentType: "application/json")
        switch created.status {
        case 201:
            break
        case 409:
            report.volumes.skipped.append(
                .init(name: name, action: .skipped, detail: "a volume with this name already exists on the target")
            )
            return
        default:
            throw MigrationError.volumeCopyFailed(
                volume: name, stage: "target create", message: DockerClient.errorText(created)
            )
        }
        if options.dryRun {
            report.volumes.migrated.append(
                .init(name: name, action: .migrated, detail: "planned (dry run)")
            )
            return
        }

        try copyVolumeData(named: name, from: source, to: target)
        report.volumes.migrated.append(.init(name: name, action: .migrated))
        emit(.init(phase: .volumes, detail: "Migrated volume \(name)."))
    }

    func copyVolumeData(named name: String, from source: DockerClient, to target: DockerClient) throws {
        let docker = try resolveDockerCLI()
        let stagingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("glassdock-migrate-\(UUID().uuidString).tar")
        defer { try? FileManager.default.removeItem(at: stagingURL) }

        try runDockerCLI(
            docker,
            arguments: [
                "--host", "unix://\(source.socketPath)", "run", "--rm",
                "-v", "\(name):/migrate:ro", options.helperImage,
                "tar", "-cf", "-", "-C", "/migrate", ".",
            ],
            stdoutDestination: .file(stagingURL),
            failure: MigrationError.volumeCopyFailed(volume: name, stage: "source export", message: "")
        )

        try runDockerCLI(
            docker,
            arguments: [
                "--host", "unix://\(target.socketPath)", "run", "--rm", "-i",
                "-v", "\(name):/migrate", options.helperImage,
                "tar", "-xf", "-", "-C", "/migrate",
            ],
            stdinSource: .file(stagingURL),
            failure: MigrationError.volumeCopyFailed(volume: name, stage: "target import", message: "")
        )
    }

    // MARK: - Networks

    func migrateNetworks(
        from source: DockerClient, to target: DockerClient, report: inout MigrationReport
    ) throws {
        let networks = (try? source.json([SourceNetwork].self, "/networks")) ?? []
        let migratable =
            networks
            .filter(isMigratableNetwork)
            .filter { MigrationContainerConverter.matchesLabelFilter($0.Labels, filter: options.filterLabel) }
        emit(.init(phase: .networks, detail: "Recreating \(migratable.count) user-defined networks."))

        for network in migratable {
            if options.dryRun {
                report.networks.migrated.append(
                    .init(name: network.Name, action: .migrated, detail: "planned (dry run)")
                )
                continue
            }
            do {
                try createNetwork(network, on: target, report: &report)
                report.networks.migrated.append(.init(name: network.Name, action: .migrated))
                emit(.init(phase: .networks, detail: "Recreated network \(network.Name)."))
            } catch {
                report.networks.failed.append(
                    .init(name: network.Name, action: .failed, detail: error.localizedDescription)
                )
                emit(.init(phase: .networks, detail: "Failed network \(network.Name): \(error.localizedDescription)"))
            }
        }
    }

    private func createNetwork(_ network: SourceNetwork, on target: DockerClient, report: inout MigrationReport) throws {
        var payload: [String: Any] = ["Name": network.Name, "Driver": network.Driver]
        if let options = network.Options, !options.isEmpty { payload["Options"] = options }
        if let internalFlag = network.Internal { payload["Internal"] = internalFlag }

        let body = try JSONSerialization.data(withJSONObject: payload)
        let result = try target.post("/networks/create", body: body, contentType: "application/json")
        switch result.status {
        case 201:
            return
        case 409:
            report.networks.skipped.append(
                .init(name: network.Name, action: .skipped, detail: "already exists on the target")
            )
            return
        default:
            throw ControlError.requestFailed(status: result.status, message: DockerClient.errorText(result))
        }
    }

    // MARK: - Containers

    func migrateContainers(
        from source: DockerClient, to target: DockerClient, report: inout MigrationReport
    ) throws {
        let summaries = try source.json([SourceContainerSummary].self, "/containers/json?all=1")
        let planned =
            summaries
            .filter { MigrationContainerConverter.matchesLabelFilter($0.Labels, filter: options.filterLabel) }
            .filter { options.includeStoppedContainers || $0.State == "running" }
            .sorted { ($0.Created ?? 0) < ($1.Created ?? 0) }

        emit(.init(phase: .containers, detail: "Recreating \(planned.count) containers."))

        var migratedVolumeNames = Set(report.volumes.migrated.map(\.name))
        for skipped in report.volumes.skipped where skipped.detail?.contains("already exists") == true {
            migratedVolumeNames.insert(skipped.name)
        }

        var inspects: [[String: Any]] = []
        var inspectBySummary: [String: [String: Any]] = [:]
        for summary in planned {
            let escaped = Self.pathSegment(summary.Id)
            if let data = try? source.get("/containers/\(escaped)/json"),
                (200..<300).contains(data.status),
                let object = try? JSONSerialization.jsonObject(with: data.body) as? [String: Any]
            {
                inspects.append(object)
                inspectBySummary[summary.Id] = object
            }
        }
        for conflict in MigrationContainerConverter.hostPortConflicts(inspects: inspects) {
            report.warnings.append(conflict)
        }

        for summary in planned {
            let name =
                summary.Names?.first?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                ?? String(summary.Id.prefix(12))
            guard let inspect = inspectBySummary[summary.Id] else {
                report.containers.failed.append(
                    .init(name: name, action: .failed, detail: "the source inspect call failed")
                )
                continue
            }
            do {
                try recreateContainer(
                    inspect: inspect,
                    fallbackName: name,
                    from: source,
                    to: target,
                    migratedVolumeNames: migratedVolumeNames,
                    report: &report
                )
            } catch {
                report.containers.failed.append(
                    .init(name: name, action: .failed, detail: error.localizedDescription)
                )
                emit(.init(phase: .containers, detail: "Failed container \(name): \(error.localizedDescription)"))
            }
        }
    }

    func recreateContainer(
        inspect: [String: Any],
        fallbackName: String,
        from source: DockerClient,
        to target: DockerClient,
        migratedVolumeNames: Set<String>,
        report: inout MigrationReport
    ) throws {
        var warnings: [String] = []
        guard
            let createBody = MigrationContainerConverter.makeCreateRequest(
                inspect: inspect,
                migratedVolumeNames: migratedVolumeNames,
                warnings: &warnings
            )
        else {
            report.containers.failed.append(
                .init(name: fallbackName, action: .failed, detail: warnings.joined(separator: " "))
            )
            return
        }
        for warning in warnings { report.warnings.append("\(fallbackName): \(warning)") }

        let name = MigrationContainerConverter.containerName(inspect: inspect)
        let displayName = name.isEmpty ? fallbackName : name

        if options.dryRun {
            report.containers.migrated.append(
                .init(name: displayName, action: .migrated, detail: "planned (dry run)")
            )
            return
        }

        let payload = try JSONSerialization.data(withJSONObject: createBody)
        let created = try target.post(
            "/containers/create?name=\(Self.pathSegment(displayName))",
            body: payload,
            contentType: "application/json"
        )
        switch created.status {
        case 200..<300:
            break
        case 409:
            report.containers.skipped.append(
                .init(name: displayName, action: .skipped, detail: "a container with this name already exists on the target")
            )
            return
        default:
            throw ControlError.requestFailed(
                status: created.status, message: DockerClient.errorText(created)
            )
        }

        if MigrationContainerConverter.shouldStart(inspect: inspect) {
            let response = try JSONDecoder().decode(CreateResponse.self, from: created.body)
            guard let identifier = response.Id, !identifier.isEmpty else {
                throw ControlError.malformedResponse("create returned no container id")
            }
            let started = try target.post("/containers/\(Self.pathSegment(identifier))/start")
            guard (200..<300).contains(started.status) || started.status == 304 else {
                throw ControlError.requestFailed(
                    status: started.status, message: DockerClient.errorText(started)
                )
            }
        }

        report.containers.migrated.append(.init(name: displayName, action: .migrated))
        emit(.init(phase: .containers, detail: "Recreated container \(displayName)."))
    }

    // MARK: - docker CLI

    func resolveDockerCLI() throws -> String {
        let candidates = [
            options.dockerCLI,
            "/usr/local/bin/docker",
            "/opt/homebrew/bin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker",
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        throw MigrationError.dockerCLIMissing(options.dockerCLI)
    }

    enum StagingSource {
        case file(URL)
        case none
    }

    func runDockerCLI(
        _ dockerPath: String,
        arguments: [String],
        stdinSource: StagingSource = .none,
        stdoutDestination: StagingSource = .none,
        failure: @autoclosure () -> MigrationError
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: dockerPath)
        process.arguments = arguments

        switch stdinSource {
        case .file(let url):
            let handle = try FileHandle(forReadingFrom: url)
            process.standardInput = handle
        case .none:
            break
        }

        switch stdoutDestination {
        case .file(let url):
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            process.standardOutput = handle
        case .none:
            break
        }

        let stderrURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("glassdock-migrate-\(UUID().uuidString).stderr")
        defer { try? FileManager.default.removeItem(at: stderrURL) }
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        guard let stderrHandle = try? FileHandle(forWritingTo: stderrURL) else {
            throw failure()
        }
        process.standardError = stderrHandle

        try process.run()
        process.waitUntilExit()
        try? stderrHandle.close()

        guard process.terminationStatus == 0 else {
            let text = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
            var message = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.isEmpty {
                message = "docker exited with status \(process.terminationStatus)"
            }
            let base = failure()
            switch base {
            case .volumeCopyFailed(let volume, let stage, _):
                throw MigrationError.volumeCopyFailed(volume: volume, stage: stage, message: message)
            default:
                throw base
            }
        }
    }
}
