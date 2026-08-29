import Testing
import VaporTesting

@testable import GlassDock

/// Regression tests for the streaming-route error convention: every streaming
/// route must resolve container/image existence before response headers are
/// committed, so a missing resource is a clean 404 instead of a 200 whose body
/// silently drops. Routes are built through `DockerRuntimeRoutes`
/// `.streamingResponse`, which enforces the resolve phase.
@Suite("Streaming route error conventions")
struct StreamingRouteErrorTests {
    private func expectNotFound(
        _ method: Vapor.HTTPMethod, _ path: String,
        backend: DockerRuntimeBackendMock = DockerRuntimeBackendMock()
    ) async throws {
        try await withRuntimeRoutes(backend) { app in
            try await app.testing().test(method, path) { response async in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test("wait on a missing container is 404 before commit")
    func waitMissing() async throws {
        try await expectNotFound(.POST, "/v1.51/containers/missing/wait")
    }

    @Test("stats on a missing container is 404 before commit")
    func statsMissing() async throws {
        try await expectNotFound(.GET, "/v1.51/containers/missing/stats")
    }

    @Test("export on a missing container is 404 before commit")
    func exportMissing() async throws {
        try await expectNotFound(.GET, "/v1.51/containers/missing/export")
    }

    @Test("archive on a missing container is 404 before commit")
    func archiveMissing() async throws {
        try await expectNotFound(.GET, "/v1.51/containers/missing/archive?path=/tmp")
    }

    @Test("follow logs on a missing container is 404 before commit")
    func followLogsMissing() async throws {
        try await expectNotFound(
            .GET, "/v1.51/containers/missing/logs?follow=1&stdout=1&stderr=1"
        )
    }

    @Test("attach on a missing container is 404 before commit")
    func attachMissing() async throws {
        try await expectNotFound(.POST, "/v1.51/containers/missing/attach?stream=1&stdout=1")
    }

    @Test("image export of a missing image is 404 before commit")
    func imageExportMissing() async throws {
        try await expectNotFound(.GET, "/v1.51/images/missing/get")
    }

    @Test("named image export of a missing image is 404 before commit")
    func namedImageExportMissing() async throws {
        try await expectNotFound(.GET, "/v1.51/images/missing/get?fromImage=missing")
    }
}
