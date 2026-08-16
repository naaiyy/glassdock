import Foundation
import Vapor

struct DockerImageSearchResult: Content, Equatable, Sendable {
    let description: String
    let is_official: Bool
    let is_automated: Bool
    let name: String
    let star_count: Int
}

protocol ImageSearchProviding: Sendable {
    func search(
        term: String,
        limit: Int?,
        filters: [String: [String]],
        auth: DockerRegistryAuth?
    ) async throws -> [DockerImageSearchResult]
}

struct DockerImageSearchHTTPResponse: Sendable {
    let statusCode: Int
    let data: Data
}

enum DockerImageSearchError: Error, Equatable {
    case invalidTerm
    case invalidURL
    case unsupportedFilter(String)
    case upstreamStatus(Int)
    case invalidResponse
}

struct DockerHubImageSearchProvider: ImageSearchProviding {
    typealias Request = @Sendable (URLRequest) async throws -> DockerImageSearchHTTPResponse

    private static let defaultLimit = 25
    private static let pageSize = 100
    private static let maximumPages = 100
    private let request: Request

    init(request: @escaping Request = DockerHubImageSearchProvider.liveRequest) {
        self.request = request
    }

    func search(
        term: String,
        limit: Int?,
        filters: [String: [String]],
        auth: DockerRegistryAuth?
    ) async throws -> [DockerImageSearchResult] {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { throw DockerImageSearchError.invalidTerm }
        let resultLimit = limit ?? Self.defaultLimit
        guard resultLimit > 0 else { return [] }
        try validate(filters: filters)

        var results: [DockerImageSearchResult] = []
        var page = 1
        while results.count < resultLimit, page <= Self.maximumPages {
            var components = URLComponents(string: "https://hub.docker.com/v2/search/repositories/")
            components?.queryItems = [
                URLQueryItem(name: "query", value: term),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "page_size", value: String(Self.pageSize)),
            ]
            guard let url = components?.url else { throw DockerImageSearchError.invalidURL }
            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = "GET"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
            apply(auth: auth, to: &urlRequest)

            let response = try await request(urlRequest)
            guard response.statusCode == 200 else {
                throw DockerImageSearchError.upstreamStatus(response.statusCode)
            }
            let envelope = try JSONDecoder().decode(SearchEnvelope.self, from: response.data)
            let pageResults = envelope.results.compactMap { item -> DockerImageSearchResult? in
                guard let name = item.name ?? item.repoName, !name.isEmpty else { return nil }
                let result = DockerImageSearchResult(
                    description: item.description ?? item.shortDescription ?? "",
                    is_official: item.isOfficial ?? false,
                    is_automated: item.isAutomated ?? false,
                    name: name,
                    star_count: item.starCount ?? 0
                )
                return matches(result, filters: filters) ? result : nil
            }
            results.append(contentsOf: pageResults)
            if envelope.results.count < Self.pageSize { break }
            page += 1
        }
        return Array(results.prefix(resultLimit))
    }

    private static func liveRequest(_ request: URLRequest) async throws -> DockerImageSearchHTTPResponse {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw DockerImageSearchError.invalidResponse
        }
        return DockerImageSearchHTTPResponse(statusCode: response.statusCode, data: data)
    }

    private func apply(auth: DockerRegistryAuth?, to request: inout URLRequest) {
        guard let auth, Self.isDockerHubAuth(auth) else { return }
        if let identityToken = auth.identitytoken, !identityToken.isEmpty {
            request.setValue("Bearer \(identityToken)", forHTTPHeaderField: "Authorization")
        } else if let username = auth.username, let password = auth.password {
            let credentials = Data("\(username):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        }
    }

    private static func isDockerHubAuth(_ auth: DockerRegistryAuth) -> Bool {
        guard let server = auth.serveraddress?.lowercased(), !server.isEmpty else { return true }
        return server.contains("docker.io") || server.contains("index.docker.io")
    }

    private func validate(filters: [String: [String]]) throws {
        for key in filters.keys where key != "is-official" && key != "is-automated" && key != "stars" {
            throw DockerImageSearchError.unsupportedFilter(key)
        }
        for key in ["is-official", "is-automated"] {
            guard let values = filters[key] else { continue }
            guard values.allSatisfy({ MobyBool.parse($0) != nil }) else {
                throw DockerImageSearchError.unsupportedFilter(key)
            }
        }
        if let values = filters["stars"], values.contains(where: { Int($0) == nil || Int($0)! < 0 }) {
            throw DockerImageSearchError.unsupportedFilter("stars")
        }
    }

    private func matches(_ result: DockerImageSearchResult, filters: [String: [String]]) -> Bool {
        if let values = filters["is-official"], !values.isEmpty {
            guard values.contains(where: { MobyBool.parse($0) == result.is_official }) else { return false }
        }
        if let values = filters["is-automated"], !values.isEmpty {
            guard values.contains(where: { MobyBool.parse($0) == result.is_automated }) else { return false }
        }
        if let values = filters["stars"], !values.isEmpty {
            guard let minimum = values.compactMap(Int.init).min(), result.star_count >= minimum else { return false }
        }
        return true
    }

    private struct SearchEnvelope: Decodable {
        let results: [SearchItem]
    }

    private struct SearchItem: Decodable {
        let name: String?
        let repoName: String?
        let description: String?
        let shortDescription: String?
        let isOfficial: Bool?
        let isAutomated: Bool?
        let starCount: Int?

        private enum CodingKeys: String, CodingKey {
            case name
            case repoName = "repo_name"
            case description
            case shortDescription = "short_description"
            case isOfficial = "is_official"
            case isAutomated = "is_automated"
            case starCount = "star_count"
        }
    }
}

struct ImageSearchRoute: RouteCollection {
    let provider: any ImageSearchProviding

    init(provider: any ImageSearchProviding = DockerHubImageSearchProvider()) {
        self.provider = provider
    }

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/images/search", use: handler)
    }

    private func handler(_ req: Request) async throws -> Response {
        guard let term = req.query[String.self, at: "term"], !term.isEmpty else {
            throw Abort(.badRequest, reason: "Missing search term")
        }
        let filters = try Self.filters(req.query[String.self, at: "filters"])
        let limit = try Self.limit(req.query[String.self, at: "limit"])
        let auth = try Self.registryAuth(req.headers.first(name: "X-Registry-Auth"))
        do {
            let results = try await provider.search(
                term: term,
                limit: limit,
                filters: filters,
                auth: auth
            )
            let response = Response(status: .ok, body: .init(data: try JSONEncoder().encode(results)))
            response.headers.contentType = .json
            return response
        } catch let error as DockerImageSearchError {
            switch error {
            case .invalidTerm, .invalidURL, .invalidResponse:
                throw Abort(.badRequest, reason: String(describing: error))
            case .unsupportedFilter(let filter):
                throw Abort(.badRequest, reason: "Unsupported image search filter: \(filter)")
            case .upstreamStatus(let status):
                throw Abort(.internalServerError, reason: "Image search upstream returned HTTP \(status)")
            }
        }
    }

    private static func filters(_ value: String?) throws -> [String: [String]] {
        guard let value, !value.isEmpty else { return [:] }
        guard let data = value.data(using: .utf8),
            let filters = try? JSONDecoder().decode([String: [String]].self, from: data)
        else {
            throw Abort(.badRequest, reason: "Invalid image search filters")
        }
        return filters
    }

    private static func limit(_ value: String?) throws -> Int? {
        guard let value, !value.isEmpty else { return nil }
        guard let limit = Int(value), limit > 0 else {
            throw Abort(.badRequest, reason: "Image search limit must be a positive integer")
        }
        return limit
    }

    private static func registryAuth(_ value: String?) throws -> DockerRegistryAuth? {
        guard let value, !value.isEmpty else { return nil }
        var normalized = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        guard let data = Data(base64Encoded: normalized),
            let auth = try? JSONDecoder().decode(DockerRegistryAuth.self, from: data)
        else {
            throw Abort(.badRequest, reason: "Invalid X-Registry-Auth header")
        }
        return auth
    }
}
