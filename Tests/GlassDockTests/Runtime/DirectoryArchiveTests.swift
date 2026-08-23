import Foundation
import Testing

@testable import GlassDock

@Suite("Directory archive builder")
struct DirectoryArchiveTests {
    /// Parses a ustar header so tests can assert real on-wire layout.
    private static func ustarFields(in data: Data, offset: Int) -> [String] {
        let header = data.subdata(in: offset..<offset + 512)
        func string(_ range: Range<Int>) -> String {
            let bytes = header[range].prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return [
            string(0..<100),      // name
            string(100..<108),    // mode
            String(UnicodeScalar(header[156])),  // typeflag
            string(257..<263),    // magic
        ]
    }

    private static func checksumValid(header: Data) -> Bool {
        guard header.count == 512 else { return false }
        var sum = 0
        for (index, byte) in header.enumerated() {
            sum += (148..<156).contains(index) ? 32 : Int(byte)
        }
        let stored = String(decoding: header[148..<155], as: UTF8.self)
        return Int(stored.trimmingCharacters(in: .whitespaces), radix: 8) == sum
    }

    @Test("builds valid ustar directory entries with intermediate components")
    func buildsIntermediateEntries() throws {
        let data = DirectoryArchive.tar(directories: ["/var/cache/nginx"])
        // Two headers + end-of-archive blocks.
        #expect(data.count % 512 == 0)

        let first = Self.ustarFields(in: data, offset: 0)
        #expect(first == ["/var", "0000755", "5", "ustar"])

        let second = Self.ustarFields(in: data, offset: 512)
        #expect(second == ["/var/cache", "0000755", "5", "ustar"])

        let third = Self.ustarFields(in: data, offset: 1024)
        #expect(third == ["/var/cache/nginx", "0000755", "5", "ustar"])

        for offset in stride(from: 0, to: 1536, by: 512) {
            #expect(
                Self.checksumValid(header: data.subdata(in: offset..<offset + 512)),
                "checksum invalid at offset \(offset)"
            )
        }

        // End-of-archive: two zero blocks, then padding to the 512 boundary.
        let trailer = data.subdata(in: 1536..<data.count)
        #expect(trailer.allSatisfy { $0 == 0 })
    }

    @Test("deduplicates shared prefixes and sorts entries")
    func deduplicatesAndSorts() {
        let data = DirectoryArchive.tar(directories: [
            "/var/lib/postgresql/data", "/var/cache/nginx", "/var/cache",
        ])
        var names: [String] = []
        for offset in stride(from: 0, to: data.count - 1024, by: 512) {
            let header = data.subdata(in: offset..<offset + 512)
            guard header.contains(where: { $0 != 0 }) else { break }
            names.append(String(decoding: header[0..<100].prefix { $0 != 0 }, as: UTF8.self))
        }
        #expect(names == ["/var", "/var/cache", "/var/cache/nginx", "/var/lib", "/var/lib/postgresql", "/var/lib/postgresql/data"])
    }
}
