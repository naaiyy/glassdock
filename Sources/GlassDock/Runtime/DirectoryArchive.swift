import Foundation

/// Builds an in-memory ustar archive containing directory entries.
///
/// Glass Dock materializes image `VOLUME` declarations through a create-time
/// archive fallback. The guest runtime separately repairs image-layer
/// directory copy-up where the guest overlayfs needs it.
enum DirectoryArchive {
    /// Writes a POSIX ustar archive whose members are the given absolute
    /// directory paths (mode 0755), sorted and de-duplicated, including every
    /// intermediate component so extraction never depends on pre-existing
    /// parents.
    static func tar(directories: [String], modificationTime: TimeInterval = 0) -> Data {
        var entries = Set<String>()
        for directory in directories {
            let components = directory.split(separator: "/").map(String.init)
            var partial = ""
            for component in components {
                partial += "/" + component
                entries.insert(partial)
            }
        }
        var data = Data()
        for entry in entries.sorted() {
            data.append(header(name: entry, modificationTime: modificationTime))
        }
        data.append(Data(count: 1024))
        let remainder = data.count % 512
        if remainder != 0 { data.append(Data(count: 512 - remainder)) }
        return data
    }

    private static func header(name: String, modificationTime: TimeInterval) -> Data {
        var header = Data(count: 512)
        func write(_ string: String, offset: Int, length: Int) {
            let bytes = Array(string.utf8.prefix(length))
            header.replaceSubrange(offset..<offset + bytes.count, with: bytes)
        }
        func writeOctal(_ value: Int, offset: Int, length: Int) {
            // length includes the terminating NUL; octal digits fill the rest.
            let text = String(value, radix: 8)
            let padded = String(repeating: "0", count: max(0, length - 1 - text.count)) + text
            write(padded.suffix(length - 1).description + "\0", offset: offset, length: length)
        }

        write(name, offset: 0, length: 100)
        writeOctal(0o755, offset: 100, length: 8)  // mode
        writeOctal(0, offset: 108, length: 8)  // uid
        writeOctal(0, offset: 116, length: 8)  // gid
        writeOctal(0, offset: 124, length: 12)  // size (directories: 0)
        writeOctal(Int(modificationTime), offset: 136, length: 12)
        write("        ", offset: 148, length: 8)  // checksum placeholder
        header.replaceSubrange(156..<157, with: Data("5".utf8))  // typeflag: directory
        write("ustar\0", offset: 257, length: 6)  // magic
        write("00", offset: 263, length: 2)  // version
        write("root", offset: 265, length: 32)  // uname
        write("root", offset: 297, length: 32)  // gname

        let checksum = header.reduce(0) { $0 + Int($1) }
        writeOctal(checksum, offset: 148, length: 8)
        return header
    }
}
