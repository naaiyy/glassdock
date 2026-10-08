import AppKit
import CocoaSpice
import CocoaSpiceRenderer
import GlassDockMachines
import MetalKit
import SwiftUI

struct DesktopView: NSViewRepresentable {
    let socket: URL
    var shareClipboard = false
    var matchMacTyping = true
    var sharedDirectory: URL?
    var shareReadOnly = true
    var usbRequest = 0
    func makeNSView(context: Context) -> GuestDesktop { GuestDesktop(socket: socket) }
    func updateNSView(_ view: GuestDesktop, context: Context) {
        view.shareClipboard = shareClipboard
        view.matchMacTyping = matchMacTyping
        view.setSharedDirectory(sharedDirectory, readOnly: shareReadOnly)
        if view.usbRequest != usbRequest {
            view.usbRequest = usbRequest
            view.showUSBPicker()
        }
    }
    static func dismantleNSView(_ view: GuestDesktop, coordinator: ()) { view.disconnect() }
}

final class GuestDesktop: MTKView, CSConnectionDelegate, CSPasteboardDelegate {
    private let controlSocket: URL
    private var connection: CSConnection!
    private var renderer: CSMetalRenderer!
    private var displayObservation: NSKeyValueObservation?
    private var resizeRequest: DispatchWorkItem?
    private var display: CSDisplay?
    private var displays: [CSDisplay] = []
    private var input: CSInput?
    private var buttons: CSInputButton = []
    var matchMacTyping = true {
        didSet { if oldValue != matchMacTyping { cancelTyping() } }
    }
    private var typingRequest: DispatchWorkItem?
    private var typingGeneration = UUID()
    private var pasting = false
    var shareClipboard = false {
        didSet { connection.session.shareClipboard = shareClipboard }
    }
    private var clipboardTimer: Timer?
    private var clipboardChange = NSPasteboard.general.changeCount
    private var guestAgentConnected = false
    var usbRequest = 0
    private var sharedDirectory: URL?
    private var shareReadOnly = true
    func setSharedDirectory(_ url: URL?, readOnly: Bool) {
        guard sharedDirectory != url || shareReadOnly != readOnly else { return }
        if let sharedDirectory { sharedDirectory.stopAccessingSecurityScopedResource() }
        sharedDirectory = url
        shareReadOnly = readOnly
        if let url {
            _ = url.startAccessingSecurityScopedResource()
            connection.session.setSharedDirectory(url.path, readOnly: readOnly)
        } else {
            connection.session.clearSharedDirectory()
        }
    }
    func showUSBPicker() {
        let manager = connection.usbManager
        guard manager.numberFreeChannels > 0 || !manager.usbDevices.isEmpty else {
            showTypingError("Enable USB forwarding in machine settings, then restart it.")
            return
        }
        let devices = manager.usbDevices
        guard !devices.isEmpty else {
            showTypingError("No USB devices are available for forwarding.")
            return
        }
        let alert = NSAlert()
        alert.messageText = "USB forwarding"
        alert.informativeText = "Choose a device to attach or detach. Attaching makes it available to the guest and can disconnect it from your Mac."
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 28))
        for device in devices { picker.addItem(withTitle: (manager.isUsbDeviceConnected(device) ? "Detach: " : "Attach: ") + (device.name ?? "USB device")) }
        alert.accessoryView = picker
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] result in
            guard result == .alertFirstButtonReturn, devices.indices.contains(picker.indexOfSelectedItem) else { return }
            let device = devices[picker.indexOfSelectedItem]
            let completion: (Error?) -> Void = { error in
                if let error { DispatchQueue.main.async { self?.showTypingError(error.localizedDescription) } }
            }
            if manager.isUsbDeviceConnected(device) {
                manager.disconnectUsbDevice(device, withCompletion: completion)
            } else {
                manager.connectUsbDevice(device, withCompletion: completion)
            }
        }
    }
    override var acceptsFirstResponder: Bool { true }
    private var ownsKeyboard: Bool {
        guard let window else { return false }
        return GuestTextKeyboard.acceptsInput(
            isFirstResponder: window.firstResponder === self,
            isKeyWindow: window.isKeyWindow, hasAttachedSheet: window.attachedSheet != nil)
    }
    private var tracking: NSTrackingArea?

    init(socket: URL) {
        controlSocket = socket.deletingLastPathComponent().appendingPathComponent("qmp.sock")
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
        preferredFramesPerSecond = 60
        enableSetNeedsDisplay = false
        isPaused = false
        clearColor = MTLClearColor(red: 0.04, green: 0.04, blue: 0.04, alpha: 1)
        renderer = CSMetalRenderer(metalKitView: self)
        delegate = renderer
        if !CSMain.shared.running { _ = CSMain.shared.spiceStart() }
        connection = CSConnection(unixSocketFile: socket)
        connection.delegate = self
        // Clipboard is opt-in in the manager; do not read the user's pasteboard here.
        connection.session.shareClipboard = false
        connection.session.clearSharedDirectory()
        connection.session.pasteboardDelegate = self
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.shareClipboard else { return }
            let count = NSPasteboard.general.changeCount
            if count != self.clipboardChange {
                self.clipboardChange = count
                NotificationCenter.default.post(name: .init("CSPasteboardChangedNotification"), object: self)
            }
        }
        _ = connection.connect()
        connection.usbManager.isAutoConnect = false
        connection.usbManager.isRedirectOnConnect = false
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func disconnect() {
        if let sharedDirectory { sharedDirectory.stopAccessingSecurityScopedResource() }
        connection.session.clearSharedDirectory()
        cancelTyping()
        clipboardTimer?.invalidate()
        resizeRequest?.cancel()
        displayObservation = nil
        input?.releaseKeys()
        if let display { display.removeRenderer(renderer) }
        connection.disconnect()
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(tracking!)
        super.updateTrackingAreas()
    }
    override func layout() {
        super.layout()
        fit()
        requestGuestSize()
    }
    private func requestGuestSize() {
        resizeRequest?.cancel()
        guard guestAgentConnected, let display, bounds.width >= 640, bounds.height >= 480 else { return }
        let target = CGRect(x: 0, y: 0, width: Int(bounds.width) / 2 * 2, height: Int(bounds.height) / 2 * 2)
        guard display.displaySize != target.size else { return }
        let request = DispatchWorkItem { [weak self] in self?.display?.requestResolution(target) }
        resizeRequest = request
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: request)
    }
    private func fit() {
        guard let display, display.displaySize.width > 0, display.displaySize.height > 0 else { return }
        let size = display.displaySize
        let pixels = convertToBacking(bounds).size
        renderer.viewportScale = min(pixels.width / size.width, pixels.height / size.height)
        renderer.viewportOrigin = .zero
    }
    private func position(_ event: NSEvent) {
        guard let input, let display else { return }
        let point = convert(event.locationInWindow, from: nil)
        let scale = min(bounds.width / display.displaySize.width, bounds.height / display.displaySize.height)
        guard scale > 0 else { return }
        let x = (point.x - (bounds.width - display.displaySize.width * scale) / 2) / scale
        let y = (bounds.height - point.y - (bounds.height - display.displaySize.height * scale) / 2) / scale
        input.sendMousePosition(buttons, absolutePoint: CGPoint(x: max(0, min(x, display.displaySize.width - 1)), y: max(0, min(y, display.displaySize.height - 1))))
    }
    override func mouseMoved(with event: NSEvent) { position(event) }
    override func mouseDragged(with event: NSEvent) { position(event) }
    override func rightMouseDragged(with event: NSEvent) { position(event) }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        position(event)
        buttons.insert(.left)
        input?.sendMouseButton(.left, mask: buttons, pressed: true)
    }
    override func mouseUp(with event: NSEvent) {
        buttons.remove(.left)
        input?.sendMouseButton(.left, mask: buttons, pressed: false)
    }
    override func rightMouseDown(with event: NSEvent) {
        position(event)
        buttons.insert(.right)
        input?.sendMouseButton(.right, mask: buttons, pressed: true)
    }
    override func rightMouseUp(with event: NSEvent) {
        buttons.remove(.right)
        input?.sendMouseButton(.right, mask: buttons, pressed: false)
    }
    override func scrollWheel(with event: NSEvent) { input?.sendMouseScroll(.smooth, buttonMask: buttons, dy: event.scrollingDeltaY) }
    override func keyDown(with event: NSEvent) {
        guard ownsKeyboard, !pasting else { return }
        if event.modifierFlags.contains(.command) {
            if handleMacShortcut(event) { return }
            return
        }
        if matchMacTyping, !event.modifierFlags.contains(.control), let text = event.characters,
            !text.isEmpty, text.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 && $0.value < 0xf700 })
        {
            do {
                let strokes = try GuestTextKeyboard.strokes(for: text)
                input?.releaseKeys()
                input?.keyLock.remove(.caps)
                for stroke in strokes { sendTextStroke(stroke) }
            } catch { showTypingError(error.localizedDescription) }
        } else if let code =
            (matchMacTyping && event.modifierFlags.contains(.control)
                ? event.charactersIgnoringModifiers.flatMap { GuestTextKeyboard.shortcutStroke(for: $0)?.code } : nil) ?? Self.scancodes[event.keyCode]
        {
            if matchMacTyping {
                input?.sendStroke(
                    code: code, shift: event.modifierFlags.contains(.shift), control: event.modifierFlags.contains(.control), alt: event.modifierFlags.contains(.option))
            } else {
                input?.send(.press, code: code)
            }
        }
    }
    override func keyUp(with event: NSEvent) {
        guard ownsKeyboard, !matchMacTyping else { return }
        if let code = Self.scancodes[event.keyCode] { input?.send(.release, code: code) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard ownsKeyboard, event.type == .keyDown else { return false }
        return handleMacShortcut(event)
    }
    private func handleMacShortcut(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return false }
        let letter = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if letter == "v" {  // Command-V is an explicit host paste, even before guest tools exist.
            if !event.isARepeat { paste(nil) }
            return true
        }
        guard ["a", "z", "x", "c"].contains(letter), let stroke = GuestTextKeyboard.shortcutStroke(for: letter) else { return false }
        input?.sendStroke(code: stroke.code, shift: event.modifierFlags.contains(.shift), control: true, alt: false)
        return true
    }
    @objc func paste(_ sender: Any?) {
        guard ownsKeyboard, !pasting, let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        do {
            let strokes = try GuestTextKeyboard.strokes(for: text)
            cancelTyping()
            input?.keyLock.remove(.caps)
            pasting = true
            let generation = typingGeneration
            sendPaste(strokes, index: 0, generation: generation)
        } catch { showTypingError(error.localizedDescription) }
    }
    private func sendPaste(_ strokes: [GuestTextKeyboard.Stroke], index: Int, generation: UUID) {
        guard generation == typingGeneration, ownsKeyboard else {
            cancelTyping()
            return
        }
        guard index < strokes.count else {
            pasting = false
            typingRequest = nil
            return
        }
        sendTextStroke(strokes[index])
        let request = DispatchWorkItem { [weak self] in self?.sendPaste(strokes, index: index + 1, generation: generation) }
        typingRequest = request
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.015, execute: request)
    }
    private func sendTextStroke(_ stroke: GuestTextKeyboard.Stroke) {
        input?.sendStroke(code: stroke.code, shift: stroke.shift, control: false, alt: false)
    }
    private func cancelTyping() {
        typingRequest?.cancel()
        typingRequest = nil
        typingGeneration = UUID()
        pasting = false
        input?.releaseKeys()
    }
    private func showTypingError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Guest integration"
        alert.informativeText = message
        if let window { alert.beginSheetModal(for: window) }
    }
    override func resignFirstResponder() -> Bool {
        cancelTyping()
        return super.resignFirstResponder()
    }
    override func flagsChanged(with event: NSEvent) {
        guard ownsKeyboard else {
            input?.releaseKeys()
            return
        }
        let modifiers: [UInt16: (Int32, NSEvent.ModifierFlags)] = [
            56: (0x2a, .shift), 60: (0x36, .shift), 59: (0x1d, .control), 62: (0x11d, .control), 58: (0x38, .option), 61: (0x138, .option), 55: (0x15b, .command),
            54: (0x15c, .command),
        ]
        if let (code, flag) = modifiers[event.keyCode] {
            if flag == .command || matchMacTyping { return }
            input?.send(event.modifierFlags.contains(flag) ? .press : .release, code: code)
        }
    }
    // macOS hardware key codes to PC set-1 codes. Guest layout handles characters.
    private static let scancodes: [UInt16: Int32] = [
        0: 0x1e, 1: 0x1f, 2: 0x20, 3: 0x21, 4: 0x23, 5: 0x22, 6: 0x2c, 7: 0x2d, 8: 0x2e, 9: 0x2f, 11: 0x30, 12: 0x10, 13: 0x11, 14: 0x12, 15: 0x13, 16: 0x15, 17: 0x14, 18: 0x02,
        19: 0x03, 20: 0x04, 21: 0x05, 22: 0x07, 23: 0x06, 24: 0x0d, 25: 0x0a, 26: 0x08, 27: 0x0c, 28: 0x09, 29: 0x0b, 30: 0x1b, 31: 0x18, 32: 0x16, 33: 0x1a, 34: 0x17, 35: 0x19,
        36: 0x1c, 37: 0x26, 38: 0x24, 39: 0x28, 40: 0x25, 41: 0x27, 42: 0x2b, 43: 0x33, 44: 0x35, 45: 0x31, 46: 0x32, 47: 0x34, 48: 0x0f, 49: 0x39, 50: 0x29, 51: 0x0e, 53: 0x01,
        65: 0x53, 67: 0x37, 69: 0x4e, 71: 0x45, 75: 0x135, 76: 0x11c, 78: 0x4a, 81: 0x0d, 82: 0x52, 83: 0x4f, 84: 0x50, 85: 0x51, 86: 0x4b, 87: 0x4c, 88: 0x4d, 89: 0x47, 91: 0x48,
        92: 0x49, 96: 0x3f, 97: 0x40, 98: 0x41, 99: 0x3d, 100: 0x42, 101: 0x43, 103: 0x57, 109: 0x44, 111: 0x58, 115: 0x147, 116: 0x149, 117: 0x153, 118: 0x3e, 119: 0x14f,
        120: 0x3c, 121: 0x151, 122: 0x3b, 123: 0x14b, 124: 0x14d, 125: 0x150, 126: 0x148,
    ]

    func spiceConnected(_ connection: CSConnection) {
        do {
            let qmp = try QMPClient(socket: controlSocket)
            let status = try qmp.command("query-status")
            if (status["return"] as? [String: Any])?["status"] as? String == "prelaunch" { try qmp.command("cont") }
        } catch { print(error.localizedDescription) }
    }
    func spiceDisconnected(_ connection: CSConnection) { DispatchQueue.main.async { self.input?.releaseKeys() } }
    func spiceInputAvailable(_ connection: CSConnection, input: CSInput) {
        DispatchQueue.main.async {
            self.input = input
            input.resetKeyboard()
            input.requestMouseMode(false)
        }
    }
    func spiceInputUnavailable(_ connection: CSConnection, input: CSInput) { DispatchQueue.main.async { self.input = nil } }
    func spiceError(_ connection: CSConnection, code: CSConnectionError, message: String?) { print("SPICE: \(message ?? "Connection error")") }
    func spiceDisplayCreated(_ connection: CSConnection, display: CSDisplay) {
        DispatchQueue.main.async {
            if !self.displays.contains(where: { $0 === display }) { self.displays.append(display) }
            self.selectDisplay()
        }
    }
    private func selectDisplay() {
        let candidates = displays.map {
            GuestDisplaySelection.Candidate(
                accelerated: $0.isGLEnabled, primary: $0.isPrimaryDisplay,
                width: $0.displaySize.width, height: $0.displaySize.height)
        }
        let selected = GuestDisplaySelection.preferredIndex(in: candidates).map { displays[$0] }
        if display !== selected {
            display?.removeRenderer(renderer)
            displayObservation = nil
            display = selected
            selected?.addRenderer(renderer)
            displayObservation = selected?.observe(\.displaySize, options: [.initial, .new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.fit() }
            }
        }
        fit()
    }
    func spiceDisplayUpdated(_ connection: CSConnection, display: CSDisplay) { DispatchQueue.main.async { self.selectDisplay() } }
    func spiceDisplayDestroyed(_ connection: CSConnection, display: CSDisplay) {
        DispatchQueue.main.async {
            self.displays.removeAll { $0 === display }
            self.selectDisplay()
        }
    }
    func spiceAgentConnected(_ connection: CSConnection, supportingFeatures features: CSConnectionAgentFeature) {
        DispatchQueue.main.async {
            self.guestAgentConnected = true
            self.requestGuestSize()
        }
    }
    func spiceAgentDisconnected(_ connection: CSConnection) { DispatchQueue.main.async { self.guestAgentConnected = false } }
    func spiceForwardedPortOpened(_ connection: CSConnection, port: CSPort) {}
    func spiceForwardedPortClosed(_ connection: CSConnection, port: CSPort) {}
    // Deliberately limited to text, and disabled until the user opts in.
    func canReadItem(for type: CSPasteboardType) -> Bool { shareClipboard && type == .string }
    func data(for type: CSPasteboardType) -> Data? {
        guard shareClipboard, type == .string else { return nil }
        return NSPasteboard.general.string(forType: .string)?.data(using: .utf8)
    }
    func setData(_ data: Data, for type: CSPasteboardType) {
        guard shareClipboard, type == .string, let string = String(data: data, encoding: .utf8) else { return }
        setString(string)
    }
    func string() -> String? { shareClipboard ? NSPasteboard.general.string(forType: .string) : nil }
    func setString(_ string: String) {
        guard shareClipboard else { return }
        DispatchQueue.main.async {
            guard self.shareClipboard else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(string, forType: .string)
            self.clipboardChange = NSPasteboard.general.changeCount
        }
    }
    func clearContents() { /* A guest must not clear the host clipboard. */  }

}
