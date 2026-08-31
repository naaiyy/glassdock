import ContainerPersistence
import ContainerResource
import Vapor

func configureDaemonMiddleware(_ app: Application) {
    var middleware = Middlewares()
    middleware.use(RouteLoggingMiddleware(logLevel: .debug))
    middleware.use(ErrorMiddleware.default(environment: app.environment))
    app.middleware = middleware
}

func configure(
    _ app: Application,
    cpuCount: Int = RuntimeMachineConfiguration.defaultCPUCount,
    memoryBytes: UInt64 = RuntimeMachineConfiguration.defaultMemoryBytes,
    directTCPForwarding: Bool = false,
    fastPing: Bool = false
) async throws {
    guard #available(macOS 26.0, *) else {
        throw Abort(.internalServerError, reason: "Glass Dock requires macOS 26 or newer")
    }

    // Docker container-create payloads (large env / config — e.g. Supabase's
    // edge-runtime + storage-api) exceed Vapor's 16 KB default collected-body
    // cap, yielding 413 "Payload Too Large". Raise it well above any real request.
    app.routes.defaultMaxBodySize = "64mb"

    // Make error responses Docker-compatible (`{"message": ...}`) so SDKs like
    // docker-py don't crash on their `response.json()['message']` lookup. Installed
    // outermost so it wraps all routing/error handling. See DockerErrorMiddleware.
    app.middleware.use(DockerErrorMiddleware(), at: .beginning)

    let volumeClient = RuntimeVolumeService()
    let broadcaster = EventBroadcaster()
    app.storage[EventBroadcasterKey.self] = broadcaster
    // A fresh daemon is a reload from Docker clients' point of view. Keep the
    // event in the bounded journal so listeners that connect immediately after
    // startup can observe the same daemon lifecycle transition.
    await broadcaster.broadcast(DockerEvent.daemonReload())
    let engineStateDirectory = GlassDockDirectories.engineStateDirectory
    let engineDataDisk = engineStateDirectory.appendingPathComponent("data.ext4")
    let machineArtifacts = try RuntimeMachineArtifacts.locate()
    let machine = RuntimeMachine(
        configuration: try RuntimeMachineConfiguration(
            helperExecutable: machineArtifacts.helper,
            stateDirectory: engineStateDirectory,
            kernel: machineArtifacts.kernel,
            rootDisk: machineArtifacts.rootDisk,
            dataDisk: engineDataDisk,
            bindSource: GlassDockDirectories.hostHome,
            cpuCount: cpuCount,
            memoryBytes: memoryBytes
        )
    )
    let engine = PersistentEngine(machine: machine, configuredMemoryBytes: memoryBytes)
    app.lifecycle.use(PersistentEngineLifecycle(engine: engine))
    // The builder relay serves hijacked /session and /grpc connections. It must
    // start before the public gateway becomes reachable and stop before the
    // engine tears down its guest connections.
    let builderRelay = BuilderRelay(
        eventLoopGroup: app.eventLoopGroup,
        ready: { try await machine.start() }
    )
    try builderRelay.start(
        socketPath: builderRelaySocketPath(
            homeDirectory: GlassDockDirectories.hostHome.path
        )
    )
    app.lifecycle.use(BuilderRelayLifecycle(relay: builderRelay))
    let ready: @Sendable () async throws -> RuntimeMachineReady = {
        try await machine.start()
    }
    let portController: any PublishedPortControlling =
        if directTCPForwarding {
            DirectTCPPublishedPortController(
                eventLoopGroup: app.eventLoopGroup,
                ready: ready
            )
        } else {
            GVProxyPublishedPortController(ready: ready)
        }
    let portPublisher = GuestPortPublicationManager(
        controller: portController
    )
    app.lifecycle.use(GuestPortPublicationLifecycle(manager: portPublisher))
    let runtime = GuestRuntime(
        engine: engine,
        portPublisher: portPublisher,
        broadcaster: broadcaster,
        volumeService: volumeClient
    )
    await volumeClient.setReferenceValidator { id in
        (try? await runtime.inspectContainer(id: id)) != nil
    }
    app.lifecycle.use(GuestRuntimeLifecycle(runtime: runtime))
    let readiness = RuntimeReadiness {
        _ = try await engine.readyConnection()
        try await runtime.startEventMonitor()
    }
    app.middleware.use(RuntimeReadinessMiddleware(readiness: readiness))
    // Shutdown runs lifecycle handlers in reverse registration order. Cancel
    // unfinished initialization before the runtime tears down its connections.
    app.lifecycle.use(RuntimeReadinessLifecycle(readiness: readiness))

    // Greedy Docker paths install scoped fallback routes as they register.
    let regexRouter = app.regexRouter(with: app.logger)
    app.setRegexRouter(regexRouter)

    // /_ping
    try app.register(collection: HealthCheckPingRoute())

    // /events
    try app.register(collection: EventsRoute())

    try app.register(collection: DockerRuntimeRoutes(backend: runtime, volumeClient: volumeClient))
    try app.register(collection: ImageSearchRoute())
    try app.register(collection: DistributionJsonRoute(systemConfig: ContainerSystemConfig()))
    try app.register(collection: AuthRoute())
    try app.register(collection: SessionRoute())
    try app.register(collection: ExplicitUnsupportedDockerRoutes())

    // /volumes
    try app.register(collection: VolumeCreateRoute(client: volumeClient))
    try app.register(collection: VolumeDeleteRoute(client: volumeClient))
    try app.register(collection: VolumeInspectRoute(client: volumeClient))
    try app.register(collection: VolumeListRoute(client: volumeClient))
    try app.register(collection: VolumePruneRoute(client: volumeClient))
    try app.register(collection: VolumeUpdateRoute())

    // --- miscellaneous ---
    try app.register(collection: VersionRoute())

    // Docker ping is a daemon-liveness response. Keep Vapor's HTTP connection
    // handling, but answer before route lookup, logging, and runtime readiness.
    if fastPing {
        app.responder.use { application in
            DockerPingResponder(next: application.responder.default)
        }
    }
}
