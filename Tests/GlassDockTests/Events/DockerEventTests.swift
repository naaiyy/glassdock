import Foundation
import Testing

@testable import GlassDock

@Suite("DockerEvent — label forwarding in Actor.Attributes")
struct DockerEventTests {

    @Test("simpleEvent includes user labels in Attributes")
    func simpleEventIncludesLabels() {
        let event = DockerEvent.simpleEvent(
            id: "ctr-1",
            type: "container",
            status: "start",
            image: "alpine:latest",
            name: "my-container",
            labels: ["app": "myapp", "version": "2.0"]
        )

        #expect(event.Actor.Attributes["app"] == "myapp")
        #expect(event.Actor.Attributes["version"] == "2.0")
    }

    @Test("simpleEvent merges image and name into Attributes")
    func simpleEventMergesImageAndName() {
        let event = DockerEvent.simpleEvent(
            id: "ctr-1",
            type: "container",
            status: "start",
            image: "alpine:latest",
            name: "my-container",
            labels: [:]
        )

        #expect(event.Actor.Attributes["image"] == "alpine:latest")
        #expect(event.Actor.Attributes["name"] == "my-container")
        #expect(event.from == "alpine:latest")
    }

    @Test("simpleEvent falls back to id for name when name is empty")
    func simpleEventFallsBackToId() {
        let event = DockerEvent.simpleEvent(
            id: "ctr-abc",
            type: "container",
            status: "start"
        )

        #expect(event.Actor.Attributes["name"] == "ctr-abc")
        #expect(event.Actor.Attributes["image"] == "")
        #expect(event.Actor.Attributes["container"] == "ctr-abc")
    }

    @Test("simpleEvent with no labels produces only image and name in Attributes")
    func simpleEventNoLabelsHasOnlyStandardKeys() {
        let event = DockerEvent.simpleEvent(
            id: "ctr-1",
            type: "container",
            status: "stop",
            image: "postgres:17",
            name: "db"
        )

        #expect(event.Actor.Attributes.keys.sorted() == ["container", "image", "name"])
    }

    @Test("simpleEvent Attributes contain labels plus image and name")
    func simpleEventAttributeKeySet() {
        let event = DockerEvent.simpleEvent(
            id: "ctr-1",
            type: "container",
            status: "start",
            image: "alpine",
            name: "test",
            labels: ["app": "x", "env": "prod"]
        )

        #expect(event.Actor.Attributes.keys.sorted() == ["app", "container", "env", "image", "name"])
    }

    @Test("Attributes encodes as flat JSON dictionary")
    func attributesEncodesAsFlat() throws {
        let event = DockerEvent.simpleEvent(
            id: "ctr-1",
            type: "container",
            status: "start",
            image: "alpine",
            name: "test",
            labels: ["app": "myapp"]
        )

        let json = try JSONEncoder().encode(event)
        let obj = try JSONDecoder().decode([String: AnyDecodable].self, from: json)
        let actor = obj["Actor"]?.value as? [String: Any]
        let attributes = actor?["Attributes"] as? [String: String]

        #expect(attributes?["app"] == "myapp")
        #expect(attributes?["image"] == "alpine")
        #expect(attributes?["name"] == "test")
    }

    @Test("every event encodes the Docker stream envelope")
    func envelopeShape() throws {
        let event = DockerEvent.make(
            type: "network", action: "connect", actorID: "network-id",
            attributes: ["name": "bridge", "type": "bridge"]
        )
        let json =
            try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(event)
            ) as? [String: Any]

        #expect(json?["Type"] as? String == "network")
        #expect(json?["Action"] as? String == "connect")
        #expect(json?["scope"] as? String == "local")
        #expect(json?["time"] is Int)
        #expect(json?["timeNano"] is Int)
        #expect(json?["Actor"] != nil)
    }

    @Test("deprecated lowercase fields are omitted for non-container events")
    func deprecatedFieldsAreTypeSpecific() throws {
        let event = DockerEvent.make(
            type: "volume", action: "mount", actorID: "data",
            attributes: ["driver": "local"]
        )
        let json =
            try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(event)
            ) as? [String: Any]

        #expect(json?["status"] == nil)
        #expect(json?["id"] == nil)
        #expect(json?["from"] == nil)
    }

    @Test("container events include the id, image, name, and user labels")
    func containerAttributesIncludeStandardFields() {
        let id = String(repeating: "a", count: 64)
        let event = DockerEvent.simpleEvent(
            id: id, type: "container", status: "start", image: "alpine:latest",
            name: "worker", labels: ["app": "demo"]
        )

        #expect(event.Actor.Attributes["container"] == String(id.prefix(12)))
        #expect(event.Actor.Attributes["image"] == "alpine:latest")
        #expect(event.Actor.Attributes["name"] == "worker")
        #expect(event.Actor.Attributes["app"] == "demo")
    }

    @Test("lifecycle events use the Docker action taxonomy")
    func lifecycleActionTaxonomy() {
        let actions: [(String, String)] = [
            ("container", "create"),
            ("container", "start"),
            ("container", "die"),
            ("container", "stop"),
            ("container", "destroy"),
            ("container", "rename"),
            ("container", "restart"),
            ("container", "attach"),
            ("container", "detach"),
            ("container", "exec_create: /bin/sh"),
            ("container", "exec_start: /bin/sh"),
            ("container", "exec_die"),
            ("container", "exec_detach"),
            ("image", "pull"),
            ("image", "tag"),
            ("image", "untag"),
            ("image", "delete"),
            ("image", "load"),
            ("image", "save"),
            ("volume", "create"),
            ("volume", "mount"),
            ("volume", "unmount"),
            ("volume", "destroy"),
            ("network", "create"),
            ("network", "connect"),
            ("network", "disconnect"),
            ("network", "destroy"),
            ("daemon", "reload"),
        ]

        for (type, action) in actions {
            let event = DockerEvent.make(
                type: type, action: action, actorID: "resource-id", attributes: [:]
            )
            #expect(event.Type == type)
            #expect(event.Action == action)
        }
    }
}

// Minimal helper for decoding arbitrary JSON values in tests.
private struct AnyDecodable: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let dict = try? container.decode([String: AnyDecodable].self) {
            value = dict.mapValues { $0.value }
        } else if let array = try? container.decode([AnyDecodable].self) {
            value = array.map { $0.value }
        } else {
            value = ()
        }
    }
}
