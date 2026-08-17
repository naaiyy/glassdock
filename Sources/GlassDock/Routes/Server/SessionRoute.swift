import Vapor

struct SessionRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/session", use: SessionRoute.handler)
        try routes.registerVersionedRoute(.GET, pattern: "/session", use: SessionRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        let connection = req.headers.first(name: "Connection")?.lowercased() ?? ""
        let upgrade = req.headers.first(name: "Upgrade")?.lowercased() ?? ""
        let tokens = connection.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard tokens.contains("upgrade"), upgrade == "tcp" || upgrade == "h2c" else {
            throw Abort(.badRequest, reason: "session requires a Docker HTTP upgrade handshake")
        }
        var headers = HTTPHeaders()
        headers.add(name: "Connection", value: "Upgrade")
        headers.add(name: "Upgrade", value: upgrade)
        return Response(status: .switchingProtocols, headers: headers)
    }
}
