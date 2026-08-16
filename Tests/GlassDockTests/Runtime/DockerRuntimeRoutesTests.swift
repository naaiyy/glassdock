import Foundation
import NIOCore
import Testing
import Vapor
import VaporTesting

@testable import GlassDock

@Suite("Docker runtime v1.51 routes")
struct DockerRuntimeRoutesTests {
    @Test("restored port bindings default an omitted host IP")
    func restoredPortBindingDefaultsHostIP() throws {
        let binding = try JSONDecoder().decode(
            DockerRuntimePortBinding.self,
            from: Data(#"{"containerPort":80,"protocol":"tcp"}"#.utf8)
        )

        #expect(binding.hostIP == "0.0.0.0")
        #expect(binding.hostPort == nil)
    }

    @Test("image pull forwards a pinned reference and platform")
    func pullImage() async throws {
        let backend = DockerRuntimeBackendMock()
        try await withRuntimeRoutes(backend) { app in
            try await app.testing().test(
                .POST,
                "/v1.51/images/create?fromImage=example.test%2Ffixture&tag=sha256-deadbeef&platform=linux%2Farm64"
            ) { response async in
                #expect(response.status == .ok)
                #expect(response.headers.contentType == .json)
                #expect(response.body.string.contains("Downloaded newer image"))
                #expect(response.body.string.hasSuffix("\n"))
            }
        }
        let pull = await backend.lastPull
        #expect(pull?.reference == "example.test/fixture:sha256-deadbeef")
        #expect(pull?.platform == "linux/arm64")
    }

    @Test("containerd image lifecycle uses Docker response shapes")
    func imageLifecycle() async throws {
        let backend = DockerRuntimeBackendMock()
        try await withRuntimeRoutes(backend) { app in
            try await app.testing().test(.GET, "/v1.51/images/json") { response async throws in
                #expect(response.status == .ok)
                let rows = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [[String: Any]]
                #expect(rows?.first?["Id"] as? String == "sha256:abc")
                #expect(rows?.first?["RepoTags"] as? [String] == ["example.test/fixture:latest"])
            }
            try await app.testing().test(.GET, "/v1.51/images/example.test%2Ffixture:latest/json") { response async throws in
                #expect(response.status == .ok)
                let image = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
                #expect(image?["Id"] as? String == "sha256:abc")
                #expect((image?["RootFS"] as? [String: Any])?["Type"] as? String == "layers")
            }
            try await app.testing().test(
                .POST,
                "/v1.51/images/example.test%2Ffixture:latest/tag?repo=example.test%2Fcopy&tag=v1"
            ) { response async in
                #expect(response.status == .created)
            }
            try await app.testing().test(.DELETE, "/v1.51/images/example.test%2Ffixture:latest?force=1") { response async throws in
                #expect(response.status == .ok)
                let items = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [[String: Any]]
                #expect(items?.contains { $0["Deleted"] as? String == "sha256:abc" } == true)
            }
            let filters = "%7B%22dangling%22:%7B%22false%22:true%7D%7D"
            try await app.testing().test(.POST, "/v1.51/images/prune?filters=\(filters)") { response async throws in
                #expect(response.status == .ok)
                let result = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
                #expect(result?["SpaceReclaimed"] as? Int == 12)
            }
        }
        #expect(await backend.lastImageDeleteForce == true)
        #expect(await backend.lastTagTarget == "example.test/copy:v1")
        #expect(await backend.lastPruneAll == true)
    }

    @Test("image export, history, and push use Docker response shapes")
    func imageTransferRoutes() async throws {
        let backend = DockerRuntimeBackendMock()
        try await withRuntimeRoutes(backend) { app in
            try await app.testing().test(
                .GET,
                "/v1.51/images/get?names=example.test%2Ffixture:latest"
            ) { response async in
                #expect(response.status == .ok)
                #expect(response.headers.contentType == HTTPMediaType(type: "application", subType: "x-tar"))
                #expect(Data(buffer: response.body) == Data("image-tar".utf8))
            }
            try await app.testing().test(
                .GET,
                "/v1.51/images/example.test%2Ffixture:latest/history"
            ) { response async throws in
                #expect(response.status == .ok)
                let history = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [[String: Any]]
                #expect(history?.first?["Id"] as? String == "sha256:layer")
                #expect(history?.first?["Tags"] as? [String] == ["example.test/fixture:latest"])
            }
            try await app.testing().test(
                .POST,
                "/v1.51/images/example.test%2Ffixture/push?tag=v2&platform=linux%2Farm64",
                headers: ["X-Registry-Auth": Data(#"{"username":"user","password":"secret"}"#.utf8).base64EncodedString()]
            ) { response async in
                #expect(response.status == .ok)
                #expect(response.body.string.contains("Pushed"))
            }
        }
        #expect(await backend.lastExportReferences == ["example.test/fixture:latest"])
        #expect(await backend.lastPush?.source == "example.test/fixture")
        #expect(await backend.lastPush?.target == "example.test/fixture:v2")
        #expect(await backend.lastPush?.platform == "linux/arm64")
    }

    @Test("container lifecycle maps Docker create fields and status codes")
    func containerLifecycle() async throws {
        let backend = DockerRuntimeBackendMock()
        try await withRuntimeRoutes(backend) { app in
            let createBody = #"""
                {
                  "Image":"fixture@sha256:abc",
                  "Cmd":["/bin/true"],
                  "Env":["A=B"],
                  "WorkingDir":"/work",
                  "Labels":{"test":"true"},
                  "HostConfig":{
                    "AutoRemove":true,
                    "Binds":["/tmp/source:/data:ro"],
                    "PortBindings":{"80/tcp":[{"HostIp":"127.0.0.1","HostPort":"18080"}]}
                  }
                }
                """#
            try await app.testing().test(
                .POST,
                "/v1.51/containers/create?name=bench",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: createBody)
            ) { response async throws in
                #expect(response.status == .created)
                let value = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
                #expect(value?["Id"] as? String == "container-1")
            }

            try await app.testing().test(.POST, "/v1.51/containers/container-1/start") { response async in
                #expect(response.status == .noContent)
            }
            try await app.testing().test(.POST, "/v1.51/containers/container-1/wait?condition=next-exit") { response async throws in
                #expect(response.status == .ok)
                #expect(!response.body.string.hasPrefix(" "))
                let value = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
                #expect(value?["StatusCode"] as? Int == 7)
            }
            try await app.testing().test(.GET, "/v1.51/containers/container-1/json") { response async throws in
                #expect(response.status == .ok)
                let value = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
                let state = value?["State"] as? [String: Any]
                #expect(state?["Running"] as? Bool == true)
                let hostConfig = value?["HostConfig"] as? [String: Any]
                let portBindings = hostConfig?["PortBindings"] as? [String: Any]
                #expect(portBindings?["80/tcp"] != nil)
            }
            try await app.testing().test(.GET, "/v1.51/containers/json?all=1") { response async throws in
                #expect(response.status == .ok)
                let value = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [[String: Any]]
                #expect(value?.first?["Id"] as? String == "container-1")
                let ports = value?.first?["Ports"] as? [[String: Any]]
                #expect(ports?.first?["PublicPort"] as? Int == 18080)
            }
            try await app.testing().test(.DELETE, "/v1.51/containers/container-1?force=1&v=true") { response async in
                #expect(response.status == .noContent)
            }
        }

        let create = try #require(await backend.lastCreate)
        #expect(create.name == "bench")
        #expect(create.command == ["/bin/true"])
        #expect(create.environment == ["A=B"])
        #expect(create.autoRemove)
        #expect(create.mounts == [.init(source: "/private/tmp/source", target: "/data", readOnly: true)])
        #expect(create.ports == [.init(containerPort: 80, proto: "tcp", hostIP: "127.0.0.1", hostPort: 18080)])
        #expect(await backend.lastWaitCondition == .nextExit)
        #expect(await backend.lastListShowAll == true)
        #expect(await backend.lastDelete == .init(force: true, volumes: true))
    }

    @Test("container create canonicalizes macOS bind path aliases")
    func containerCreateCanonicalizesBindPathAliases() async throws {
        let backend = DockerRuntimeBackendMock()
        let canonicalSource = "/private/var/tmp/glassdock-bind-\(UUID().uuidString)"
        let aliasedSource = String(canonicalSource.dropFirst("/private".count))
        try FileManager.default.createDirectory(
            atPath: canonicalSource,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(atPath: canonicalSource) }

        try await withRuntimeRoutes(backend) { app in
            let body = #"{"Image":"fixture@sha256:abc","HostConfig":{"Binds":["\#(aliasedSource):/data"]}}"#
            try await app.testing().test(
                .POST,
                "/v1.51/containers/create",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: body)
            ) { response async in
                #expect(response.status == .created)
            }
        }

        let create = try #require(await backend.lastCreate)
        #expect(create.mounts == [.init(source: canonicalSource, target: "/data", readOnly: false)])
    }

    @Test("exec start returns stdcopy frames and records the exit code")
    func execLifecycle() async throws {
        let backend = DockerRuntimeBackendMock()
        try await withRuntimeRoutes(backend) { app in
            try await app.testing().test(
                .POST,
                "/v1.51/containers/container-1/exec",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: #"{"Cmd":["printf","hello"],"AttachStdout":true}"#)
            ) { response async throws in
                #expect(response.status == .created)
                let value = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
                #expect(value?["Id"] as? String == "exec-1")
            }
            try await app.testing().test(
                .POST,
                "/v1.51/exec/exec-1/start",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: #"{"Detach":false,"Tty":false}"#)
            ) { response async in
                #expect(response.status == .ok)
                let bytes = Array(response.body.readableBytesView)
                #expect(Array(bytes.prefix(8)) == [1, 0, 0, 0, 0, 0, 0, 5])
                #expect(String(decoding: bytes.dropFirst(8), as: UTF8.self) == "hello")
            }
            try await app.testing().test(.GET, "/v1.51/exec/exec-1/json") { response async throws in
                let value = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
                #expect(value?["Running"] as? Bool == false)
                #expect(value?["ExitCode"] as? Int == 23)
            }
        }
        #expect(await backend.lastExec?.command == ["printf", "hello"])
    }

    @Test("logs use Docker framing and backend not-found maps to 404")
    func logsAndErrors() async throws {
        let backend = DockerRuntimeBackendMock()
        try await withRuntimeRoutes(backend) { app in
            try await app.testing().test(.GET, "/v1.51/containers/container-1/logs?stdout=1&stderr=1") { response async in
                #expect(response.status == .ok)
                let bytes = Array(response.body.readableBytesView)
                #expect(bytes[0] == 1)
                #expect(bytes[11] == 2)
                #expect(response.headers.first(name: "Content-Type") == nil)
            }
            try await app.testing().test(.GET, "/v1.51/containers/missing/json") { response async in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test("container logs tail preserves the final newline")
    func logsTail() async throws {
        let backend = DockerRuntimeBackendMock(logOutput: "old\nnew\n")
        try await withRuntimeRoutes(backend) { app in
            try await app.testing().test(.GET, "/v1.51/containers/container-1/logs?stdout=1&tail=1") { response async in
                #expect(response.status == .ok)
                let bytes = Array(response.body.readableBytesView)
                #expect(Data(bytes.dropFirst(8)) == Data("new\n".utf8))
            }
        }
    }

    @Test("container list applies exact label filters")
    func listLabelFilters() async throws {
        let backend = DockerRuntimeBackendMock()
        try await withRuntimeRoutes(backend) { app in
            let matching = "%7B%22label%22:%5B%22test%3Dtrue%22%5D%7D"
            try await app.testing().test(.GET, "/v1.51/containers/json?all=1&filters=\(matching)") { response async throws in
                let values = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [[String: Any]]
                #expect(values?.count == 1)
            }
            let different = "%7B%22label%22:%5B%22glassdock.benchmark.run%3Dother%22%5D%7D"
            try await app.testing().test(.GET, "/v1.51/containers/json?all=1&filters=\(different)") { response async throws in
                let values = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [[String: Any]]
                #expect(values?.isEmpty == true)
            }
        }
    }

    @Test("runtime and unsupported routes expose Docker statuses")
    func explicitUnsupportedRoutes() async throws {
        let backend = DockerRuntimeBackendMock()
        try await withApp(configure: { _ in }) { app in
            let router = app.regexRouter(with: app.logger)
            app.setRegexRouter(router)
            try app.register(collection: DockerRuntimeRoutes(backend: backend))
            try app.register(collection: ExplicitUnsupportedDockerRoutes())
            try await app.testing().test(.GET, "/v1.51/info") { response async throws in
                #expect(response.status == .ok)
                let value = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
                #expect(value?["Containers"] as? Int == 1)
                #expect(value?["Images"] as? Int == 1)
                #expect(value?["OSType"] as? String == "linux")
            }
            try await app.testing().test(.GET, "/v1.51/containers/container-1/attach/ws") { response async in
                #expect(response.status == .notImplemented)
            }
            for (method, path) in [
                (HTTPMethod.GET, "/v1.51/swarm"),
                (HTTPMethod.GET, "/v1.51/plugins"),
                (HTTPMethod.POST, "/v1.51/session"),
            ] {
                try await app.testing().test(method, path) { response async in
                    #expect(response.status == .notImplemented)
                }
            }
            try await app.testing().test(.GET, "/v1.51/system/df") { response async throws in
                #expect(response.status == .ok)
                let value = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
                #expect(value?["Images"] is [[String: Any]])
                #expect(value?["Containers"] is [[String: Any]])
            }
        }
    }

    @Test("container state and metadata operations use Docker response statuses")
    func containerStateOperations() async throws {
        let backend = DockerRuntimeBackendMock()
        try await withRuntimeRoutes(backend) { app in
            try await app.testing().test(
                .POST,
                "/v1.51/containers/container-1/rename",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: #"{"Name":"renamed"}"#)
            ) { response async in
                #expect(response.status == .noContent)
            }
            try await app.testing().test(.POST, "/v1.51/containers/container-1/pause") { response async in
                #expect(response.status == .noContent)
            }
            try await app.testing().test(.POST, "/v1.51/containers/container-1/unpause") { response async in
                #expect(response.status == .noContent)
            }
            try await app.testing().test(.POST, "/v1.51/containers/container-1/resize?w=120&h=40") { response async in
                #expect(response.status == .noContent)
            }
            try await app.testing().test(.POST, "/v1.51/containers/container-1/restart?t=0") { response async in
                #expect(response.status == .noContent)
            }
        }
        #expect(await backend.lastRename == "renamed")
        let resize = await backend.lastResize
        #expect(resize?.0 == 120)
        #expect(resize?.1 == 40)
    }

    @Test("top, non-streaming stats, and export map guest data")
    func processAndFilesystemRoutes() async throws {
        let backend = DockerRuntimeBackendMock()
        try await withRuntimeRoutes(backend) { app in
            try await app.testing().test(
                .GET,
                "/v1.51/containers/container-1/top?ps_args=-ef"
            ) { response async throws in
                #expect(response.status == .ok)
                let value = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
                #expect(value?["Titles"] as? [String] == ["PID", "CMD"])
                #expect(value?["Processes"] as? [[String]] == [["42", "/bin/sh"]])
            }
            try await app.testing().test(
                .GET,
                "/v1.51/containers/container-1/stats?stream=0"
            ) { response async throws in
                #expect(response.status == .ok)
                let value = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
                #expect(value?["id"] as? String == "container-1")
                #expect(value?["pids_stats"] is [String: Any])
                #expect(!response.body.string.hasSuffix("\n"))
            }
            try await app.testing().test(.GET, "/v1.51/containers/container-1/export") { response async in
                #expect(response.status == .ok)
                #expect(response.headers.contentType == HTTPMediaType(type: "application", subType: "octet-stream"))
                #expect(Data(buffer: response.body) == Data("rootfs-tar".utf8))
            }
            try await app.testing().test(
                .GET,
                "/v1.51/containers/container-1/archive?path=%2Fetc"
            ) { response async in
                #expect(response.status == .ok)
                #expect(response.headers.first(name: "X-Docker-Container-Path-Stat") != nil)
                #expect(Data(buffer: response.body) == Data("container-tar".utf8))
            }
            try await app.testing().test(
                .HEAD,
                "/v1.51/containers/container-1/archive?path=%2Fetc"
            ) { response async in
                #expect(response.status == .ok)
                #expect(response.headers.first(name: "X-Docker-Container-Path-Stat") != nil)
                #expect(response.body.readableBytes == 0)
            }
            try await app.testing().test(
                .PUT,
                "/v1.51/containers/container-1/archive?path=%2Ftmp",
                body: ByteBuffer(string: "container-tar")
            ) { response async in
                #expect(response.status == .ok)
            }
            try await app.testing().test(.GET, "/v1.51/containers/container-1/changes") { response async throws in
                #expect(response.status == .ok)
                let value = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [[String: Any]]
                #expect(value?.first?["Path"] as? String == "/etc/fixture")
                #expect(value?.first?["Kind"] as? Int == 0)
            }
        }
        #expect(await backend.lastTopArguments == ["-ef"])
        #expect(await backend.lastArchiveData == Data("container-tar".utf8))
    }

    @Test("container prune removes stopped containers and reports Docker fields")
    func containerPrune() async throws {
        let backend = DockerRuntimeBackendMock()
        try await withRuntimeRoutes(backend) { app in
            try await app.testing().test(.POST, "/v1.51/containers/prune") { response async throws in
                #expect(response.status == .ok)
                let value = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
                #expect(value?["ContainersDeleted"] as? [String] == ["container-1"])
                #expect(value?["SpaceReclaimed"] as? Int == 0)
            }
        }
        #expect(await backend.lastDelete?.force == false)
        #expect(await backend.lastDelete?.volumes == false)
    }

    @Test("container prune rejects filters it cannot apply")
    func containerPruneRejectsUnsupportedFilter() async throws {
        let backend = DockerRuntimeBackendMock()
        try await withRuntimeRoutes(backend) { app in
            let filters = "%7B%22status%22:%5B%22exited%22%5D%7D"
            try await app.testing().test(.POST, "/v1.51/containers/prune?filters=\(filters)") { response async in
                #expect(response.status == .badRequest)
            }
        }
        #expect(await backend.lastDelete == nil)
    }

    @Test("healthy wait and detached exec are explicit 501 responses")
    func unsupportedRuntimeVariants() async throws {
        let backend = DockerRuntimeBackendMock()
        try await withRuntimeRoutes(backend) { app in
            try await app.testing().test(.POST, "/v1.51/containers/container-1/wait?condition=healthy") { response async in
                #expect(response.status == .notImplemented)
            }
            try await app.testing().test(
                .POST,
                "/v1.51/containers/container-1/exec",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: #"{"Cmd":["true"]}"#)
            ) { response async throws in
                #expect(response.status == .created)
            }
            try await app.testing().test(
                .POST,
                "/v1.51/exec/exec-1/start",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: #"{"Detach":true}"#)
            ) { response async in
                #expect(response.status == .notImplemented)
            }
        }
    }

    @Test("attach honors Docker's false stream defaults")
    func attachWithoutUpgrade() async throws {
        let backend = DockerRuntimeBackendMock()
        try await withRuntimeRoutes(backend) { app in
            try await app.testing().test(
                .POST,
                "/v1.51/containers/container-1/attach?stdout=1&stderr=1"
            ) { response async in
                #expect(response.status == .ok)
                #expect(response.headers.first(name: "Upgrade") == nil)
            }
        }
        #expect(await backend.startCount == 0)
    }

    @Test("unsupported create options fail explicitly")
    func unsupportedCreateOptions() async throws {
        let backend = DockerRuntimeBackendMock()
        try await withRuntimeRoutes(backend) { app in
            for body in [
                #"{"Image":"fixture","HostConfig":{"Privileged":true}}"#,
                #"{"Image":"fixture","HostConfig":{"Memory":1048576}}"#,
                #"{"Image":"fixture","HostConfig":{"RestartPolicy":{"Name":"always"}}}"#,
                #"{"Image":"fixture","HostConfig":{"NetworkMode":"host"}}"#,
                #"{"Image":"fixture","OpenStdin":true}"#,
            ] {
                try await app.testing().test(
                    .POST, "/v1.51/containers/create",
                    headers: ["Content-Type": "application/json"], body: ByteBuffer(string: body)
                ) { response async in
                    #expect(response.status == .notImplemented)
                }
            }
            try await app.testing().test(
                .POST, "/v1.51/containers/create",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(
                    string: #"{"Image":"fixture","HostConfig":{"Privileged":false,"Memory":0,"NetworkMode":"default"}}"#)
            ) { response async in
                #expect(response.status == .created)
            }
        }
    }

    @Test("image import fails explicitly")
    func unsupportedImageImport() async throws {
        let backend = DockerRuntimeBackendMock()
        try await withRuntimeRoutes(backend) { app in
            try await app.testing().test(.POST, "/v1.51/images/create?fromSrc=-") { response async in
                #expect(response.status == .notImplemented)
            }
        }
    }

    @Test("attach upgrades without starting a created container")
    func attachDoesNotStartContainer() async throws {
        let backend = DockerRuntimeBackendMock()
        try await withRuntimeRoutes(backend) { app in
            try await app.testing().test(
                .POST,
                "/v1.51/containers/container-1/attach?stream=1&stdout=1&stderr=1",
                headers: ["Connection": "Upgrade", "Upgrade": "tcp"]
            ) { response async in
                #expect(response.status == .switchingProtocols)
                #expect(response.headers.first(name: "Upgrade") == "tcp")
                let bytes = Array(response.body.readableBytesView)
                #expect(Array(bytes.prefix(8)) == [1, 0, 0, 0, 0, 0, 0, 3])
            }
        }
        #expect(await backend.startCount == 0)
    }
}

private func withRuntimeRoutes(
    _ backend: DockerRuntimeBackendMock,
    test: @escaping (Application) async throws -> Void
) async throws {
    try await withApp(configure: { _ in }) { app in
        let router = app.regexRouter(with: app.logger)
        app.setRegexRouter(router)
        try app.register(collection: DockerRuntimeRoutes(backend: backend))
        try await test(app)
    }
}

private actor DockerRuntimeBackendMock: DockerRuntimeRouteBackend {
    struct Pull: Equatable {
        let reference: String
        let platform: String?
    }
    struct Delete: Equatable {
        let force: Bool
        let volumes: Bool
    }
    struct Push: Equatable {
        let source: String
        let target: String
        let platform: String?
    }

    private(set) var lastPull: Pull?
    private(set) var lastCreate: DockerRuntimeContainerCreate?
    private(set) var lastWaitCondition: ContainerWaitCondition?
    private(set) var lastListShowAll: Bool?
    private(set) var lastDelete: Delete?
    private(set) var lastExec: DockerRuntimeExecCreate?
    private(set) var lastImageDeleteForce: Bool?
    private(set) var lastTagTarget: String?
    private(set) var lastPruneAll: Bool?
    private(set) var lastExportReferences: [String]?
    private(set) var lastPush: Push?
    private(set) var lastTopArguments: [String]?
    private(set) var lastArchiveData: Data?
    private(set) var lastRename: String?
    private(set) var lastResize: (UInt32, UInt32)?
    private(set) var startCount = 0
    private var running = false
    private var paused = false
    private let logOutput: String?

    init(logOutput: String? = nil) {
        self.logOutput = logOutput
    }

    func pullImage(
        reference: String, platform: String?, auth: DockerRegistryAuth?
    ) async throws -> DockerRuntimeImage {
        lastPull = Pull(reference: reference, platform: platform)
        return DockerRuntimeImage(reference: reference, digest: "sha256:abc")
    }

    func listImages() async throws -> [DockerRuntimeImage] {
        [DockerRuntimeImage(reference: "example.test/fixture:latest", digest: "sha256:abc")]
    }

    func inspectImage(reference: String) async throws -> DockerRuntimeImage {
        guard reference != "missing" else { throw DockerRuntimeRouteError.notFound("No such image: missing") }
        return DockerRuntimeImage(
            reference: reference,
            digest: "sha256:abc",
            rootFSLayers: ["sha256:layer"],
            history: [
                DockerRuntimeImageHistory(
                    created: Date(timeIntervalSince1970: 1_700_000_000),
                    createdBy: "/bin/sh -c fixture",
                    tags: [],
                    size: 12,
                    comment: "",
                    emptyLayer: false
                )
            ]
        )
    }

    func deleteImage(reference: String, force: Bool) async throws -> DockerRuntimeImageDelete {
        lastImageDeleteForce = force
        return DockerRuntimeImageDelete(deleted: ["sha256:abc"], untagged: [reference], reclaimed: 12)
    }

    func pruneImages(all: Bool) async throws -> DockerRuntimeImageDelete {
        lastPruneAll = all
        return DockerRuntimeImageDelete(deleted: all ? ["sha256:abc"] : [], untagged: [], reclaimed: all ? 12 : 0)
    }

    func tagImage(source: String, target: String) async throws { lastTagTarget = target }

    func pushImage(
        source: String, target: String, platform: String?, auth: DockerRegistryAuth?
    ) async throws -> DockerRuntimeImage {
        lastPush = Push(source: source, target: target, platform: platform)
        return DockerRuntimeImage(reference: target, digest: "sha256:pushed")
    }

    func exportImages(references: [String]) async throws -> AsyncThrowingStream<Data, Error> {
        lastExportReferences = references
        return AsyncThrowingStream { continuation in
            continuation.yield(Data("image-tar".utf8))
            continuation.finish()
        }
    }

    func createContainer(_ request: DockerRuntimeContainerCreate) async throws -> DockerRuntimeContainer {
        lastCreate = request
        return container()
    }

    func startContainer(id: String) async throws {
        startCount += 1
        running = true
        paused = false
    }

    func pauseContainer(id: String) async throws {
        paused = true
        running = false
    }

    func resumeContainer(id: String) async throws {
        paused = false
        running = true
    }

    func resizeContainer(id: String, width: UInt32, height: UInt32) async throws {
        lastResize = (width, height)
    }

    func renameContainer(id: String, name: String) async throws {
        lastRename = name
    }

    func killContainer(id: String, signal: UInt32) async throws {
        running = false
        paused = false
    }

    func waitContainer(id: String, condition: ContainerWaitCondition) async throws -> Int32 {
        lastWaitCondition = condition
        return 7
    }

    func deleteContainer(id: String, force: Bool, removeVolumes: Bool) async throws {
        lastDelete = Delete(force: force, volumes: removeVolumes)
    }

    func inspectContainer(id: String) async throws -> DockerRuntimeContainer {
        guard id != "missing" else { throw DockerRuntimeRouteError.notFound("No such container: missing") }
        return container()
    }

    func listContainers(showAll: Bool) async throws -> [DockerRuntimeContainer] {
        lastListShowAll = showAll
        return [container()]
    }

    func topContainer(id: String, psArguments: [String]) async throws -> DockerRuntimeTop {
        lastTopArguments = psArguments
        return DockerRuntimeTop(Titles: ["PID", "CMD"], Processes: [["42", "/bin/sh"]])
    }

    func statsContainer(id: String) async throws -> DockerRuntimeStats {
        let cpuUsage = DockerRuntimeStats.CPUUsage(
            total_usage: 10, usage_in_kernelmode: 4, usage_in_usermode: 6
        )
        let throttling = DockerRuntimeStats.ThrottlingData(
            throttled_periods: 0, throttled_time: 0, throttling_periods: 0
        )
        let cpu = DockerRuntimeStats.CPUStats(
            cpu_usage: cpuUsage,
            system_cpu_usage: 100,
            online_cpus: 1,
            throttling_data: throttling
        )
        return DockerRuntimeStats(
            id: id,
            read: "2026-08-16T00:00:00Z",
            preread: "2026-08-15T23:59:59Z",
            cpu_stats: cpu,
            precpu_stats: cpu,
            memory_stats: .init(usage: 1, limit: 2, stats: nil),
            networks: nil,
            blkio_stats: .init(io_service_bytes_recursive: nil),
            pids_stats: .init(current: 1)
        )
    }

    func exportContainer(id: String) async throws -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(Data("rootfs-tar".utf8))
            continuation.finish()
        }
    }

    func archiveContainer(id: String, path: String) async throws -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(Data("container-tar".utf8))
            continuation.finish()
        }
    }

    func archiveContainerInfo(id: String, path: String) async throws -> DockerRuntimeArchivePath {
        DockerRuntimeArchivePath(
            name: "etc",
            size: 4,
            mode: 0o755,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            linkTarget: ""
        )
    }

    func putContainerArchive(
        id: String, path: String, data: Data, noOverwriteDirNonDir: Bool
    ) async throws {
        lastArchiveData = data
    }

    func containerChanges(id: String) async throws -> [DockerRuntimeContainerChange] {
        [DockerRuntimeContainerChange(path: "/etc/fixture", kind: 0)]
    }

    func createExec(_ request: DockerRuntimeExecCreate) async throws -> String {
        lastExec = request
        return "exec-1"
    }

    func startExec(id: String, detach: Bool, tty: Bool) async throws -> DockerRuntimeProcessOutput {
        DockerRuntimeProcessOutput(stdout: Data("hello".utf8), exitCode: 23)
    }

    func logs(id: String, stdout: Bool, stderr: Bool) async throws -> DockerRuntimeProcessOutput {
        DockerRuntimeProcessOutput(
            stdout: stdout ? Data((logOutput ?? "out").utf8) : Data(),
            stderr: stderr ? Data((logOutput ?? "err").utf8) : Data(),
            exitCode: 0
        )
    }

    private func container() -> DockerRuntimeContainer {
        DockerRuntimeContainer(
            id: "container-1",
            name: "bench",
            image: "fixture@sha256:abc",
            command: ["/bin/true"],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            state: paused ? .paused : (running ? .running : .created),
            exitCode: nil,
            labels: ["test": "true"],
            tty: false,
            ports: [.init(containerPort: 80, proto: "tcp", hostIP: "127.0.0.1", hostPort: 18080)]
        )
    }
}
