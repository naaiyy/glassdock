import Darwin
import Foundation
import NIOCore
import NIOPosix

enum DockerSocketRelayConfiguration {
    static let hostBindPath = "/var/run/docker.sock"
    static let guestSocketPath = "/run/glassdock/docker.sock"

    static func isDockerSocketSource(_ source: String) -> Bool {
        source == hostBindPath || source == "/run/docker.sock"
    }

    static func mount(
        source: String,
        target: String,
        readOnly: Bool,
        enabled: Bool
    ) throws -> DockerRuntimeMount? {
        guard isDockerSocketSource(source) else { return nil }
        guard enabled else {
            throw DockerRuntimeRouteError.invalidRequest(
                "Docker socket bind relay is disabled; remove the Docker socket bind or start Glass Dock with --docker-socket-relay"
            )
        }
        return DockerRuntimeMount(
            source: guestSocketPath,
            target: target,
            readOnly: readOnly,
            type: "bind",
            relay: true,
            sourceForInspect: hostBindPath
        )
    }
}

/// Relays guest Unix socket connections to the daemon's public Docker socket.
/// Guest connection notifications and relay bytes share the persistent control
/// GuestConnection, so this service does not create a second VMM or vsock path.
final class DockerSocketRelayService: @unchecked Sendable {
    private let hostSocketPath: String
    private let eventLoopGroup: any EventLoopGroup
    private let lock = NSLock()
    private var eventTask: Task<Void, Never>?
    private var relayTasks: [UUID: Task<Void, Never>] = [:]

    init(hostSocketPath: String, eventLoopGroup: any EventLoopGroup) {
        self.hostSocketPath = hostSocketPath
        self.eventLoopGroup = eventLoopGroup
    }

    deinit {
        stop()
    }

    func start(connection: GuestConnection) async {
        let events = await connection.events()
        let task = Task { [weak self, connection] in
            for await frame in events {
                guard !Task.isCancelled else { return }
                self?.handle(frame, connection: connection)
            }
        }
        let oldTask = lock.withLock {
            let oldTask = eventTask
            eventTask = task
            let oldRelays = relayTasks.values
            relayTasks.removeAll()
            oldRelays.forEach { $0.cancel() }
            return oldTask
        }
        oldTask?.cancel()
    }

    func stop() {
        let tasks: [Task<Void, Never>] = lock.withLock {
            eventTask?.cancel()
            eventTask = nil
            let tasks = Array(relayTasks.values)
            relayTasks.removeAll()
            return tasks
        }
        tasks.forEach { $0.cancel() }
    }

    private func handle(_ frame: GuestFrame, connection: GuestConnection) {
        guard frame.kind == .event, frame.method == "socket.open",
            case .object(let fields)? = frame.payload,
            case .string(let id)? = fields["id"], !id.isEmpty
        else { return }

        let token = UUID()
        let task = Task { [weak self, connection] in
            await self?.relay(id: id, connection: connection)
            self?.removeRelay(token: token)
        }
        lock.withLock { relayTasks[token] = task }
    }

    private func removeRelay(token: UUID) {
        _ = lock.withLock { relayTasks.removeValue(forKey: token) }
    }

    private func relay(id: String, connection: GuestConnection) async {
        let handler = DockerSocketRelayChannelHandler(
            connection: connection
        )
        var channel: Channel?
        var requestStarted = false
        do {
            let address = try SocketAddress(unixDomainSocketPath: hostSocketPath)
            channel = try await ClientBootstrap(group: eventLoopGroup)
                .connectTimeout(.seconds(2))
                .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .channelOption(ChannelOptions.autoRead, value: false)
                .channelInitializer { channel in
                    channel.pipeline.addHandler(handler)
                }
                .connect(to: address)
                .get()
            guard let channel else { throw DockerSocketRelayError.connectionUnavailable }
            try Task.checkCancellation()
            let request = Task {
                do {
                    _ = try await connection.request(
                        method: "socket.relay",
                        payload: .object(["id": .string(id)]),
                        onStream: handler.receive,
                        onRequestID: handler.requestIDReady
                    )
                    handler.requestFinished()
                } catch {
                    handler.requestFailed()
                }
            }
            requestStarted = true
            handler.setRequestTask(request)
            await withTaskCancellationHandler(
                operation: {
                    await request.value
                },
                onCancel: {
                    request.cancel()
                    handler.requestFailed()
                })
            try? await channel.close().get()
        } catch {
            handler.requestFailed()
            if let channel {
                try? await channel.close().get()
            }
            if !requestStarted {
                await closeGuestSession(id: id, connection: connection)
            }
        }
    }

    private func closeGuestSession(id: String, connection: GuestConnection) async {
        _ = try? await connection.request(
            method: "socket.close", payload: .object(["id": .string(id)])
        )
    }
}

private enum DockerSocketRelayError: Error {
    case connectionUnavailable
}

private final class DockerSocketRelayChannelHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let connection: GuestConnection
    private let contextLock = NSLock()
    private let sendQueue: DockerSocketRelaySendQueue
    private var contextBox: NIOLoopBoundBox<ChannelHandlerContext?>?
    private var requestID: UInt64?
    private var requestTask: Task<Void, Never>?
    private var inputClosed = false
    private var outputClosed = false
    private var inactive = false

    init(connection: GuestConnection) {
        self.connection = connection
        self.sendQueue = DockerSocketRelaySendQueue(connection: connection)
    }

    func handlerAdded(context: ChannelHandlerContext) {
        contextLock.withLock {
            contextBox = NIOLoopBoundBox(context, eventLoop: context.eventLoop)
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        contextLock.withLock {
            contextBox = nil
            inactive = true
        }
        sendQueue.cancel()
    }

    func setRequestTask(_ task: Task<Void, Never>) {
        let cancel = contextLock.withLock {
            requestTask = task
            return inactive
        }
        if cancel { task.cancel() }
    }

    func requestIDReady(_ id: UInt64) {
        onEventLoop { context in
            guard !self.inactive else { return }
            self.requestID = id
            context.read()
            if self.inputClosed {
                self.enqueueInput(Data(), context: context)
            }
        }
    }

    func receive(_ frame: GuestFrame) {
        guard frame.stream == .stdout, let data = frame.data else { return }
        onEventLoop { context in
            guard context.channel.isActive, !self.outputClosed else { return }
            if data.isEmpty {
                self.outputClosed = true
                self.closeOutputWhenDrained(context: context, deadline: .now() + .seconds(5))
                return
            }
            var buffer = context.channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            let loopBoundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
            context.writeAndFlush(self.wrapOutboundOut(buffer)).whenFailure { _ in
                loopBoundContext.value.close(promise: nil)
            }
        }
    }

    func requestFinished() {
        onEventLoop { $0.close(promise: nil) }
    }

    func requestFailed() {
        onEventLoop { $0.close(promise: nil) }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard let requestID else {
            context.close(promise: nil)
            return
        }
        let buffer = unwrapInboundIn(data)
        let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) ?? []
        enqueueInput(Data(bytes), context: context, requestID: requestID)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard let event = event as? ChannelEvent, case .inputClosed = event else { return }
        guard !inputClosed else { return }
        inputClosed = true
        guard let requestID else { return }
        enqueueInput(Data(), context: context, requestID: requestID)
    }

    func channelInactive(context: ChannelHandlerContext) {
        contextLock.withLock {
            inactive = true
            contextBox = nil
        }
        sendQueue.cancel()
        requestTask?.cancel()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    func read(context: ChannelHandlerContext) {
        context.read()
    }

    private func enqueueInput(
        _ data: Data,
        context: ChannelHandlerContext,
        requestID: UInt64? = nil
    ) {
        guard let requestID = requestID ?? self.requestID else { return }
        sendQueue.enqueue(
            data,
            requestID: requestID,
            onSuccess: { [weak self] in
                self?.onEventLoop { context in
                    guard context.channel.isActive else { return }
                    if !data.isEmpty { context.read() }
                }
            },
            onFailure: { [weak self] in self?.requestFailed() }
        )
    }

    private func closeOutputWhenDrained(context: ChannelHandlerContext, deadline: NIODeadline) {
        let loopBoundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        context.channel.getOption(
            ChannelOptions.socket(.init(SOL_SOCKET), .init(SO_NWRITE))
        ).whenComplete { result in
            switch result {
            case .success(0):
                loopBoundContext.value.close(mode: .output, promise: nil)
            case .success where .now() < deadline:
                loopBoundContext.value.eventLoop.scheduleTask(in: .milliseconds(1)) {
                    self.closeOutputWhenDrained(
                        context: loopBoundContext.value, deadline: deadline
                    )
                }
            case .success, .failure:
                loopBoundContext.value.close(mode: .output, promise: nil)
            }
        }
    }

    private func onEventLoop(_ body: @escaping @Sendable (ChannelHandlerContext) -> Void) {
        let box = contextLock.withLock { contextBox }
        guard let box else { return }
        box.eventLoop.execute {
            guard let context = box.value else { return }
            body(context)
        }
    }
}

private final class DockerSocketRelaySendQueue: @unchecked Sendable {
    private let connection: GuestConnection
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    init(connection: GuestConnection) {
        self.connection = connection
    }

    func enqueue(
        _ data: Data,
        requestID: UInt64,
        onSuccess: @escaping @Sendable () -> Void,
        onFailure: @escaping @Sendable () -> Void
    ) {
        let task: Task<Void, Never> = lock.withLock {
            let previous = tail
            let task = Task { [connection] in
                _ = await previous?.value
                do {
                    try await connection.sendStream(id: requestID, stream: .stdin, data: data)
                    onSuccess()
                } catch {
                    onFailure()
                }
            }
            tail = task
            return task
        }
        _ = task
    }

    func cancel() {
        lock.withLock {
            tail?.cancel()
            tail = nil
        }
    }
}
