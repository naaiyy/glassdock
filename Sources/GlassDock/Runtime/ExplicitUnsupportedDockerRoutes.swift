import Vapor

/// Serves the Docker control-plane endpoint families that a single-node
/// container runtime cannot honor. The responses mirror what the pinned
/// Moby v28.5.2 daemon returns when Swarm is uninitialized and no plugins
/// are installed, so clients observe real Docker behavior instead of a
/// generic router 404.
struct ExplicitUnsupportedDockerRoutes: RouteCollection {
    private struct Endpoint {
        let method: HTTPMethod
        let pattern: String
    }

    /// Moby's `errNoManager` for manager-only operations on an
    /// uninitialized daemon (daemon/cluster/cluster.go).
    private static let swarmManagerMessage =
        #"This node is not a swarm manager. Use "docker swarm init" or "docker swarm join" to connect this node to swarm and try again."#

    /// Moby's `errNoSwarm` for leaving a cluster that was never initialized
    /// (daemon/cluster/errors.go).
    private static let noSwarmMessage = "This node is not part of a swarm"

    private static let endpoints: [Endpoint] = [
        // Swarm
        Endpoint(method: .GET, pattern: "/swarm"),
        Endpoint(method: .POST, pattern: "/swarm/init"),
        Endpoint(method: .POST, pattern: "/swarm/join"),
        Endpoint(method: .POST, pattern: "/swarm/leave"),
        Endpoint(method: .POST, pattern: "/swarm/update"),
        Endpoint(method: .POST, pattern: "/swarm/unlock"),
        Endpoint(method: .GET, pattern: "/swarm/unlockkey"),

        // Nodes
        Endpoint(method: .GET, pattern: "/nodes"),
        Endpoint(method: .GET, pattern: "/nodes/{id}"),
        Endpoint(method: .POST, pattern: "/nodes/{id}/update"),
        Endpoint(method: .DELETE, pattern: "/nodes/{id}"),

        // Services
        Endpoint(method: .GET, pattern: "/services"),
        Endpoint(method: .POST, pattern: "/services/create"),
        Endpoint(method: .GET, pattern: "/services/{id}"),
        Endpoint(method: .POST, pattern: "/services/{id}/update"),
        Endpoint(method: .GET, pattern: "/services/{id}/logs"),
        Endpoint(method: .DELETE, pattern: "/services/{id}"),

        // Tasks
        Endpoint(method: .GET, pattern: "/tasks"),
        Endpoint(method: .GET, pattern: "/tasks/{id}"),
        Endpoint(method: .GET, pattern: "/tasks/{id}/logs"),

        // Secrets
        Endpoint(method: .GET, pattern: "/secrets"),
        Endpoint(method: .POST, pattern: "/secrets/create"),
        Endpoint(method: .GET, pattern: "/secrets/{id}"),
        Endpoint(method: .POST, pattern: "/secrets/{id}/update"),
        Endpoint(method: .DELETE, pattern: "/secrets/{id}"),

        // Configs
        Endpoint(method: .GET, pattern: "/configs"),
        Endpoint(method: .POST, pattern: "/configs/create"),
        Endpoint(method: .GET, pattern: "/configs/{id}"),
        Endpoint(method: .POST, pattern: "/configs/{id}/update"),
        Endpoint(method: .DELETE, pattern: "/configs/{id}"),
    ]

    func boot(routes: RoutesBuilder) throws {
        for endpoint in Self.endpoints {
            try routes.registerVersionedRoute(
                endpoint.method,
                pattern: endpoint.pattern,
                use: swarmUnavailable
            )
        }

        try routes.registerVersionedRoute(.GET, pattern: "/plugins", use: listPlugins)
        try routes.registerVersionedRoute(.GET, pattern: "/plugins/privileges", use: pluginPullTargetMissing)
        try routes.registerVersionedRoute(.POST, pattern: "/plugins/pull", use: pluginPullTargetMissing)
        try routes.registerVersionedRoute(.POST, pattern: "/plugins/create", use: pluginCreateTargetMissing)
        try routes.registerVersionedRoute(.GET, pattern: "/plugins/{name:.*}/json", use: pluginMissing)
        try routes.registerVersionedRoute(.POST, pattern: "/plugins/{name:.*}/enable", use: pluginMissing)
        try routes.registerVersionedRoute(.POST, pattern: "/plugins/{name:.*}/disable", use: pluginMissing)
        try routes.registerVersionedRoute(.POST, pattern: "/plugins/{name:.*}/push", use: pluginMissing)
        try routes.registerVersionedRoute(.POST, pattern: "/plugins/{name:.*}/set", use: pluginMissing)
        try routes.registerVersionedRoute(.POST, pattern: "/plugins/{name:.*}/upgrade", use: pluginMissing)
        try routes.registerVersionedRoute(.DELETE, pattern: "/plugins/{name:.*}", use: pluginMissing)
    }

    private func swarmUnavailable(_ request: Request) async throws -> Response {
        let message =
            request.url.path.hasSuffix("/leave")
            ? Self.noSwarmMessage : Self.swarmManagerMessage
        throw Abort(.serviceUnavailable, reason: message)
    }

    /// A fresh Docker daemon has no plugins installed, so listing returns an
    /// empty array and every other plugin operation reports Moby's exact
    /// `plugin %q not found` 404 error (plugin/errors.go).
    private func listPlugins(_ request: Request) async throws -> [String] { [] }

    private func pluginPullTargetMissing(_ request: Request) async throws -> Response {
        let name = request.query[String.self, at: "remote"] ?? ""
        throw Abort(.notFound, reason: "plugin \(String(reflecting: name)) not found")
    }

    private func pluginCreateTargetMissing(_ request: Request) async throws -> Response {
        let name = request.query[String.self, at: "name"] ?? ""
        throw Abort(.notFound, reason: "plugin \(String(reflecting: name)) not found")
    }

    private func pluginMissing(_ request: Request) async throws -> Response {
        throw Abort(.notFound, reason: "plugin \(String(reflecting: request.parameters.get("name") ?? "")) not found")
    }
}
