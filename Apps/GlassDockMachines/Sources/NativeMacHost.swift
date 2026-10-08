import AppKit
import GlassDockMachines
import SwiftUI
import Virtualization

@MainActor final class NativeMacHost: ObservableObject {
    static let shared = NativeMacHost()
    @Published var sessions: [UUID: MacOSSession] = [:]
    @Published var requestedMachine: UUID?
    @Published var failure: String?
    var openLibraryWindow: (() -> Void)?
    private var handledStartup = false

    var hasActiveSessions: Bool { sessions.values.contains { $0.status != "stopped" } }

    func start(store: MachineStore, id: UUID) throws {
        if let session = sessions[id], session.status != "stopped" {
            show(id)
            return
        }
        let session = try MacOSSession(store: store, id: id)
        session.onShow = { [weak self] in self?.show(id) }
        session.onStopped = { [weak self, weak session] in
            guard let self, let session, self.sessions[id] === session else { return }
            self.sessions[id] = nil
        }
        sessions[id] = session
        requestedMachine = id
        Task { @MainActor in
            do { try await session.start() } catch { failure = error.localizedDescription }
        }
    }

    func handleStartup(store: MachineStore) throws {
        guard !handledStartup else { return }
        handledStartup = true
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--start-macos") else { return }
        guard args.indices.contains(flag + 1), let id = UUID(uuidString: args[flag + 1]) else { throw MachineError.invalid("Invalid native machine startup request") }
        try start(store: store, id: id)
    }

    private func show(_ id: UUID) {
        requestedMachine = id
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && !$0.isSheet }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openLibraryWindow?()
        }
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class MachinesAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Native virtualization belongs to this process. Keep it alive just as
        // QEMU's supervisor keeps a guest alive when its desktop viewer closes.
        if NativeMacHost.shared.hasActiveSessions {
            sender.hide(nil)
            return .terminateCancel
        }
        return .terminateNow
    }
}

@MainActor struct NativeMacDesktopView: View {
    @ObservedObject var session: MacOSSession
    var body: some View {
        NativeMacDisplay(session: session)
            .overlay(alignment: .bottom) {
                if session.status == "installing" {
                    VStack(spacing: 8) {
                        Text("Installing macOS · \(Int(session.installationProgress * 100))%").font(.callout)
                        ProgressView(value: session.installationProgress).frame(maxWidth: 280)
                    }
                    .padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).padding(24)
                }
            }
    }
}

@MainActor private struct NativeMacDisplay: NSViewRepresentable {
    @ObservedObject var session: MacOSSession
    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.capturesSystemKeys = true
        view.automaticallyReconfiguresDisplay = true
        view.virtualMachine = session.machine
        return view
    }
    func updateNSView(_ view: VZVirtualMachineView, context: Context) {
        view.virtualMachine = session.machine
    }
    func makeCoordinator() -> MacOSSession { session }
    static func dismantleNSView(_ view: VZVirtualMachineView, coordinator: MacOSSession) {
        coordinator.revokeShare()
        view.virtualMachine = nil
    }
}
