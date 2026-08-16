import Vapor

/// Keeps the advertised Docker API surface explicit while the persistent
/// containerd runtime is still alpha. Known endpoints must not fall through to
/// a generic router 404, which clients can misinterpret as a version mismatch.
struct ExplicitUnsupportedDockerRoutes: RouteCollection {
    private struct Endpoint {
        let method: HTTPMethod
        let pattern: String
    }

    private static let endpoints = [
        Endpoint(method: .POST, pattern: "/build"),
        Endpoint(method: .POST, pattern: "/build/prune"),
        Endpoint(method: .DELETE, pattern: "/plugins/{name:.*}"),
        Endpoint(method: .GET, pattern: "/plugins"),
        Endpoint(method: .GET, pattern: "/plugins/privileges"),
        Endpoint(method: .GET, pattern: "/plugins/{name:.*}/json"),
        Endpoint(method: .POST, pattern: "/plugins/create"),
        Endpoint(method: .POST, pattern: "/plugins/pull"),
        Endpoint(method: .POST, pattern: "/plugins/{name:.*}/disable"),
        Endpoint(method: .POST, pattern: "/plugins/{name:.*}/enable"),
        Endpoint(method: .POST, pattern: "/plugins/{name:.*}/push"),
        Endpoint(method: .POST, pattern: "/plugins/{name:.*}/set"),
        Endpoint(method: .POST, pattern: "/plugins/{name:.*}/upgrade"),
        Endpoint(method: .POST, pattern: "/session"),
        Endpoint(method: .PUT, pattern: "/volumes/{name:.*}"),
    ]

    func boot(routes: RoutesBuilder) throws {
        for endpoint in Self.endpoints {
            try routes.registerVersionedRoute(
                endpoint.method,
                pattern: endpoint.pattern,
                use: unsupported
            )
        }
    }

    private func unsupported(_ request: Request) async throws -> Response {
        throw Abort(
            .notImplemented,
            reason: "Docker endpoint \(request.method.rawValue) \(request.url.path) is not implemented by the persistent runtime"
        )
    }
}
