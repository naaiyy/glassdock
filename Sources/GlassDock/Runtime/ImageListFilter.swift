import Foundation
import Vapor

/// Parses and applies the Docker image-list filter contract.
///
/// Keeping this logic outside the route makes the matching rules independently
/// testable while allowing the route to focus on request and response handling.
struct ImageListFilter {
    private static let supportedKeys: Set<String> = [
        "before", "dangling", "label", "reference", "since", "until",
    ]

    static func parse(_ raw: String?) throws -> [String: [String]] {
        guard let raw, !raw.isEmpty, let data = raw.data(using: .utf8) else {
            return [:]
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Abort(.badRequest, reason: "invalid filter")
        }

        var filters: [String: [String]] = [:]
        for (key, value) in object {
            guard supportedKeys.contains(key) else {
                throw Abort(.badRequest, reason: "invalid filter '\(key)'")
            }
            if let values = value as? [String: Any] {
                guard values.values.allSatisfy(isJSONBool) else {
                    throw Abort(.badRequest, reason: "invalid filter")
                }
                filters[key] = values.compactMap { key, value in
                    (value as? Bool) == true ? key : nil
                }
            } else if let values = value as? [Any] {
                guard values.allSatisfy({ $0 is String }) else {
                    throw Abort(.badRequest, reason: "invalid filter")
                }
                filters[key] = values.compactMap { $0 as? String }
            } else if let value = value as? String {
                filters[key] = [value]
            } else {
                throw Abort(.badRequest, reason: "invalid filter")
            }
        }
        return filters
    }

    static func validate(_ filters: [String: [String]]) throws {
        if let values = filters["dangling"] {
            _ = try danglingValue(values)
        }
    }

    static func apply(
        _ images: [DockerRuntimeImage], filters: [String: [String]]
    ) throws -> [DockerRuntimeImage] {
        var result = images
        if let values = filters["dangling"] {
            let isTrue = try danglingValue(values)
            result = result.filter { isDangling($0) == isTrue }
        }
        if let patterns = filters["reference"] {
            result = result.filter { image in
                image.references.contains { reference in
                    patterns.contains { referenceMatches(reference, pattern: $0) }
                }
            }
        }
        if let values = filters["label"] {
            result = result.filter { image in
                values.contains { matchesLabel($0, labels: image.labels) }
            }
        }
        if let values = filters["before"] {
            guard let boundary = filterDate(values, images: images) else {
                throw Abort(.badRequest, reason: "invalid filter 'before'")
            }
            result = result.filter { $0.createdAt < boundary }
        }
        if let values = filters["since"] {
            guard let boundary = filterDate(values, images: images) else {
                throw Abort(.badRequest, reason: "invalid filter 'since'")
            }
            result = result.filter { $0.createdAt > boundary }
        }
        if let values = filters["until"] {
            guard let raw = values.first, let boundary = parseDate(raw) else {
                throw Abort(.badRequest, reason: "invalid filter 'until'")
            }
            result = result.filter { $0.createdAt < boundary }
        }
        return result
    }

    static func isDangling(_ image: DockerRuntimeImage) -> Bool {
        image.references.allSatisfy {
            $0 == "<none>:<none>" || $0.hasPrefix("sha256:") || $0.contains("@sha256:")
        }
    }

    static func referenceMatches(_ reference: String, pattern: String) -> Bool {
        familiarReferenceForms(reference).contains {
            globMatch(pattern: pattern, candidate: $0)
        }
    }

    static func globMatch(pattern: String, candidate: String) -> Bool {
        let patternSegments = pattern.split(separator: "/", omittingEmptySubsequences: false)
        let candidateSegments = candidate.split(separator: "/", omittingEmptySubsequences: false)
        guard patternSegments.count == candidateSegments.count else { return false }
        return zip(patternSegments, candidateSegments).allSatisfy {
            wildcardMatch(pattern: Array($0), candidate: Array($1))
        }
    }

    static func isJSONBool(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func danglingValue(_ values: [String]) throws -> Bool {
        guard !values.isEmpty else {
            throw Abort(.badRequest, reason: "invalid filter 'dangling'")
        }
        let isTrue = values.contains { $0 == "1" || $0 == "true" }
        let isFalse = values.contains { $0 == "0" || $0 == "false" }
        guard isTrue != isFalse else {
            throw Abort(.badRequest, reason: "invalid filter 'dangling'")
        }
        return isTrue
    }

    private static func matchesLabel(_ expression: String, labels: [String: String]) -> Bool {
        let parts = expression.split(separator: "=", maxSplits: 1).map(String.init)
        guard let key = parts.first, !key.isEmpty, let value = labels[key] else { return false }
        return parts.count == 1 || value == parts[1]
    }

    private static func filterDate(
        _ values: [String], images: [DockerRuntimeImage]
    ) -> Date? {
        guard let value = values.first, !value.isEmpty else { return nil }
        if let image = images.first(where: {
            $0.digest == value || $0.reference == value || $0.references.contains(value)
        }) {
            return image.createdAt
        }
        return parseDate(value)
    }

    private static func parseDate(_ value: String) -> Date? {
        if let seconds = Double(value) { return Date(timeIntervalSince1970: seconds) }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func familiarReferenceForms(_ reference: String) -> [String] {
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
        return name == familiar ? [familiar] : [familiar, name]
    }

    private static func familiarizeReference(_ reference: String) -> String {
        for prefix in ["docker.io/library/", "docker.io/"] where reference.hasPrefix(prefix) {
            return String(reference.dropFirst(prefix.count))
        }
        return reference
    }

    private static func wildcardMatch(pattern: [Character], candidate: [Character]) -> Bool {
        var patternIndex = 0
        var candidateIndex = 0
        var starIndex = -1
        var starCandidateIndex = 0
        while candidateIndex < candidate.count {
            if patternIndex < pattern.count,
                pattern[patternIndex] == "?" || pattern[patternIndex] == candidate[candidateIndex]
            {
                patternIndex += 1
                candidateIndex += 1
            } else if patternIndex < pattern.count, pattern[patternIndex] == "*" {
                starIndex = patternIndex
                starCandidateIndex = candidateIndex
                patternIndex += 1
            } else if starIndex >= 0 {
                patternIndex = starIndex + 1
                starCandidateIndex += 1
                candidateIndex = starCandidateIndex
            } else {
                return false
            }
        }
        while patternIndex < pattern.count, pattern[patternIndex] == "*" {
            patternIndex += 1
        }
        return patternIndex == pattern.count
    }
}
