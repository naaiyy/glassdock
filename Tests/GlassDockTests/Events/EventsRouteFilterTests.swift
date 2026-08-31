import Foundation
import NIOCore
import NIOPosix
import Testing
import Vapor
import VaporTesting

@testable import GlassDock

@Suite("Docker events query semantics")
struct EventsRouteFilterTests {
    @Test("event stream flushes immediately before the first event")
    func streamFlushesImmediately() async throws {
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: EventsRoute())

            try await app.testing().test(.GET, "/v1.51/events?until=0") { response async in
                #expect(response.status == .ok)
                #expect(response.body.getString(at: 0, length: response.body.readableBytes) == "\n")
            }
        }
    }

    @Test("event stream writes newline-delimited JSON frames")
    func streamWritesFramedEvents() async throws {
        let broadcaster = EventBroadcaster()
        let event = DockerEvent.simpleEvent(
            id: String(repeating: "a", count: 64), type: "container", status: "start",
            image: "alpine:latest", name: "worker", labels: ["app": "demo"]
        )
        await broadcaster.broadcast(event)

        try await withApp(configure: { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            app.storage[EventBroadcasterKey.self] = broadcaster
            try app.register(collection: EventsRoute())
        }) { app in
            let until = Double(event.timeNano) / 1_000_000_000
            try await app.testing().test(
                .GET, "/v1.51/events?since=0&until=\(until)"
            ) { response async throws in
                #expect(response.status == .ok)
                let lines = String(decoding: response.body.readableBytesView, as: UTF8.self)
                    .split(whereSeparator: { $0 == "\n" })
                #expect(lines.count == 1)
                let frame =
                    try JSONSerialization.jsonObject(
                        with: Data(lines[0].utf8)
                    ) as? [String: Any]
                #expect(frame?["Action"] as? String == "start")
                #expect(frame?["Type"] as? String == "container")
            }
        }
    }

    @Test("quiet event streams remove their subscriber after client disconnect")
    func disconnectUnblocksQuietStream() async throws {
        let socket = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("gd-events-\(UUID().uuidString.prefix(8)).sock")
        defer { try? FileManager.default.removeItem(at: socket) }
        let broadcaster = EventBroadcaster()

        try await withApp(configure: { app in
            app.environment.commandInput.arguments = ["serve"]
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            app.storage[EventBroadcasterKey.self] = broadcaster
            try app.register(collection: EventsRoute())
            app.http.server.configuration.address = .unixDomainSocket(path: socket.path)
            app.http.server.configuration.serverName = nil
        }) { app in
            try await app.startup()
            let channel = try await ClientBootstrap(group: app.eventLoopGroup)
                .connect(to: SocketAddress(unixDomainSocketPath: socket.path))
                .get()
            var request = channel.allocator.buffer(capacity: 128)
            request.writeString(
                "GET /v1.51/events HTTP/1.1\r\nHost: docker\r\nConnection: close\r\n\r\n"
            )
            try await channel.writeAndFlush(request).get()

            let connectedDeadline = Date().addingTimeInterval(2)
            while await broadcaster.subscriberCount() == 0, Date() < connectedDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(await broadcaster.subscriberCount() == 1)

            try await channel.close().get()
            let disconnectedDeadline = Date().addingTimeInterval(3)
            while await broadcaster.subscriberCount() != 0,
                Date() < disconnectedDeadline
            {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(await broadcaster.subscriberCount() == 0)
        }
    }

    @Test("container names and Docker ID prefixes round-trip through event filters")
    func containerIdentityFilter() throws {
        let id = String(repeating: "a", count: 64)
        let event = DockerEvent.simpleEvent(
            id: id,
            type: "container",
            status: "start",
            image: "postgres:17",
            name: "project-db-1",
            labels: ["com.docker.compose.project": "project"]
        )

        #expect(try DockerEventFilter(#"{"container":["project-db-1"]}"#).matches(event))
        #expect(try DockerEventFilter(#"{"container":["aaaaaaaaaaaa"]}"#).matches(event))
        #expect(try DockerEventFilter(#"{"container":["st-opaque-native"]}"#).matches(event) == false)
    }

    @Test("container destroy events retain image, name, and label filters")
    func destroyEventRetainsContainerAttributes() throws {
        let event = DockerEvent.simpleEvent(
            id: String(repeating: "c", count: 64),
            type: "container",
            status: "destroy",
            image: "alpine:3.22.1",
            name: "project-db-1",
            labels: ["com.docker.compose.project": "project"]
        )

        #expect(try DockerEventFilter(#"{"event":["destroy"],"image":["alpine:3.22.1"],"label":["com.docker.compose.project=project"]}"#).matches(event))
        #expect(event.from == "alpine:3.22.1")
        #expect(event.Actor.Attributes["name"] == "project-db-1")
        #expect(event.Actor.Attributes["com.docker.compose.project"] == "project")
    }

    @Test("image filters accept familiar and fully qualified image references")
    func imageFilterReferenceForms() throws {
        let event = DockerEvent.simpleEvent(
            id: String(repeating: "d", count: 64),
            type: "container",
            status: "start",
            image: "docker.io/library/alpine:3.22.1",
            name: "worker"
        )

        #expect(try DockerEventFilter(#"{"image":["alpine:3.22.1"]}"#).matches(event))
        #expect(try DockerEventFilter(#"{"image":["docker.io/library/alpine:3.22.1"]}"#).matches(event))
        #expect(try DockerEventFilter(#"{"image":["alpine"]}"#).matches(event))
    }

    @Test("different event filter keys compose with AND semantics")
    func combinedFilters() throws {
        let event = DockerEvent.simpleEvent(
            id: String(repeating: "b", count: 64),
            type: "container",
            status: "exec_start: sh -c true",
            image: "alpine:3.22",
            name: "worker",
            labels: ["role": "worker", "tier": "background"]
        )

        let matching = try DockerEventFilter(
            #"{"type":["container"],"event":["exec_start"],"image":["alpine:3.22"],"label":["role=worker","tier"]}"#
        )
        #expect(matching.matches(event))
        #expect(try DockerEventFilter(#"{"type":["image"]}"#).matches(event) == false)
        #expect(try DockerEventFilter(#"{"label":["role=api"]}"#).matches(event) == false)
    }

    @Test("event filters accept qualified Docker actions")
    func qualifiedEventFilter() throws {
        let event = DockerEvent.simpleEvent(
            id: "container-id", type: "container", status: "start", image: "alpine", name: "worker"
        )

        #expect(try DockerEventFilter(#"{"event":["container:start"]}"#).matches(event))
        #expect(try DockerEventFilter(#"{"event":["container:stop"]}"#).matches(event) == false)
    }

    @Test("all Docker event resource filter keys are accepted")
    func resourceFilterKeys() throws {
        let keys = ["config", "node", "secret", "service"]
        for key in keys {
            let event = DockerEvent.make(
                type: key, action: "create", actorID: "resource-id",
                attributes: ["name": "resource-name"]
            )
            #expect(
                try DockerEventFilter("{\"\(key)\":[\"resource-name\"]}").matches(event),
                "filter key \(key) should match its event type"
            )
        }
    }

    @Test("legacy boolean-map filter encoding remains accepted")
    func legacyFilterEncoding() throws {
        let event = DockerEvent.simpleEvent(
            id: "volume-id", type: "volume", status: "create", name: "database"
        )
        let filter = try DockerEventFilter(
            #"{"type":{"volume":true,"container":false},"volume":{"database":true}}"#
        )
        #expect(filter.matches(event))
    }

    @Test("unknown and malformed filters are rejected")
    func invalidFilters() {
        #expect(throws: Abort.self) {
            _ = try DockerEventFilter(#"{"unsupported":["value"]}"#)
        }
        #expect(throws: Abort.self) {
            _ = try DockerEventFilter("not-json")
        }
    }

    @Test("timestamps accept Unix, RFC3339, and compound duration forms")
    func timestamps() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        #expect(try EventsRoute.eventTimestamp("123.5", relativeTo: now) == 123_500_000_000)
        #expect(
            try EventsRoute.eventTimestamp("1970-01-01T00:02:03Z", relativeTo: now)
                == 123_000_000_000
        )
        #expect(
            try EventsRoute.eventTimestamp("1h30m", relativeTo: now)
                == 4_600_000_000_000
        )
        #expect(throws: Abort.self) {
            _ = try EventsRoute.eventTimestamp("tomorrow-ish", relativeTo: now)
        }
    }

    @Test("since replays bounded daemon history without a subscription race")
    func sinceHistory() async {
        let broadcaster = EventBroadcaster()
        let first = DockerEvent.simpleEvent(id: "one", type: "container", status: "create")
        let second = DockerEvent.simpleEvent(id: "two", type: "container", status: "start")
        await broadcaster.broadcast(first)
        await broadcaster.broadcast(second)

        let stream = await broadcaster.stream(since: first.timeNano, until: second.timeNano)
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next()?.id == "one")
        #expect(await iterator.next()?.id == "two")
        #expect(await iterator.next() == nil)
    }
}
