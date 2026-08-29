import Foundation
import NIOCore
import NIOPosix
import Testing
import Vapor
import VaporTesting

@testable import GlassDock

/// Pins the header-commit behavior of streaming responses on a real socket.
///
/// `docker run -d` opens POST /containers/{id}/wait and blocks on its response
/// headers BEFORE sending the container start request; Moby commits those
/// headers immediately. Vapor defers the header flush until the first body
/// byte, so streaming routes must emit an empty first chunk. Without it the
/// Docker CLI hangs forever with containers stuck in "created".
@Suite("Streaming header commitment")
struct StreamingHeaderCommitTests {
    @Test("wait sends headers before the backend wait completes")
    func waitHeadersArriveEarly() async throws {
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("st-header-\(UUID().uuidString.prefix(8)).sock")
        defer { try? FileManager.default.removeItem(atPath: temporary.path) }

        try await withApp(configure: { app in
            // Ignore the test harness arguments, mirroring main.swift.
            app.environment.commandInput.arguments = ["serve"]
            var middleware = Middlewares()
            middleware.use(DockerErrorMiddleware(), at: .beginning)
            app.middleware = middleware
            let router = app.regexRouter(with: app.logger)
            app.setRegexRouter(router)
            // 3 seconds: headers must beat the backend completion by a wide margin.
            let backend = DockerRuntimeBackendMock(waitDelayNanoseconds: 3_000_000_000)
            try app.register(
                collection: DockerRuntimeRoutes(backend: backend, volumeClient: nil)
            )
            app.http.server.configuration.address =
                .unixDomainSocket(path: temporary.path)
            app.http.server.configuration.serverName = nil
        }) { app in
            // Bind the real HTTP server on the unix socket.
            try await app.startup()

            final class HeaderCollector: ChannelInboundHandler, @unchecked Sendable {
                typealias InboundIn = ByteBuffer
                var received = Data()

                func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                    var buffer = unwrapInboundIn(data)
                    received.append(buffer.readData(length: buffer.readableBytes) ?? Data())
                }
            }

            let collector = HeaderCollector()
            let channel = try await ClientBootstrap(group: app.eventLoopGroup)
                .connect(to: SocketAddress(unixDomainSocketPath: temporary.path))
                .get()
            _ = try await channel.pipeline.addHandler(collector).get()
            var request = channel.allocator.buffer(capacity: 256)
            request.writeString(
                "POST /v1.51/containers/container-1/wait?condition=next-exit HTTP/1.1\r\n"
                    + "Host: docker\r\nContent-Length: 0\r\n\r\n"
            )
            try await channel.writeAndFlush(request).get()

            // Poll for up to 1 second: headers must arrive while the backend is
            // still blocked for ~3 seconds.
            let deadline = Date().addingTimeInterval(1.0)
            while !collector.received.contains(Data("HTTP/1.1".utf8)), Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            channel.close(promise: nil)

            #expect(
                collector.received.contains(Data("HTTP/1.1 200 OK".utf8)),
                Comment(
                    rawValue: "wait headers did not arrive before the backend completed; "
                        + "docker run -d would hang: "
                        + String(decoding: collector.received, as: UTF8.self)
                )
            )
        }
    }
}
