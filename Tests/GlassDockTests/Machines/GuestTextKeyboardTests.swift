import Testing

@testable import GlassDockMachines

@Suite("Guest text keyboard")
struct GuestTextKeyboardTests {
    @Test func hostSheetsAndOtherWindowsDoNotSendKeysToGuest() {
        #expect(GuestTextKeyboard.acceptsInput(isFirstResponder: true, isKeyWindow: true, hasAttachedSheet: false))
        #expect(!GuestTextKeyboard.acceptsInput(isFirstResponder: true, isKeyWindow: true, hasAttachedSheet: true))
        #expect(!GuestTextKeyboard.acceptsInput(isFirstResponder: true, isKeyWindow: false, hasAttachedSheet: false))
        #expect(!GuestTextKeyboard.acceptsInput(isFirstResponder: false, isKeyWindow: true, hasAttachedSheet: false))
    }

    @Test func shortcutLettersFollowHostLayoutAndIgnoreCase() {
        // AZERTY A/Z occupy different physical positions than their US equivalents.
        #expect(GuestTextKeyboard.shortcutStroke(for: "A")?.code == 0x1e)
        #expect(GuestTextKeyboard.shortcutStroke(for: "z")?.code == 0x2c)
        #expect(GuestTextKeyboard.shortcutStroke(for: "V")?.code == 0x2f)
        #expect(GuestTextKeyboard.shortcutStroke(for: "é") == nil)
        #expect(GuestTextKeyboard.shortcutStroke(for: "") == nil)
        #expect(GuestTextKeyboard.shortcutStroke(for: "ab") == nil)
        #expect(GuestTextKeyboard.shortcutStroke(for: "\u{1}") == nil)
    }
    @Test func translatesHostCharactersRatherThanMacKeyPositions() throws {
        let keys = try GuestTextKeyboard.strokes(for: "aAzZ09@:/\\\"!")
        #expect(keys.map(\.code) == [0x1e, 0x1e, 0x2c, 0x2c, 0x0b, 0x0a, 0x03, 0x27, 0x35, 0x2b, 0x28, 0x02])
        #expect(keys.map(\.shift) == [false, true, false, true, false, false, true, true, false, false, true, true])
    }

    @Test func allPrintableASCIIIsRepresentable() throws {
        let text = String((32...126).compactMap(UnicodeScalar.init).map(Character.init))
        #expect(try GuestTextKeyboard.strokes(for: text).count == 95)
    }

    @Test func rejectsUnsupportedTextBeforeAnyKeystrokesAreReturned() {
        #expect(throws: MachineError.self) { try GuestTextKeyboard.strokes(for: "ASCII then é") }
        #expect(throws: MachineError.self) { try GuestTextKeyboard.strokes(for: "emoji 🔐") }
        #expect(throws: MachineError.self) { try GuestTextKeyboard.strokes(for: "\u{0}") }
        #expect(throws: MachineError.self) { try GuestTextKeyboard.strokes(for: String(repeating: "a", count: 65_537)) }
    }

    @Test func normalizesLineEndingsWithoutAddingSubmissions() throws {
        #expect(try GuestTextKeyboard.strokes(for: "a\r\nb\rc\t").map(\.code) == [0x1e, 0x1c, 0x30, 0x1c, 0x2e, 0x0f])
        #expect(try GuestTextKeyboard.strokes(for: "").isEmpty)
        #expect(try GuestTextKeyboard.strokes(for: " ").first?.shift == false)
    }
}
