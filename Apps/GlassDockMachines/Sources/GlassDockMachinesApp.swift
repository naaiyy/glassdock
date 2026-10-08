import AppKit
import GlassDockMachines
import SwiftUI

@main
struct MachinesApplication: App {
    @NSApplicationDelegateAdaptor(MachinesAppDelegate.self) private var delegate
    @StateObject private var nativeHost = NativeMacHost.shared
    var body: some Scene {
        WindowGroup("Glass Dock Machines", id: "machines") { MachineLibraryView().environmentObject(nativeHost) }
            .defaultSize(width: 1180, height: 780)
            .windowResizability(.contentMinSize)
    }
}

struct MachineLibraryView: View {
    @EnvironmentObject private var nativeHost: NativeMacHost
    @Environment(\.openWindow) private var openWindow
    @State private var machines: [MachineConfiguration] = []
    @State private var selected: UUID?
    @State private var sessions: [UUID: String] = [:]
    @State private var status: [UUID: String] = [:]
    @State private var error: String?
    @State private var working = false
    @State private var refreshing = false
    @State private var creating = false
    @State private var shareClipboard = false
    @State private var matchMacTyping = true
    @State private var editing: MachineConfiguration?
    @State private var savedSnapshots: [String] = []
    @State private var memorySnapshots: [String] = []
    @State private var sharedDirectory: URL?
    @State private var shareReadOnly = true
    @State private var usbRequest = 0
    private func store() throws -> MachineStore { try MachineStore(root: MachineStore.defaultRoot, runtime: MachineRuntime.discover()) }
    @State private var searchText = ""
    @State private var showingInspector = false
    @State private var confirmingShutdown = false
    @State private var pendingRestore: (id: UUID, name: String, memory: Bool)?
    @State private var pendingCheckpointDeletion: (id: UUID, name: String)?
    private func displayState(_ machine: MachineConfiguration) -> MachineDisplayState { MachineDisplayState(status: status[machine.id]) }
    private var currentMachine: MachineConfiguration? { machines.first { $0.id == selected } }
    private var filteredMachines: [MachineConfiguration] {
        machines.filter { searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selected) {
                ForEach(filteredMachines) { machine in
                    MachineSidebarRow(machine: machine, state: displayState(machine))
                        .tag(machine.id)
                }
            }
            .overlay {
                if !searchText.isEmpty && filteredMachines.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .searchable(text: $searchText, placement: .sidebar, prompt: "Find a machine")
            .navigationTitle("Machines")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Spacer()
                    Button(action: importMachine) { Image(systemName: "square.and.arrow.down") }
                        .buttonStyle(.borderless).help("Import Machine…").accessibilityLabel("Import Machine")
                }.font(.caption).padding(16)
            }
            .toolbar {
                ToolbarItem {
                    Button {
                        creating = true
                    } label: {
                        Label("New Machine", systemImage: "plus")
                    }
                    .keyboardShortcut("n", modifiers: .command).help("New Machine")
                    .disabled(working)
                }
            }
        } detail: {
            Group {
                if let machine = currentMachine {
                    machineDetail(machine)
                        .navigationTitle(machine.name)
                        .navigationSubtitle(displayState(machine).title)
                } else {
                    ContentUnavailableView {
                        Label("A space for every system", systemImage: "desktopcomputer")
                    } description: {
                        Text("Run Linux, Windows, and macOS alongside your Mac. Create a machine or import an existing one to get started.")
                    } actions: {
                        Button("New Machine", systemImage: "plus") { creating = true }
                            .modifier(MachineStartAppearance())
                        Button("Import Machine…", action: importMachine)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .toolbar {
                if let machine = currentMachine {
                    if #available(macOS 26, *) {
                        ToolbarItemGroup(placement: .primaryAction) { machineToolbarControls(machine) }
                            .sharedBackgroundVisibility(.visible)
                    } else {
                        ToolbarItemGroup(placement: .primaryAction) { machineToolbarControls(machine) }
                    }
                }
            }
        }
        .inspector(isPresented: $showingInspector) {
            if let machine = currentMachine {
                machineInspector(machine)
                    .toolbar {
                        if showingInspector {
                            ToolbarItem {
                                Button {
                                    showingInspector = false
                                } label: {
                                    Label("Hide Inspector", systemImage: "sidebar.right")
                                }
                                .help("Hide Inspector")
                            }
                        }
                    }
            }
        }
        .inspectorColumnWidth(min: 250, ideal: 280, max: 340)
        .tint(.gray)
        .confirmationDialog("Shut down this machine?", isPresented: $confirmingShutdown, titleVisibility: .visible) {
            if let machine = currentMachine {
                Button("Shut Down", role: .destructive) { perform { try store().shutdown(machine.id) } }
            }
        } message: {
            Text("Save your work in the guest before shutting down.")
        }
        .confirmationDialog("Restore this checkpoint?", isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }), titleVisibility: .visible) {
            if let restore = pendingRestore {
                Button("Restore “\(restore.name)”", role: .destructive) {
                    perform {
                        if restore.memory {
                            if try store().status(restore.id) == "stopped" {
                                try store().start(restore.id, memorySnapshot: restore.name)
                            } else {
                                try store().restoreMemorySnapshot(restore.id, name: restore.name)
                            }
                        } else {
                            try store().restore(restore.id, name: restore.name)
                        }
                    }
                    pendingRestore = nil
                }
            }
        } message: {
            Text("Changes since this checkpoint will be replaced. Save or export anything you want to keep first.")
        }
        .confirmationDialog(
            "Delete this memory checkpoint?", isPresented: Binding(get: { pendingCheckpointDeletion != nil }, set: { if !$0 { pendingCheckpointDeletion = nil } }),
            titleVisibility: .visible
        ) {
            if let checkpoint = pendingCheckpointDeletion {
                Button("Delete “\(checkpoint.name)”", role: .destructive) {
                    perform { try store().deleteMemorySnapshot(checkpoint.id, name: checkpoint.name) }
                    pendingCheckpointDeletion = nil
                }
            }
        } message: {
            Text("This checkpoint cannot be recovered after deletion.")
        }
        .frame(minWidth: 760, minHeight: 520)
        .sheet(isPresented: $creating) {
            MachineEditor { config, disk, iso in
                creating = false
                perform {
                    if config.operatingSystem == .macos {
                        _ = try store().create(config, macOSRestoreImage: iso)
                    } else if config.operatingSystem == .omarchy {
                        _ = try store().create(config, omarchyGuest: disk)
                    } else {
                        _ = try store().create(config, disk: disk, media: iso)
                    }
                }
            }
        }
        .sheet(item: $editing) { machine in
            MachineEditor(existing: machine) { config, _, _ in
                editing = nil
                perform {
                    try store().configure(
                        machine.id, cpuCount: config.cpuCount, memoryMiB: config.memoryMiB, graphics: config.graphics, audioEnabled: config.audioEnabled,
                        usbEnabled: config.usbEnabled)
                }
            }
        }
        .onChange(of: sharedDirectory) { _, _ in updateNativeShare() }
        .onChange(of: shareReadOnly) { _, _ in updateNativeShare() }
        .onChange(of: selected) { previous, value in
            if let previous, sharedDirectory != nil, ["running", "paused"].contains(status[previous] ?? ""), machines.first(where: { $0.id == previous })?.operatingSystem == .macos
            {
                perform { try store().control(previous).command("glassdock-share") }
            }
            shareClipboard = false
            sharedDirectory = nil
            shareReadOnly = true
            usbRequest = 0
            savedSnapshots = []
            memorySnapshots = []
            refresh()
        }
        .alert("Machine operation failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
        .onReceive(nativeHost.$requestedMachine) { value in
            if let value { selected = value }
        }
        .onReceive(nativeHost.$failure) { value in
            if let value { error = value }
        }
        .task {
            nativeHost.openLibraryWindow = { openWindow(id: "machines") }
            if let requested = nativeHost.requestedMachine { selected = requested }
            do { try nativeHost.handleStartup(store: store()) } catch { self.error = error.localizedDescription }
            refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if !working { refresh() }
            }
        }
    }
    @ViewBuilder private func machineToolbarControls(_ machine: MachineConfiguration) -> some View {
        if working { ProgressView().controlSize(.small).accessibilityLabel("Working") }
        if displayState(machine).canStart {
            Button("Start", systemImage: "play.fill") { startMachine(machine) }
                .disabled(working).help("Start Machine")
        } else if displayState(machine).showsDesktop {
            if displayState(machine).canPause {
                Button(status[machine.id] == "paused" ? "Resume" : "Pause", systemImage: status[machine.id] == "paused" ? "play" : "pause") {
                    perform { try store().control(machine.id).command(status[machine.id] == "paused" ? "cont" : "stop") }
                }.disabled(working)
            }
            Button("Shut Down", systemImage: "power") { confirmingShutdown = true }.disabled(working)
        }
        machineActions(machine)
        if !showingInspector {
            Button {
                showingInspector = true
            } label: {
                Label("Show Inspector", systemImage: "sidebar.right")
            }
            .help("Show Sharing Controls")
        }
    }

    @ViewBuilder
    private func machineDetail(_ machine: MachineConfiguration) -> some View {
        if machine.operatingSystem == .macos, let session = nativeHost.sessions[machine.id] {
            NativeMacDesktopView(session: session).frame(maxWidth: .infinity, maxHeight: .infinity).id(machine.id)
        } else if machine.operatingSystem == .macos && displayState(machine).showsDesktop {
            VStack(spacing: 20) {
                MachineEmblem(system: .macos, size: 88)
                Text("This machine is running in another Machines window.").foregroundStyle(.secondary)
                Button("Show Machine", systemImage: "macwindow") { perform { try store().control(machine.id).command("glassdock-show") } }
                    .modifier(MachineStartAppearance())
            }.padding(40)
        } else if displayState(machine).showsDesktop {
            DesktopView(
                socket: QEMUArguments.socketDirectory(id: machine.id).appendingPathComponent("spice.sock"), shareClipboard: shareClipboard,
                matchMacTyping: matchMacTyping, sharedDirectory: sharedDirectory, shareReadOnly: shareReadOnly, usbRequest: usbRequest
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id("\(machine.id)-\(sessions[machine.id] ?? "")")
        } else {
            ScrollView {
                VStack(spacing: 28) {
                    MachineEmblem(system: machine.operatingSystem, size: 88)
                    VStack(spacing: 8) {
                        Text(machine.name).font(.largeTitle.weight(.semibold)).textSelection(.enabled)
                        Text("\(machine.operatingSystem.displayName) · ARM64")
                            .font(.title3).foregroundStyle(.secondary)
                        MachineStatus(value: status[machine.id])
                    }
                    ViewThatFits {
                        HStack(spacing: 12) { resourceTiles(machine) }
                        VStack(spacing: 12) { resourceTiles(machine) }
                    }
                    .frame(maxWidth: 560)
                    if displayState(machine).canStart {
                        VStack(spacing: 12) {
                            Button("Start Machine", systemImage: "play.fill") { startMachine(machine) }
                                .modifier(MachineStartAppearance()).controlSize(.large).disabled(working)
                        }
                    } else {
                        ProgressView()
                        Text(
                            status[machine.id] == "busy"
                                ? "An archive or state operation is in progress." : "Waiting for the machine’s control connection. Open Logs if this continues."
                        )
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                }
                .padding(40)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.center)
        }
    }

    @ViewBuilder private func resourceTiles(_ machine: MachineConfiguration) -> some View {
        ResourceTile(title: "Processors", value: "\(machine.cpuCount) cores", symbol: "cpu")
        ResourceTile(title: "Memory", value: "\(machine.memoryMiB / 1024) GB", symbol: "memorychip")
        ResourceTile(title: "Storage", value: "\(machine.diskGiB) GB", symbol: "internaldrive")
    }

    private func machineInspector(_ machine: MachineConfiguration) -> some View {
        Form {
            if machine.operatingSystem != .macos {
                Section("Input") {
                    Toggle("Mac keyboard", isOn: $matchMacTyping)
                        .help("Translate Mac typing to a US guest layout. Command-V types clipboard text directly.")
                    Toggle("Clipboard", isOn: $shareClipboard)
                        .disabled(machine.operatingSystem == .omarchy)
                        .help(
                            machine.operatingSystem == .omarchy
                                ? "Wayland clipboard sync is not available. Enable Mac keyboard and use Command-V to type text into Omarchy."
                                : "Share text with the guest. Requires guest tools.")
                }
            } else {
                Section("Input") { Text("Native Mac keyboard and trackpad. Clipboard sync is unavailable.").foregroundStyle(.secondary) }
            }
            Section("Folder") {
                if let directory = sharedDirectory {
                    Label(directory.lastPathComponent, systemImage: "folder")
                        .lineLimit(2).help(directory.path)
                    Toggle("Read only", isOn: $shareReadOnly)
                    Button("Stop Sharing", systemImage: "xmark.circle", role: .destructive) { sharedDirectory = nil }
                } else {
                    Button("Share Folder…", systemImage: "folder.badge.plus", action: chooseSharedFolder)
                        .disabled(machine.operatingSystem == .macos && !displayState(machine).canPause)
                        .help("Choose a folder for this guest. Sharing starts read only and ends when you switch machines.")
                }
            }
            if machine.operatingSystem != .macos {
                Section("Devices") {
                    Button("USB Devices…", systemImage: "cable.connector") { usbRequest += 1 }
                        .disabled(machine.usbEnabled != true || !displayState(machine).canPause)
                        .help(machine.usbEnabled == true ? "Attach or detach a USB device while the machine is running." : "Enable USB forwarding in machine settings first.")
                }
            }
        }.formStyle(.grouped)
    }

    private func machineActions(_ machine: MachineConfiguration) -> some View {
        Menu {
            Menu {
                Button("Settings…", systemImage: "gearshape") { editing = machine }
                Button("Clone", systemImage: "plus.square.on.square") { perform { _ = try store().clone(machine.id, name: machine.name + " Copy") } }
                Button("Create Snapshot", systemImage: "camera") { perform { try store().snapshot(machine.id, name: "snapshot-" + String(Int(Date().timeIntervalSince1970))) } }
                Menu("Restore Snapshot", systemImage: "clock.arrow.circlepath") {
                    ForEach(savedSnapshots, id: \.self) { name in
                        Button(name) { pendingRestore = (machine.id, name, false) }
                    }
                }.disabled(savedSnapshots.isEmpty)
                Button("Export ZIP…", systemImage: "square.and.arrow.up") { exportMachine(machine) }
                Button("Export Folder…", systemImage: "folder") { exportFolder(machine) }
                Divider()
                if machine.operatingSystem != .macos {
                    Button(machine.installationMedia ? "Eject Installer" : "Mount Installer", systemImage: machine.installationMedia ? "eject" : "opticaldisc") {
                        perform { try store().setMediaMounted(machine.id, installation: !machine.installationMedia) }
                    }
                    Button(machine.seedMedia ? "Eject Guest Tools" : "Mount Guest Tools", systemImage: machine.seedMedia ? "eject" : "opticaldisc") {
                        perform { try store().setMediaMounted(machine.id, seed: !machine.seedMedia) }
                    }
                }
            } label: {
                Label("Configuration & Archives", systemImage: "gearshape").labelStyle(.titleAndIcon)
            }
            .disabled(!displayState(machine).canStart || working)
            Menu {
                Button("Save Checkpoint", systemImage: "memorychip") {
                    perform { try store().saveMemorySnapshot(machine.id, name: "memory-" + String(Int(Date().timeIntervalSince1970))) }
                }
                .disabled(!displayState(machine).canPause || machine.graphics != .basic || machine.operatingSystem == .macos)
                Menu("Restore Checkpoint", systemImage: "clock.arrow.circlepath") {
                    ForEach(memorySnapshots, id: \.self) { name in
                        Button(name) {
                            pendingRestore = (machine.id, name, true)
                        }
                    }
                }.disabled(memorySnapshots.isEmpty)
                Menu("Delete Checkpoint", systemImage: "trash") {
                    ForEach(memorySnapshots, id: \.self) { name in Button(name, role: .destructive) { pendingCheckpointDeletion = (machine.id, name) } }
                }.disabled(memorySnapshots.isEmpty)
            } label: {
                Label("Memory Checkpoints", systemImage: "memorychip").labelStyle(.titleAndIcon)
            }
            .disabled(working || machine.operatingSystem == .macos)
            Button {
                if let store = try? store() { NSWorkspace.shared.open(store.bundle(machine.id).appendingPathComponent("supervisor.log")) }
            } label: {
                Label("Logs", systemImage: "doc.text").labelStyle(.titleAndIcon)
            }.help("Open the machine supervisor log")
        } label: {
            Label("Machine Actions", systemImage: "ellipsis")
        }
        .help("Machine Actions")
        .disabled(working)
    }

    private func startMachine(_ machine: MachineConfiguration) {
        if machine.operatingSystem == .macos {
            do { try nativeHost.start(store: store(), id: machine.id) } catch { self.error = error.localizedDescription }
            refresh()
        } else {
            perform { try store().start(machine.id) }
        }
    }

    private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        DispatchQueue.global(qos: .utility).async {
            do {
                let store = try store()
                let configurations = try store.list()
                var statuses: [UUID: String] = [:]
                var runIDs: [UUID: String] = [:]
                var snapshots: [UUID: [String]] = [:]
                var memory: [UUID: [String]] = [:]
                for machine in configurations {
                    statuses[machine.id] = store.status(machine.id)
                    runIDs[machine.id] = try? String(contentsOf: store.bundle(machine.id).appendingPathComponent("run-id"), encoding: .utf8)
                    snapshots[machine.id] = (try? store.snapshots(machine.id)) ?? []
                    memory[machine.id] = (try? store.memorySnapshots(machine.id)) ?? []
                }
                DispatchQueue.main.async {
                    machines = configurations
                    status = statuses
                    sessions = runIDs
                    if selected == nil { selected = configurations.first?.id }
                    savedSnapshots = selected.flatMap { snapshots[$0] } ?? []
                    memorySnapshots = selected.flatMap { memory[$0] } ?? []
                    refreshing = false
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    self.error = message
                    refreshing = false
                }
            }
        }
    }
    private func updateNativeShare() {
        guard let machine = currentMachine, machine.operatingSystem == .macos, displayState(machine).canPause else { return }
        let directory = sharedDirectory
        let readOnly = shareReadOnly
        perform {
            var arguments: [String: Any] = [:]
            if let directory { arguments = ["path": directory.path, "read-only": readOnly] }
            try store().control(machine.id).command("glassdock-share", arguments: arguments)
        }
    }
    private func chooseSharedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder to make available to this guest. Sharing starts read only and ends when you switch machines."
        if panel.runModal() == .OK, let url = panel.url {
            shareReadOnly = true
            sharedDirectory = url
        }
    }
    private func exportFolder(_ machine: MachineConfiguration) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = machine.name + ".glassvmarchive"
        if panel.runModal() == .OK, let url = panel.url { perform { try store().exportDirectory(machine.id, to: url) } }
    }
    private func importMachine() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Glass Dock machine archive."
        if panel.runModal() == .OK, let url = panel.url {
            perform { _ = try store().importArchive(url) }
        }
    }
    private func exportMachine(_ machine: MachineConfiguration) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = machine.name + ".glassvm.zip"
        let compact = NSButton(checkboxWithTitle: "Compact disk for export (takes longer)", target: nil, action: nil)
        compact.isEnabled = machine.operatingSystem != .macos
        compact.state = .off
        compact.sizeToFit()
        panel.accessoryView = compact
        if panel.runModal() == .OK, let url = panel.url {
            let compress = compact.state == .on
            perform { try store().export(machine.id, to: url, compact: compress) }
        }
    }
    private func perform(_ action: @escaping () throws -> Void) {
        working = true
        DispatchQueue.global(qos: .userInitiated).async {
            var message: String?
            do { try action() } catch { message = error.localizedDescription }
            DispatchQueue.main.async {
                working = false
                error = message
                refresh()
            }
        }
    }
}
