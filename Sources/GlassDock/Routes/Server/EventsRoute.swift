import ContainerAPIClient
import NIOCore
import Vapor

private struct EventsQuery: Content {
    let since: String?
    let until: String?
    let filters: String?
}

struct DockerEventFilter: Sendable {
    private static let allowedKeys: Set<String> = [
        "config", "container", "daemon", "event", "image", "label", "network", "node",
        "plugin", "scope", "secret", "service", "type", "volume",
    ]

    let values: [String: [String]]

    init(_ raw: String?) throws {
        guard let raw, !raw.isEmpty else {
            values = [:]
            return
        }
        guard let data = raw.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw Abort(.badRequest, reason: "invalid event filters")
        }
        let unknown = Set(object.keys).subtracting(Self.allowedKeys)
        guard unknown.isEmpty else {
            throw Abort(.badRequest, reason: "invalid event filter: \(unknown.sorted().joined(separator: ", "))")
        }

        var parsed: [String: [String]] = [:]
        for (key, value) in object {
            if let array = value as? [String] {
                parsed[key] = array
            } else if let string = value as? String {
                parsed[key] = [string]
            } else if let map = value as? [String: Any] {
                parsed[key] = map.compactMap { name, enabled in
                    enabled as? Bool == true ? name : nil
                }
            } else {
                throw Abort(.badRequest, reason: "invalid event filter values for \(key)")
            }
        }
        values = parsed
    }

    func matches(_ event: DockerEvent) -> Bool {
        values.allSatisfy { key, expected in
            guard !expected.isEmpty else { return true }
            switch key {
            case "type":
                return expected.contains(event.Type)
            case "event":
                let action =
                    event.Action.split(separator: ":", maxSplits: 1).first.map(String.init)
                    ?? event.Action
                let qualified = "\(event.Type):\(event.Action)"
                let qualifiedPrefix = "\(event.Type):\(action)"
                return expected.contains {
                    $0 == event.Action || $0 == action || $0 == qualified
                        || $0 == qualifiedPrefix
                }
            case "scope":
                return expected.contains(event.scope)
            case "label":
                return expected.allSatisfy { Self.matchesLabel($0, attributes: event.Actor.Attributes) }
            case "container":
                return event.Type == "container" && Self.matchesResource(event, expected: expected)
            case "image":
                let image = event.Actor.Attributes["image"] ?? event.from
                return expected.contains { Self.matchesImage($0, actual: image) }
                    || (event.Type == "image" && Self.matchesResource(event, expected: expected))
            case "config", "network", "node", "plugin", "secret", "service", "volume", "daemon":
                return event.Type == key && Self.matchesResource(event, expected: expected)
            default:
                return false
            }
        }
    }

    private static func matchesResource(_ event: DockerEvent, expected: [String]) -> Bool {
        let names = [
            event.Actor.Attributes["name"],
            event.Actor.Attributes["container"],
        ].compactMap { $0 }
        return expected.contains { value in
            event.Actor.ID == value || event.Actor.ID.hasPrefix(value)
                || names.contains(value)
                || names.contains(DockerContainerMetadataStore.normalized(value))
        }
    }

    private static func matchesImage(_ expected: String, actual: String) -> Bool {
        !Set(referenceForms(expected)).isDisjoint(with: referenceForms(actual))
    }

    /// Docker clients use both familiar references such as `alpine:latest` and
    /// fully qualified references such as `docker.io/library/alpine:latest` in
    /// event filters. Moby accepts those equivalent forms for one image.
    private static func referenceForms(_ reference: String) -> [String] {
        let familiar = familiarizeReference(reference)
        var name = familiar
        if let at = name.firstIndex(of: "@") {
            name = String(name[..<at])
        }
        if let colon = name.lastIndex(of: ":"),
            !name[name.index(after: colon)...].contains("/")
        {
            name = String(name[..<colon])
        }
        return name == familiar ? [reference, familiar, name] : [reference, familiar, name]
    }

    private static func familiarizeReference(_ reference: String) -> String {
        for prefix in ["docker.io/library/", "docker.io/"] where reference.hasPrefix(prefix) {
            return String(reference.dropFirst(prefix.count))
        }
        return reference
    }

    private static func matchesLabel(_ expression: String, attributes: [String: String]) -> Bool {
        guard let separator = expression.firstIndex(of: "=") else {
            return attributes[expression] != nil
        }
        let key = String(expression[..<separator])
        let value = String(expression[expression.index(after: separator)...])
        return attributes[key] == value
    }
}

