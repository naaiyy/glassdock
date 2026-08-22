import Vapor

struct VersionRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/version", use: VersionRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        do {
            let version = VersionInfo(
                Platform: ServerPlatform(Name: "glassdock"),
                Components: [Component(Name: "glassdock", Version: getBuildVersion())],
                Version: getBuildVersion(),
                ApiVersion: normalizedAPIValue(getDockerEngineApiMaxVersion()),
                MinAPIVersion: normalizedAPIValue(getDockerEngineApiMinVersion()),
                GitCommit: getBuildGitCommit(),
                Os: "macOS",
                Arch: "arm64",
                KernelVersion: getKernel(),
                Experimental: false,
                BuildTime: getBuildTime(),
            )
            return try await version.encodeResponse(for: req)
        } catch {
            let response = Response(status: .internalServerError)
            response.headers.add(name: .contentType, value: "application/json")
            response.body = .init(string: "{\"message\": \"Failed to generate version information\"}\n")
            return response
        }
    }

    private static func normalizedAPIValue(_ value: String) -> String {
        value.hasPrefix("v") ? String(value.dropFirst()) : value
    }
}
