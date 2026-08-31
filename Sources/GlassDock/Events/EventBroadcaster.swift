import ContainerResource
import Vapor

struct EventBroadcasterKey: StorageKey {
    typealias Value = EventBroadcaster
}

struct DockerActor: Codable {
    let ID: String
    let Attributes: [String: String]
}

struct DockerEvent: Codable {
    let status: String
    let id: String
    let from: String
    let `Type`: String
    let Action: String
    let Actor: DockerActor
    let scope: String
    let time: Int
    let timeNano: UInt64

    private enum CodingKeys: String, CodingKey {
        case status, id, from, `Type`, Action, Actor, scope, time, timeNano
    }

    /// Moby keeps the three lowercase fields for older container and image
    /// clients only. They are `omitempty` fields in the Engine API, so volume,
    /// network, daemon, and other event types must not acquire empty copies.
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        if Type == "container" || Type == "image" {
            if !status.isEmpty { try values.encode(status, forKey: .status) }
            if !id.isEmpty { try values.encode(id, forKey: .id) }
            if Type == "container", !from.isEmpty {
                try values.encode(from, forKey: .from)
            }
        }
        try values.encode(Type, forKey: .Type)
        try values.encode(Action, forKey: .Action)
        try values.encode(Actor, forKey: .Actor)
        try values.encode(scope, forKey: .scope)
        try values.encode(time, forKey: .time)
        try values.encode(timeNano, forKey: .timeNano)
    }
}

extension DockerEvent {
    static func daemonReload(name: String = ProcessInfo.processInfo.hostName) -> DockerEvent {
        make(type: "daemon", action: "reload", actorID: name, attributes: ["name": name])
    }

    /// General constructor mirroring moby's `EventsService.Log(action, type, Actor{ID, Attributes})`.
    /// The deprecated top-level fields are derived exactly as moby does for backward compatibility:
    /// `id` = Actor.ID, `status` = action, and a container's `from` is
    /// `Attributes["image"]`. The encoder applies Moby's omitempty behavior
    /// for the deprecated fields.
    /// Use this for image/network/volume/prune events, whose attribute sets differ from containers
    /// (e.g. no forced `image`/`name` keys).
    static func make(
        type: String,
        action: String,
        actorID: String,
        attributes: [String: String]
    ) -> DockerEvent {
        let now = Date()
        let timeSeconds = Int(now.timeIntervalSince1970)
        let timeNano = UInt64(now.timeIntervalSince1970 * 1_000_000_000)

        return DockerEvent(
            status: action,
            id: actorID,
            from: attributes["image"] ?? "",
            Type: type,
            Action: action,
            Actor: DockerActor(ID: actorID, Attributes: attributes),
            scope: "local",
            time: timeSeconds,
            timeNano: timeNano
        )
    }

    /// Container-shaped event: moby's `LogContainerEventWithAttributes` always injects
    /// `image` and `name` attributes alongside the container labels. Keep using this for
    /// `Type: "container"` events only. `extraAttributes` carries action-specific keys moby
    /// adds on top (e.g. `signal` on `kill`, `exitCode` on `die`/`exec_die`); they override
    /// any same-named label.
    static func simpleEvent(
        id: String,
        type: String,
        status: String,
        image: String = "",
        name: String = "",
        labels: [String: String] = [:],
        extraAttributes: [String: String] = [:]
    ) -> DockerEvent {
        var attributes = labels
        attributes["image"] = image
        attributes["name"] = name.isEmpty ? id : name
        if type == "container" {
            attributes["container"] = String(id.prefix(12))
        }
        for (key, value) in extraAttributes { attributes[key] = value }
        return make(type: type, action: status, actorID: id, attributes: attributes)
    }

    /// Container-shaped event derived from a snapshot: canonical 64-char Docker id,
    /// image reference, Docker-visible name, and restored labels — the fields every
    /// container lifecycle event site otherwise re-derives by hand.
    static func containerEvent(
        _ action: String,
        container: ContainerSnapshot,
        extraAttributes: [String: String] = [:]
    ) async -> DockerEvent {
        let name = await DockerContainerMetadataStore.shared.name(nativeID: container.id)
        return simpleEvent(
            id: DockerContainerID.hexId(for: container),
            type: "container",
            status: action,
            image: ContainerImageIdentity.requestedReference(for: container),
            name: name,
            labels: ContainerImageIdentity.dockerLabels(for: container),
            extraAttributes: extraAttributes
        )
    }

    static func containerEvent(
        _ action: String,
        id: String,
        image: String,
        name: String,
        labels: [String: String],
        extraAttributes: [String: String] = [:]
    ) -> DockerEvent {
        simpleEvent(
            id: id,
            type: "container",
            status: action,
            image: image,
            name: name,
            labels: labels,
            extraAttributes: extraAttributes
        )
    }
}

actor EventBroadcaster {
    /// Docker's `since` query replays daemon events emitted before the request.
    /// Keep a bounded in-memory journal: it has daemon-lifetime semantics (like
    /// the broadcaster itself) without allowing event traffic to grow memory
    /// without limit.
    private static let historyLimit = 4_096
    private var continuations: [UUID: AsyncStream<DockerEvent>.Continuation] = [:]
    private var history: [DockerEvent] = []

    func stream(since: UInt64? = nil, until: UInt64? = nil) -> AsyncStream<DockerEvent> {
        let id = UUID()

        // Register the continuation synchronously, before returning the stream. The
        // previous implementation deferred registration to `Task { addContinuation }`,
        // leaving a window where the stream existed but was not yet in `continuations`
        // — any event broadcast in that window was silently dropped for this listener
        // (e.g. a container's start event firing right after `docker events` connects).
        // `makeStream` lets us register inside the actor-isolated method with no race.
        let (stream, continuation) = AsyncStream.makeStream(of: DockerEvent.self)
        if let since {
            for event in history
            where event.timeNano >= since && until.map({ event.timeNano <= $0 }) != false {
                continuation.yield(event)
            }
        }
        if let until, until <= Self.nowNanoseconds() {
            continuation.finish()
            return stream
        }
        continuations[id] = continuation
        let deadlineTask: Task<Void, Never>?
        if let until {
            let remaining = max(
                0,
                Double(until) / 1_000_000_000 - Date().timeIntervalSince1970
            )
            deadlineTask = Task {
                if remaining > 0 {
                    try? await Task.sleep(
                        nanoseconds: UInt64(remaining * 1_000_000_000)
                    )
                }
                guard !Task.isCancelled else { return }
                continuation.finish()
            }
        } else {
            deadlineTask = nil
        }
        continuation.onTermination = { @Sendable _ in
            deadlineTask?.cancel()
            Task { await self.removeContinuation(id: id) }
        }
        return stream
    }

    func broadcast(_ event: DockerEvent) {
        history.append(event)
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    func subscriberCount() -> Int {
        continuations.count
    }

    private static func nowNanoseconds() -> UInt64 {
        UInt64(max(0, Date().timeIntervalSince1970) * 1_000_000_000)
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
