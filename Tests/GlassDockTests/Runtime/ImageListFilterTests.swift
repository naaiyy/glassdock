import Foundation
import Testing
import Vapor

@testable import GlassDock

@Suite("Docker image-list filters")
struct ImageListFilterTests {
    @Test("reference filters use familiar Docker names")
    func referenceFamiliarNames() {
        #expect(
            ImageListFilter.referenceMatches(
                "docker.io/library/alpine:3.20", pattern: "alpine"
            )
        )
        #expect(
            ImageListFilter.referenceMatches(
                "docker.io/library/alpine:3.20", pattern: "alpine:3.*"
            )
        )
        #expect(
            !ImageListFilter.referenceMatches(
                "docker.io/myuser/app:1", pattern: "*"
            )
        )
        #expect(
            ImageListFilter.referenceMatches(
                "docker.io/myuser/app:1", pattern: "myuser/*"
            )
        )
    }

    @Test("reference filters support single-character globs")
    func referenceQuestionMarkGlob() {
        #expect(ImageListFilter.referenceMatches("alpine:3.18", pattern: "alpine:3.1?"))
        #expect(!ImageListFilter.referenceMatches("alpine:3.18", pattern: "alpine:3.1"))
        #expect(!ImageListFilter.referenceMatches("alpine:3.18", pattern: "alpine:3.1??"))
    }

    @Test("filter parsing accepts Docker's string, array, and boolean-map forms")
    func parsesFilterShapes() throws {
        for raw in [
            #"{"reference":"alpine:*"}"#,
            #"{"reference":["alpine:*"]}"#,
            #"{"reference":{"alpine:*":true,"old":false}}"#,
        ] {
            #expect(
                try ImageListFilter.parse(raw) == ["reference": ["alpine:*"]]
            )
        }
    }

    @Test("filter parsing rejects unknown keys and invalid values")
    func rejectsInvalidFilters() {
        let unknown = #expect(throws: Abort.self) {
            _ = try ImageListFilter.parse(#"{"unsupported":["value"]}"#)
        }
        #expect(unknown?.status == .badRequest)

        let invalidValue = #expect(throws: Abort.self) {
            _ = try ImageListFilter.parse(#"{"reference":1}"#)
        }
        #expect(invalidValue?.status == .badRequest)
    }

    @Test("dangling and reference filters compose with AND semantics")
    func appliesFilters() throws {
        let tagged = Self.image(
            reference: "docker.io/library/alpine:latest",
            timestamp: 2,
            labels: ["role": "base"]
        )
        let untagged = Self.image(reference: "sha256:untagged", timestamp: 1)

        #expect(ImageListFilter.isDangling(tagged) == false)
        #expect(ImageListFilter.isDangling(untagged))

        let dangling = try ImageListFilter.apply(
            [tagged, untagged], filters: ["dangling": ["true"]]
        )
        #expect(dangling == [untagged])

        let matching = try ImageListFilter.apply(
            [tagged, untagged], filters: ["reference": ["alpine"]]
        )
        #expect(matching == [tagged])

        let combined = try ImageListFilter.apply(
            [tagged, untagged],
            filters: ["dangling": ["false"], "label": ["role=base"]]
        )
        #expect(combined == [tagged])
    }

    @Test("date filters resolve image references before filtering")
    func appliesDateFilters() throws {
        let older = Self.image(reference: "sha256:older", timestamp: 1)
        let newer = Self.image(reference: "sha256:newer", timestamp: 2)

        let before = try ImageListFilter.apply(
            [older, newer], filters: ["before": ["sha256:newer"]]
        )
        #expect(before == [older])

        let since = try ImageListFilter.apply(
            [older, newer], filters: ["since": ["sha256:older"]]
        )
        #expect(since == [newer])
    }

    private static func image(
        reference: String, timestamp: TimeInterval, labels: [String: String] = [:]
    ) -> DockerRuntimeImage {
        DockerRuntimeImage(
            reference: reference,
            digest: reference.hasPrefix("sha256:") ? reference : "sha256:\(reference)",
            references: [reference],
            createdAt: Date(timeIntervalSince1970: timestamp),
            labels: labels
        )
    }
}
