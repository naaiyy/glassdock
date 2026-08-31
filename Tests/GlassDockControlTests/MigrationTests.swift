import Foundation
import Testing

@testable import GlassDockControl

@Suite("Docker migration")
struct MigrationTests {
    private func makeInspect(
        name: String = "web",
        image: String = "nginx:1.27",
        running: Bool = true,
        config: [String: Any] = [:],
        hostConfig: [String: Any] = [:],
        mounts: [[String: Any]] = []
    ) -> [String: Any] {
        var inspect: [String: Any] = [
            "Id": "abc123def456",
            "Name": "/" + name,
            "Created": "2026-08-01T00:00:00.000000000Z",
            "State": ["Running": running, "Status": running ? "running" : "exited"],
            "Config": config,
            "HostConfig": hostConfig,
        ]
        if !mounts.isEmpty {
            inspect["Mounts"] = mounts
        }
        return inspect
    }

    @Test("splits image references into repo and tag")
    func splitReference() {
        #expect(MigrationEngine.splitReference("nginx") == ("nginx", nil))
        #expect(MigrationEngine.splitReference("nginx:1.27") == ("nginx", "1.27"))
        #expect(MigrationEngine.splitReference("app/web") == ("app/web", nil))
        #expect(MigrationEngine.splitReference("app/web:v2") == ("app/web", "v2"))
        #expect(
            MigrationEngine.splitReference("registry.example:5000/app/web:v2")
                == ("registry.example:5000/app/web", "v2")
        )
        #expect(
            MigrationEngine.splitReference("registry.example:5000/app/web")
                == ("registry.example:5000/app/web", nil)
        )
    }

    @Test("percent-encodes path segments")
    func pathSegment() {
        #expect(MigrationEngine.pathSegment("nginx:1.27") == "nginx%3A1.27")
        #expect(MigrationEngine.pathSegment("app/web") == "app%2Fweb")
        #expect(MigrationEngine.pathSegment("plain-value") == "plain-value")
    }

    @Test("recreates core container configuration")
    func coreConfiguration() throws {
        var warnings: [String] = []
        let inspect = makeInspect(
            config: [
                "Image": "postgres:16",
                "Env": ["POSTGRES_PASSWORD=secret", "TZ=UTC"],
                "Cmd": ["postgres"],
                "Entrypoint": ["docker-entrypoint.sh"],
                "WorkingDir": "/var/lib/postgresql",
                "User": "postgres",
                "Labels": ["team": "backend"],
                "Tty": true,
                "OpenStdin": true,
                "StopSignal": "SIGINT",
                "ExposedPorts": ["5432/tcp": [String: Any]()],
            ],
            hostConfig: [
                "PortBindings": [
                    "5432/tcp": [["HostIp": "", "HostPort": "5432"]]
                ],
                "RestartPolicy": ["Name": "unless-stopped"],
                "NetworkMode": "app-net",
            ]
        )

        let body = try #require(
            MigrationContainerConverter.makeCreateRequest(
                inspect: inspect,
                migratedVolumeNames: [],
                warnings: &warnings
            )
        )

        #expect(body["Image"] as? String == "postgres:16")
        #expect(body["Env"] as? [String] == ["POSTGRES_PASSWORD=secret", "TZ=UTC"])
        #expect(body["Cmd"] as? [String] == ["postgres"])
        #expect(body["Entrypoint"] as? [String] == ["docker-entrypoint.sh"])
        #expect(body["WorkingDir"] as? String == "/var/lib/postgresql")
        #expect(body["User"] as? String == "postgres")
        #expect((body["Labels"] as? [String: String])?["team"] == "backend")
        #expect(body["Tty"] as? Bool == true)
        #expect(body["OpenStdin"] as? Bool == true)
        #expect(body["StopSignal"] as? String == "SIGINT")
        #expect((body["ExposedPorts"] as? [String: Any])?.keys.contains("5432/tcp") == true)
        #expect(warnings.isEmpty)

        let hostConfig = try #require(body["HostConfig"] as? [String: Any])
        let bindings = try #require(hostConfig["PortBindings"] as? [String: Any])
        let targets = try #require(bindings["5432/tcp"] as? [[String: Any]])
        let hostPort = targets.first?["HostPort"] as? String
        #expect(hostPort == "5432")
        let restartPolicy = hostConfig["RestartPolicy"] as? [String: String]
        #expect(restartPolicy == ["Name": "unless-stopped"])
        #expect(hostConfig["NetworkMode"] as? String == "app-net")
    }

    @Test("migrates named volumes and host binds")
    func volumeAndBindMounts() throws {
        var warnings: [String] = []
        let inspect = makeInspect(
            config: ["Image": "app"],
            hostConfig: ["Binds": ["/Users/dev/data:/imported:ro"]],
            mounts: [
                [
                    "Type": "volume",
                    "Name": "pgdata",
                    "Destination": "/var/lib/postgresql/data",
                    "RW": true,
                ],
                [
                    "Type": "volume",
                    "Name": "notmigrated",
                    "Destination": "/cache",
                    "RW": true,
                ],
                [
                    "Type": "bind",
                    "Source": "/Users/dev/config",
                    "Destination": "/etc/app",
                    "RW": false,
                ],
                [
                    "Type": "tmpfs",
                    "Destination": "/tmp/work",
                ],
            ]
        )

        let body = try #require(
            MigrationContainerConverter.makeCreateRequest(
                inspect: inspect,
                migratedVolumeNames: ["pgdata"],
                warnings: &warnings
            )
        )

        let targetMounts = try #require(body["Mounts"] as? [[String: Any]])
        #expect(targetMounts.count == 1)
        #expect(targetMounts[0]["Source"] as? String == "pgdata")
        #expect(targetMounts[0]["Target"] as? String == "/var/lib/postgresql/data")
        #expect(targetMounts[0]["ReadWrite"] as? Bool == true)

        let hostConfig = try #require(body["HostConfig"] as? [String: Any])
        let binds = try #require(hostConfig["Binds"] as? [String])
        #expect(binds.contains("/Users/dev/data:/imported:ro"))
        #expect(binds.contains("/Users/dev/config:/etc/app:ro"))

        let tmpfs = try #require(hostConfig["Tmpfs"] as? [String: String])
        #expect(tmpfs["/tmp/work"] == "")

        #expect(warnings.contains { $0.contains("notmigrated") })
        #expect(warnings.count == 1)
    }

    @Test("reports unsupported host configuration with warnings")
    func unsupportedHostConfig() throws {
        var warnings: [String] = []
        let inspect = makeInspect(
            config: ["Image": "tool"],
            hostConfig: [
                "Links": ["db:database"],
                "Devices": [["PathOnHost": "/dev/ttyUSB0"]],
                "SecurityOpt": ["seccomp:unconfined"],
                "PidMode": "host",
                "AutoRemove": true,
                "Dns": ["8.8.8.8"],
            ]
        )

        let body = try #require(
            MigrationContainerConverter.makeCreateRequest(
                inspect: inspect,
                migratedVolumeNames: [],
                warnings: &warnings
            )
        )

        let hostConfig = try #require(body["HostConfig"] as? [String: Any])
        #expect(hostConfig["Links"] == nil)
        #expect(hostConfig["Devices"] == nil)
        #expect(hostConfig["SecurityOpt"] == nil)
        #expect(hostConfig["Dns"] == nil)
        for phrase in ["Links", "Devices", "SecurityOpt", "PidMode", "AutoRemove", "Dns"] {
            #expect(warnings.contains { $0.contains(phrase) })
        }
    }

    @Test("rejects shared network namespaces")
    func rejectsContainerNetworkMode() {
        var warnings: [String] = []
        let inspect = makeInspect(
            config: ["Image": "sidecar"],
            hostConfig: ["NetworkMode": "container:abc123"]
        )

        let body = MigrationContainerConverter.makeCreateRequest(
            inspect: inspect,
            migratedVolumeNames: [],
            warnings: &warnings
        )

        #expect(body == nil)
        #expect(warnings.contains { $0.contains("network namespace") })
    }

    @Test("detects conflicting fixed host ports")
    func hostPortConflicts() {
        let first = makeInspect(
            name: "api",
            config: ["Image": "api"],
            hostConfig: ["PortBindings": ["8080/tcp": [["HostPort": "8080"]]]]
        )
        let second = makeInspect(
            name: "web",
            config: ["Image": "web"],
            hostConfig: ["PortBindings": ["8080/tcp": [["HostPort": "8080"]]]]
        )
        let distinct = makeInspect(
            name: "db",
            config: ["Image": "db"],
            hostConfig: ["PortBindings": ["5432/tcp": [["HostPort": "5432"]]]]
        )

        let conflicts = MigrationContainerConverter.hostPortConflicts(inspects: [first, second, distinct])
        #expect(conflicts.count == 1)
        #expect(conflicts[0].contains("8080"))
        #expect(conflicts[0].contains("api"))
        #expect(conflicts[0].contains("web"))
    }

    @Test("start decision and name extraction follow the inspect state")
    func startAndName() {
        #expect(MigrationContainerConverter.shouldStart(inspect: makeInspect(running: true)))
        #expect(!MigrationContainerConverter.shouldStart(inspect: makeInspect(running: false)))
        #expect(MigrationContainerConverter.containerName(inspect: makeInspect(name: "web")) == "web")
    }

    @Test("report text lists failures and warnings")
    func reportText() {
        var report = MigrationReport(
            sourceSocketPath: "/tmp/source.sock",
            targetSocketPath: "/tmp/target.sock",
            dryRun: false,
            inventory: MigrationInventory(
                imageReferences: ["nginx:1.27"],
                containerNames: ["web"],
                volumeNames: ["pgdata"],
                networkNames: ["app-net"]
            )
        )
        report.images.migrated.append(.init(name: "nginx:1.27", action: .migrated))
        report.containers.failed.append(
            .init(name: "web", action: .failed, detail: "create returned 500")
        )
        report.warnings.append("Host port 8080 is claimed twice.")

        #expect(!report.succeeded)
        let text = report.text()
        #expect(text.contains("FAILED:   web — create returned 500"))
        #expect(text.contains("migrated: nginx:1.27"))
        #expect(text.contains("! Host port 8080 is claimed twice."))
        #expect(text.contains("completed with failures"))
    }

    @Test("dry-run plan marks every category as planned")
    func dryRunPlan() {
        var report = MigrationReport(
            sourceSocketPath: "/tmp/source.sock",
            targetSocketPath: "/tmp/target.sock",
            dryRun: true,
            inventory: MigrationInventory(
                imageReferences: ["nginx:1.27"],
                containerNames: [],
                volumeNames: ["pgdata"],
                networkNames: []
            )
        )
        report.images.migrated.append(
            .init(name: "nginx:1.27", action: .migrated, detail: "planned (dry run)")
        )
        report.volumes.migrated.append(
            .init(name: "pgdata", action: .migrated, detail: "planned (dry run)")
        )

        #expect(report.succeeded)
        #expect(report.text().contains("Migration plan"))
        #expect(report.text().contains("planned (dry run)"))
    }

    @Test("label filter matches key presence and exact values")
    func labelFilter() {
        let labeled = ["glassdock.migrate": "test", "team": "backend"]
        #expect(MigrationContainerConverter.matchesLabelFilter(labeled, filter: nil))
        #expect(MigrationContainerConverter.matchesLabelFilter(labeled, filter: ""))
        #expect(MigrationContainerConverter.matchesLabelFilter(labeled, filter: "glassdock.migrate"))
        #expect(MigrationContainerConverter.matchesLabelFilter(labeled, filter: "glassdock.migrate=test"))
        #expect(MigrationContainerConverter.matchesLabelFilter(labeled, filter: "team=backend"))

        #expect(!MigrationContainerConverter.matchesLabelFilter(labeled, filter: "glassdock.migrate=nope"))
        #expect(!MigrationContainerConverter.matchesLabelFilter(labeled, filter: "missing"))
        #expect(!MigrationContainerConverter.matchesLabelFilter(nil, filter: "glassdock.migrate"))
        #expect(MigrationContainerConverter.matchesLabelFilter(nil, filter: nil))
        #expect(!MigrationContainerConverter.matchesLabelFilter([:], filter: "glassdock.migrate"))
    }

    @Test("null and zero-valued host configuration produces no warnings")
    func nullHostConfigFields() throws {
        var warnings: [String] = []
        let inspect = makeInspect(
            config: ["Image": "tool"],
            hostConfig: [
                "Links": NSNull(),
                "Devices": NSNull(),
                "SecurityOpt": NSNull(),
                "Dns": [String](),
                "ExtraHosts": [],
                "PidsLimit": 0,
                "Privileged": false,
            ]
        )

        _ = try #require(
            MigrationContainerConverter.makeCreateRequest(
                inspect: inspect,
                migratedVolumeNames: [],
                warnings: &warnings
            )
        )

        #expect(warnings.isEmpty)
    }

    @Test("migration event and report keep their JSON contract")
    func jsonContract() throws {
        let event = MigrationEvent(phase: .images, detail: "Migrated image nginx.")
        let decodedEvent = try JSONDecoder().decode(
            MigrationEvent.self, from: JSONEncoder().encode(event)
        )
        #expect(decodedEvent == event)
        #expect(decodedEvent.phase.rawValue == "images")

        let report = MigrationReport(
            sourceSocketPath: "/tmp/source.sock",
            targetSocketPath: "/tmp/target.sock",
            dryRun: true,
            inventory: MigrationInventory()
        )
        let decodedReport = try JSONDecoder().decode(
            MigrationReport.self, from: JSONEncoder().encode(report)
        )
        #expect(decodedReport.schemaVersion == MigrationReport.currentSchemaVersion)
        #expect(decodedReport.succeeded)
    }
}
