import Foundation
import NIOCore
import Testing
import Vapor
import VaporTesting

@testable import GlassDock

@Suite("Docker image search route")
struct ImageSearchRouteTests {
    @Test("decodes Docker Hub search results and applies supported filters")
    func provider() async throws {
        let payload =
            #"{"results":[{"repo_name":"library/alpine","short_description":"Alpine Linux","is_official":true,"is_automated":false,"star_count":123},{"repo_name":"example/alpine","short_description":"Example","is_official":false,"is_automated":true,"star_count":2}]}"#
        let provider = DockerHubImageSearchProvider { _ in
            DockerImageSearchHTTPResponse(statusCode: 200, data: Data(payload.utf8))
        }

        let results = try await provider.search(
            term: "alpine",
            limit: 1,
            filters: ["is-official": ["true"], "stars": ["10"]],
            auth: nil
        )

        #expect(
            results == [
                DockerImageSearchResult(
                    description: "Alpine Linux",
                    is_official: true,
                    is_automated: false,
                    name: "library/alpine",
                    star_count: 123
                )
            ])
    }

    @Test("returns Docker search fields and forwards filters")
    func search() async throws {
        let provider = FakeImageSearchProvider()
        try await withImageSearchApp(provider: provider) { app in
            try await app.testing().test(
                .GET,
                "/v1.51/images/search?term=alpine&limit=2&filters=%7B%22is-official%22:%5B%22true%22%5D%7D"
            ) { response async throws in
                #expect(response.status == .ok)
                #expect(response.headers.contentType == .json)
                let results = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [[String: Any]]
                #expect(results?.first?["name"] as? String == "library/alpine")
                #expect(results?.first?["is_official"] as? Bool == true)
                #expect(results?.first?["star_count"] as? Int == 123)
            }
        }
        let request = await provider.lastRequest
        #expect(request?.term == "alpine")
        #expect(request?.limit == 2)
        #expect(request?.filters["is-official"] == ["true"])
    }

    @Test("rejects a missing term and malformed filters")
    func validatesQuery() async throws {
        let provider = FakeImageSearchProvider()
        try await withImageSearchApp(provider: provider) { app in
            try await app.testing().test(.GET, "/v1.51/images/search") { response async in
                #expect(response.status == .badRequest)
            }
            try await app.testing().test(.GET, "/v1.51/images/search?term=alpine&filters=bad") { response async in
                #expect(response.status == .badRequest)
            }
        }
    }
}

private func withImageSearchApp(
    provider: any ImageSearchProviding,
    test: @escaping (Application) async throws -> Void
) async throws {
    try await withApp(configure: { _ in }) { app in
        let router = app.regexRouter(with: app.logger)
        app.setRegexRouter(router)
        try app.register(collection: ImageSearchRoute(provider: provider))
        try await test(app)
    }
}

private actor FakeImageSearchProvider: ImageSearchProviding {
    struct Request: Equatable {
        let term: String
        let limit: Int?
        let filters: [String: [String]]
    }

    private(set) var lastRequest: Request?

    func search(
        term: String,
        limit: Int?,
        filters: [String: [String]],
        auth: DockerRegistryAuth?
    ) async throws -> [DockerImageSearchResult] {
        lastRequest = Request(term: term, limit: limit, filters: filters)
        return [
            DockerImageSearchResult(
                description: "A small Linux image",
                is_official: true,
                is_automated: false,
                name: "library/alpine",
                star_count: 123
            )
        ]
    }
}
