import Vapor

/// Docker Engine API `PUT /volumes/{name}` only updates Swarm cluster
/// volumes. Moby v28.5.2 rejects it with a 503 before any validation when
/// the daemon is not part of a swarm (api/server/router/volume/
/// volume_routes.go, putVolumesUpdate). Glass Dock has no swarm manager,
/// so this route always returns that exact error.
struct VolumeUpdateRoute: RouteCollection {
    static let unavailableMessage =
        "volume update only valid for cluster volumes, but swarm is unavailable"

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.PUT, pattern: "/volumes/{name:.*}", use: handler)
    }

    func handler(_ req: Request) async throws -> Response {
        throw Abort(.serviceUnavailable, reason: Self.unavailableMessage)
    }
}