struct EventsRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/events", use: EventsRoute.handler)
    }

}

extension EventsRoute {
    static func handler(_ req: Request) async throws -> Response {
        guard let broadcaster = req.application.storage[EventBroadcasterKey.self] else {
            throw Abort(.internalServerError, reason: "EventBroadcaster not configured")
        }
        let query = try req.query.decode(EventsQuery.self)
        let now = Date()
        let since = try Self.eventTimestamp(query.since, relativeTo: now)
        let until = try Self.eventTimestamp(query.until, relativeTo: now)
        let filter = try DockerEventFilter(query.filters)
        let stream = await broadcaster.stream(since: since, until: until)

        let response = Response(status: .ok)
        response.headers.add(name: .contentType, value: "application/json")

        response.body = .init(managedAsyncStream: { writer in
            do {
                try await DisconnectCoupledResponseStream.run(writer: writer) { writer in
                    // Flush the response head immediately. Docker CLI opens
                    // /events before starting no-argument commands such as
                    // `docker stats`; without an initial body write, Vapor
                    // waits for the first real event and the CLI never
                    // proceeds to the command's API calls. JSON decoders
                    // accept this newline as leading whitespace.
                    try await writer.write(.buffer(ByteBuffer(string: "\n")))

                    for await event in stream {
                        try Task.checkCancellation()
                        if let until, event.timeNano > until { break }
                        guard filter.matches(event) else { continue }
                        let json = try JSONEncoder().encode(event)
                        var buffer = req.application.allocator.buffer(capacity: json.count + 1)
                        buffer.writeBytes(json)
                        buffer.writeString("\n")
                        // DisconnectCoupledResponseStream serializes this
                        // write with its heartbeat and cancels this operation
                        // when the client closes a quiet connection.
                        try await writer.write(.buffer(buffer))
                    }
                }
            } catch is CancellationError {
                // The response channel canceled the producer.
            } catch is DisconnectCoupledResponseStream.ProducerError {
                req.logger.debug("Client disconnected from event stream")
            } catch {
                req.logger.warning("Event stream terminated: \(error)")
            }
        })

        return response
    }

    static func eventTimestamp(_ raw: String?, relativeTo now: Date) throws -> UInt64? {
        guard let raw, !raw.isEmpty else { return nil }
        if let seconds = Double(raw), seconds >= 0 {
            return UInt64(seconds * 1_000_000_000)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) {
            return UInt64(max(0, date.timeIntervalSince1970) * 1_000_000_000)
        }
        if let duration = durationSeconds(raw) {
            return UInt64(max(0, now.timeIntervalSince1970 - duration) * 1_000_000_000)
        }
        throw Abort(.badRequest, reason: "invalid event time or duration: \(raw)")
    }

    private static func durationSeconds(_ raw: String) -> Double? {
        let pattern = #"([0-9]+(?:\.[0-9]+)?)(ns|us|µs|ms|s|m|h)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        let matches = regex.matches(in: raw, range: range)
        guard !matches.isEmpty,
            matches.reduce(0, { $0 + $1.range.length }) == range.length
        else { return nil }
        let factors: [String: Double] = [
            "ns": 1e-9, "us": 1e-6, "µs": 1e-6, "ms": 1e-3,
            "s": 1, "m": 60, "h": 3_600,
        ]
        return matches.reduce(0) { total, match in
            guard let numberRange = Range(match.range(at: 1), in: raw),
                let unitRange = Range(match.range(at: 2), in: raw),
                let number = Double(raw[numberRange]),
                let factor = factors[String(raw[unitRange])]
            else { return total }
            return total + number * factor
        }
    }
}
