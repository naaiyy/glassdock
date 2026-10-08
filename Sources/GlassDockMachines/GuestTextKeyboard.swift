import Foundation

/// Converts host text to complete PC set-1 keystrokes for a US-layout guest.
/// Validation happens before sending any key, so unsupported text cannot become a partial password.
public enum GuestTextKeyboard {
    /// A parent window can retain this responder while a host sheet takes focus.
    public static func acceptsInput(isFirstResponder: Bool, isKeyWindow: Bool, hasAttachedSheet: Bool) -> Bool {
        isFirstResponder && isKeyWindow && !hasAttachedSheet
    }

    public struct Stroke: Equatable, Sendable {
        public let code: Int32
        public let shift: Bool
    }

    /// Shortcut letters are resolved from the active host layout, not Mac key positions.
    public static func shortcutStroke(for characters: String) -> Stroke? {
        let letter = characters.lowercased()
        guard letter.count == 1, "abcdefghijklmnopqrstuvwxyz".contains(letter) else { return nil }
        return try? strokes(for: letter).first
    }

    public static func strokes(for text: String) throws -> [Stroke] {
        guard text.utf8.count <= 65_536 else { throw MachineError.invalid("Paste is limited to 64 KiB.") }
        let plain = "1234567890-=qwertyuiop[]asdfghjkl;'`\\zxcvbnm,./ "
        let shifted = "!@#$%^&*()_+QWERTYUIOP{}ASDFGHJKL:\"~|ZXCVBNM<>? "
        let codes: [Int32] = [
            0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d,
            0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b,
            0x1e, 0x1f, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2b,
            0x2c, 0x2d, 0x2e, 0x2f, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x39,
        ]
        var mapping: [Character: Stroke] = [:]
        for (character, code) in zip(plain, codes) { mapping[character] = Stroke(code: code, shift: false) }
        for (character, code) in zip(shifted, codes) where character != " " { mapping[character] = Stroke(code: code, shift: true) }
        mapping["\n"] = Stroke(code: 0x1c, shift: false)
        mapping["\t"] = Stroke(code: 0x0f, shift: false)
        // Normalize CRLF as one Return; standalone CR is also Return.
        return try text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").map { character in
            guard let stroke = mapping[character] else {
                throw MachineError.invalid(
                    "This text contains characters that require a matching guest keyboard layout or guest clipboard integration. No text was sent. US text mode supports ASCII letters, numbers and punctuation."
                )
            }
            return stroke
        }
    }
}
