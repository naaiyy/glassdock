import Vapor

struct VolumeUpdateRoute: RouteCollection {
    let client: any ClientVolumeProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.PUT, pattern: "/volumes/{name:.*}", use: handler)
    }

    func handler(_ req: Request) async throws -> Response {
        guard let name = req.parameters.get("name"), !name.isEmpty else {
            throw Abort(.badRequest, reason: "Missing volume name")
        }
        guard let rawVersion = req.query[String.self, at: "version"],
            let version = UInt64(rawVersion)
        else {
            throw Abort(.badRequest, reason: "A valid version query parameter is required")
        }
        let request = try req.content.decode(RESTVolumeUpdate.self)
        let volume: Volume
        if let versionedClient = client as? any VersionedClientVolumeProtocol {
            volume = try await versionedClient.update(name: name, request: request, version: version)
        } else {
            volume = try await client.update(name: name, request: request)
        }
        return try await volume.encodeResponse(for: req)
    }
}
