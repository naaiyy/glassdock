import Darwin
import Foundation
import NIOCore
import NIOPosix

/// Accepts hijacked Docker API connections (/session, /grpc) from the C ping
/// gateway and relays raw bytes to the guest agent's BuildKit listener over
/// vsock port 1027. The relay owns no protocol state: both endpoints speak
/// Docker's upgrade semantics directly.
final class BuilderRelay: @unchecked Sendable {
    typealias ReadyProvider = @Sendable () async throws -> RuntimeMachineReady

    private let ready: ReadyProvider
    private let eventLoopGroup: any EventLoopGroup
    private let lock = NSLock()
    private var serverChannel: Channel?

    init(eventLoopGroup: any EventLoopGroup, ready: @escaping ReadyProvider) {
        self.eventLoopGroup = eventLoopGroup
        self.ready = ready
    }

    func start(socketPath: String) throws {
        try lock.withLock {
            guard serverChannel == nil else { return }
            FileManager.default.tryRemoveItem(atPath: socketPath)
            let bootstrap = ServerBootstrap(group: eventLoopGroup)
                .serverChannelOption(
                    ChannelOptions.socket(.init(SOL_SOCKET), .init(SO_REUSEADDR)),
                    value: 1
                )
                // Hold client bytes until the guest connection is glued so an
                // eager first write cannot be consumed by an empty pipeline.
                .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .childChannelOption(ChannelOptions.autoRead, value: false)
                .childChannelInitializer { [ready] channel in
                    channel.pipeline.addHandler(BuilderRelayHandler(ready: ready))
                }
            let address = try SocketAddress(unixDomainSocketPath: socketPath)
            let channel = try bootstrap.bind(to: address).wait()
            serverChannel = channel
        }
    }

    func stop() {
        let channel: Channel? = lock.withLock {
            defer { serverChannel = nil }
            return serverChannel
        }
        try? channel?.close().wait()
    }
}

extension FileManager {
    fileprivate func tryRemoveItem(atPath path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }
}

