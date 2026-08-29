import NIOCore
import NIOPosix
import Testing
import VaporTesting

@testable import GlassDock

@Suite("Builder relay")
struct BuilderRelayTests {
    private func makeSnapshot(builderSocket: URL) -> RuntimeMachineReady {
        RuntimeMachineReady(
            generation: UUID(),
            processIdentifier: 1,
            guestIPv4: "192.168.127.2",
            hostGatewayIPv4: "192.168.127.1",
            gvproxyAPI: URL(fileURLWithPath: "/tmp/unused-gvproxy.sock"),
            tcpRelaySocket: URL(fileURLWithPath: "/tmp/unused-tcp-relay.sock"),
            builderSocket: builderSocket
        )
    }

    /// Connects a client to the relay and collects bytes until EOF or timeout.
    /// The relay may answer and close before the client finishes writing (the
    /// 503 path closes eagerly); such attempts surface as EPIPE or an empty
    /// read and are retried.
    private func collectRelayResponse(
        eventLoopGroup: any EventLoopGroup, socketPath: String, request: String,
        attempts: Int = 8
    ) async throws -> String {
        for _ in 1...attempts {
            do {
                if let response = try await attemptOnce(
                    eventLoopGroup: eventLoopGroup, socketPath: socketPath, request: request
                ) {
                    return response
                }
            } catch {
                // The relay may have answered and torn the connection down
                // before our write landed; retry.
                continue
            }
        }
        return ""
    }

    private func attemptOnce(
        eventLoopGroup: any EventLoopGroup, socketPath: String, request: String
    ) async throws -> String? {
        final class Collector: ChannelInboundHandler, @unchecked Sendable {
            typealias InboundIn = ByteBuffer
            var received = Data()

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                var buffer = unwrapInboundIn(data)
                received.append(buffer.readData(length: buffer.readableBytes) ?? Data())
            }
        }

        let address = try SocketAddress(unixDomainSocketPath: socketPath)
        let collector = Collector()
        let channel = try await ClientBootstrap(group: eventLoopGroup)
            .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .connect(to: address)
            .get()
        _ = try await channel.pipeline.addHandler(collector).get()
        var buffer = channel.allocator.buffer(capacity: request.utf8.count)
        buffer.writeString(request)
        channel.writeAndFlush(buffer).whenComplete { [channel] _ in
            channel.close(mode: .output, promise: nil)
        }
        // Give the peer a moment to answer, then decide from what arrived.
        try await Task.sleep(for: .milliseconds(200))
        channel.close(promise: nil)
        return collector.received.isEmpty ? nil : String(decoding: collector.received, as: UTF8.self)
    }

    @Test("an instant-ready engine answers unavailable dials without crashing")
    func instantReadyUnavailable() async throws {
        // Regression: when the engine is already warm, ready() resolved before
        // the promise callback was registered and its continuation ran on a
        // cooperative-pool thread. Touching the loop-bound handler context
        // there trapped and killed the daemon on every /session or /grpc dial.
        try await withApp(configure: { _ in }) { app in
            let relaySocket = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("st-builder-\(UUID().uuidString.prefix(8)).sock")
            defer { try? FileManager.default.removeItem(atPath: relaySocket.path) }
            let missingBuilder = URL(fileURLWithPath: "/tmp/st-missing-builder-\(UUID().uuidString)")
            let snapshot = makeSnapshot(builderSocket: missingBuilder)
            let relay = BuilderRelay(eventLoopGroup: app.eventLoopGroup, ready: { snapshot })
            try relay.start(socketPath: relaySocket.path)
            defer { relay.stop() }

            for _ in 0..<20 {
                let response = try await collectRelayResponse(
                    eventLoopGroup: app.eventLoopGroup,
                    socketPath: relaySocket.path,
                    request: "POST /session HTTP/1.1\r\nHost: docker\r\n\r\n"
                )
                #expect(response.contains("503 Service Unavailable"))
                #expect(response.contains("builder is unavailable"))
            }
        }
    }

    @Test("a failing readiness provider answers unavailable instead of hanging")
    func failedReady() async throws {
        try await withApp(configure: { _ in }) { app in
            let relaySocket = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("st-builder-\(UUID().uuidString.prefix(8)).sock")
            defer { try? FileManager.default.removeItem(atPath: relaySocket.path) }
            struct ReadyError: Error {}
            let relay = BuilderRelay(eventLoopGroup: app.eventLoopGroup) {
                throw ReadyError()
            }
            try relay.start(socketPath: relaySocket.path)
            defer { relay.stop() }

            let response = try await collectRelayResponse(
                eventLoopGroup: app.eventLoopGroup,
                socketPath: relaySocket.path,
                request: "POST /grpc HTTP/1.1\r\nHost: docker\r\n\r\n"
            )
            #expect(response.contains("503 Service Unavailable"))
        }
    }

    @Test("a ready engine relays raw bytes to the guest builder listener")
    func readyRelaysBytes() async throws {
        try await withApp(configure: { _ in }) { app in
            let relaySocket = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("st-builder-\(UUID().uuidString.prefix(8)).sock")
            let builderSocket = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("st-guest-builder-\(UUID().uuidString.prefix(8)).sock")
            defer {
                try? FileManager.default.removeItem(atPath: relaySocket.path)
                try? FileManager.default.removeItem(atPath: builderSocket.path)
            }
            let payload = "buildkit-session-bytes"
            let echo = try await ServerBootstrap(group: app.eventLoopGroup)
                .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .childChannelInitializer { channel in
                    channel.pipeline.addHandler(EchoHandler(payload: payload))
                }
                .bind(unixDomainSocketPath: builderSocket.path)
                .get()
            defer { echo.close(promise: nil) }

            let snapshot = makeSnapshot(builderSocket: builderSocket)
            let relay = BuilderRelay(eventLoopGroup: app.eventLoopGroup, ready: { snapshot })
            try relay.start(socketPath: relaySocket.path)
            defer { relay.stop() }

            let response = try await collectRelayResponse(
                eventLoopGroup: app.eventLoopGroup,
                socketPath: relaySocket.path,
                request: payload
            )
            #expect(response == payload)
        }
    }
}

private final class EchoHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let payload: String

    init(payload: String) {
        self.payload = payload
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.writeAndFlush(data, promise: nil)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event {
            context.close(mode: .output, promise: nil)
        }
    }
}
