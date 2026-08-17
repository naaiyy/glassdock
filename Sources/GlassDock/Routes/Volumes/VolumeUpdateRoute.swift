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
        let request = try req.content.decode(RESTVolumeUpdate.self)
        let volume = try await client.update(name: name, request: request)
        return try await volume.encodeResponse(for: req)
    }
}