private final class BuilderRelayHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let ready: BuilderRelay.ReadyProvider

    init(ready: @escaping BuilderRelay.ReadyProvider) {
        self.ready = ready
    }

    func channelActive(context: ChannelHandlerContext) {
        let loopBoundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        let eventLoop = context.eventLoop
        // Resolve readiness off the event loop, then deliver the outcome onto
        // the channel's event loop explicitly. Completing an NIO promise from
        // a foreign thread and relying on callback delivery semantics has
        // proven fragile: when the engine is already warm, ready() resolves
        // almost immediately and the completion raced ahead of registration,
        // running the continuation on a cooperative-pool thread. Touching
        // NIOLoopBound context there traps (EXC_BREAKPOINT) and killed the
        // whole daemon on any /session or /grpc dial.
        Task {
            let result: Result<RuntimeMachineReady, Error>
            do {
                result = .success(try await ready())
            } catch {
                result = .failure(error)
            }
            eventLoop.execute {
                Self.handleReady(result, loopBoundContext: loopBoundContext, eventLoop: eventLoop)
            }
        }
        context.fireChannelActive()
    }

    private static func handleReady(
        _ result: Result<RuntimeMachineReady, Error>,
        loopBoundContext: NIOLoopBound<ChannelHandlerContext>,
        eventLoop: EventLoop
    ) {
        switch result {
        case .success(let snapshot):
            do {
                let address = try SocketAddress(
                    unixDomainSocketPath: snapshot.builderSocket.path
                )
                ClientBootstrap(group: eventLoop)
                    .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                    // Hold guest bytes too: BuildKit writes its 101 response
                    // immediately, before the glue handlers are installed.
                    .channelOption(ChannelOptions.autoRead, value: false)
                    .connect(to: address)
                    .whenComplete { result in
                        // Connect completions are delivered on the bootstrap
                        // loop, which equals eventLoop; execute keeps that
                        // guarantee explicit instead of assumed.
                        eventLoop.execute {
                            switch result {
                            case .success(let guest):
                                guard loopBoundContext.value.channel.isActive else {
                                    guest.close(promise: nil)
                                    return
                                }
                                glue(client: loopBoundContext.value.channel, guest: guest)
                            case .failure:
                                writeUnavailableResponse(loopBoundContext.value)
                            }
                        }
                    }
            } catch {
                writeUnavailableResponse(loopBoundContext.value)
            }
        case .failure:
            writeUnavailableResponse(loopBoundContext.value)
        }
    }

    private static func glue(client: Channel, guest: Channel) {
        let (clientGlue, guestGlue) = RelayGlueHandler.matchedPair()
        client.pipeline.addHandler(clientGlue).whenComplete { _ in
            guest.pipeline.addHandler(guestGlue).whenComplete { _ in
                client.read()
                guest.read()
            }
        }
    }

    /// The engine is not accepting builder connections yet. Answer with a
    /// Docker-style error so clients see a clean failure instead of a hang.
    private static func writeUnavailableResponse(_ context: ChannelHandlerContext) {
        let body = "{\"message\":\"builder is unavailable; engine not ready\"}"
        var buffer = context.channel.allocator.buffer(capacity: body.utf8.count + 160)
        buffer.writeString(
            "HTTP/1.1 503 Service Unavailable\r\n"
                + "Content-Type: application/json\r\n"
                + "Content-Length: \(body.utf8.count)\r\n"
                + "Connection: close\r\n\r\n"
                + body
        )
        // Close only after the write lands; an immediate close can cancel the
        // pending flush and leave the client with an empty response.
        context.writeAndFlush(NIOAny(buffer)).whenComplete { _ in
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

/// Copies bytes between two channels and tears both down when either side ends.
private final class RelayGlueHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var partner: RelayGlueHandler?
    private let contextLock = NSLock()
    private var contextBox: NIOLoopBoundBox<ChannelHandlerContext?>?

    private init() {}

    static func matchedPair() -> (RelayGlueHandler, RelayGlueHandler) {
        let first = RelayGlueHandler()
        let second = RelayGlueHandler()
        first.partner = second
        second.partner = first
        return (first, second)
    }

    func handlerAdded(context: ChannelHandlerContext) {
        contextLock.withLock {
            contextBox = NIOLoopBoundBox(context, eventLoop: context.eventLoop)
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        contextLock.withLock { contextBox = nil }
        partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        onPartnerLoop { partner in
            let promise = partner.eventLoop.makePromise(of: Void.self)
            // autoRead is disabled on both channels, so every delivered buffer
            // must be followed by an explicit read once the forwarded copy has
            // landed; otherwise the relay stalls after the first segment.
            promise.futureResult.whenComplete { _ in
                self.onOwnLoop { $0.read() }
            }
            partner.writeAndFlush(NIOAny(buffer), promise: promise)
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        onPartnerLoop { $0.flush() }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event {
            // Half-close the partner output so pending writes still drain; the
            // BuildKit session and gRPC conns close their side explicitly.
            onPartnerLoop { $0.close(mode: .output, promise: nil) }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner?.closePartner()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
        partner?.closePartner()
    }

    func read(context: ChannelHandlerContext) {
        context.read()
    }

    private func closePartner() {
        onPartnerLoop { $0.close(promise: nil) }
    }

    private func onOwnLoop(_ body: @escaping @Sendable (ChannelHandlerContext) -> Void) {
        let box = contextLock.withLock { contextBox }
        guard let box else { return }
        box.eventLoop.execute {
            guard let context = box.value else { return }
            body(context)
        }
    }

    private func onPartnerLoop(_ body: @escaping @Sendable (ChannelHandlerContext) -> Void) {
        let box = contextLock.withLock { partner?.contextBox }
        guard let box else { return }
        box.eventLoop.execute {
            guard let context = box.value else { return }
            body(context)
        }
    }
}
