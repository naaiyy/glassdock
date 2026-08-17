import Vapor

/// Keeps the advertised Docker API surface explicit while the persistent
/// containerd runtime is still alpha. Known endpoints must not fall through to
/// a generic router 404, which clients can misinterpret as a version mismatch.
struct ExplicitUnsupportedDockerRoutes: RouteCollection {
    private struct Endpoint {
        let method: HTTPMethod
        let pattern: String
    }

    private static let endpoints: [Endpoint] = []

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
