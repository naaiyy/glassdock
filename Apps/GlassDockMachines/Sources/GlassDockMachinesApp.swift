import AppKit
import GlassDockMachines
import SwiftUI

@main
struct MachinesApplication: App {
    var body: some Scene {
        WindowGroup("Glass Dock Machines") { MachineLibraryView() }
            .defaultSize(width: 1100, height: 760)
    }
}

struct MachineLibraryView: View {
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
    var body: some View {
        NavigationSplitView {
            List(machines, selection: $selected) { machine in
                HStack(spacing: 12) {
                    Image(systemName: machine.operatingSystem == .linux ? "terminal" : "desktopcomputer").font(.title2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(machine.name).font(.headline)
                        Text(status[machine.id] ?? "Checking…").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 6).tag(machine.id)
            }
            .navigationTitle("Machines")
            .navigationSplitViewColumnWidth(min: 200, ideal: 250)
            .toolbar {
                Button {
                    creating = true
                } label: {
                    Label("New Machine", systemImage: "plus")
                }
                Button(action: importMachine) { Label("Import", systemImage: "square.and.arrow.down") }
                Button(action: refresh) { Label("Refresh", systemImage: "arrow.clockwise") }
            }
        } detail: {
            if let machine = machines.first(where: { $0.id == selected }) {
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(machine.name).font(.title2.bold())
                            Text("\(machine.cpuCount) CPUs · \(machine.memoryMiB / 1024) GB memory · \(machine.diskGiB) GB disk").font(.caption).foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Spacer()
                        Menu {
                            Toggle("Match Mac typing (US guest)", isOn: $matchMacTyping)
                            Toggle("Share text clipboard", isOn: $shareClipboard)
                            Divider()
                            Button("Share Folder…", action: chooseSharedFolder)
                            Toggle("Shared folder is read only", isOn: $shareReadOnly).disabled(sharedDirectory == nil)
                            Button("Stop Sharing Folder") { sharedDirectory = nil }.disabled(sharedDirectory == nil)
                            Button("USB Devices…") { usbRequest += 1 }.disabled(machine.usbEnabled != true)
                        } label: {
                            Label("Input", systemImage: "keyboard")
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                        .help("Mac typing translates letters and punctuation to a US guest. Command-V types clipboard text directly, without guest tools.")
                        Menu {
                            Button("Settings…") { editing = machine }
                            Button("Clone") { perform { _ = try store().clone(machine.id, name: machine.name + " Copy") } }
                            Button("Create Snapshot") { perform { try store().snapshot(machine.id, name: "snapshot-" + String(Int(Date().timeIntervalSince1970))) } }
                            Menu("Restore Snapshot") {
                                ForEach(savedSnapshots, id: \.self) { name in
                                    Button(name) { perform { try store().restore(machine.id, name: name) } }
                                }
                            }.disabled(savedSnapshots.isEmpty)
                            Button("Export ZIP…") { exportMachine(machine) }
                            Button("Export Folder…") { exportFolder(machine) }
                            Divider()
                            Button(machine.installationMedia ? "Eject Installation ISO" : "Mount Installation ISO") {
                                perform { try store().setMediaMounted(machine.id, installation: !machine.installationMedia) }
                            }
                            Button(machine.seedMedia ? "Eject Guest Tools / Seed ISO" : "Mount Guest Tools / Seed ISO") {
                                perform { try store().setMediaMounted(machine.id, seed: !machine.seedMedia) }
                            }
                        } label: {
                            Label("Manage", systemImage: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                        .disabled(status[machine.id] != "stopped" || working)
                        Menu {
                            Button("Save Memory Checkpoint") { perform { try store().saveMemorySnapshot(machine.id, name: "memory-" + String(Int(Date().timeIntervalSince1970))) } }
                                .disabled(!["running", "paused"].contains(status[machine.id] ?? "") || machine.graphics != .basic)
                            Menu("Restore Memory") {
                                ForEach(memorySnapshots, id: \.self) { name in
                                    Button(name) {
                                        perform {
                                            if try store().status(machine.id) == "stopped" {
                                                try store().start(machine.id, memorySnapshot: name)
                                            } else {
                                                try store().restoreMemorySnapshot(machine.id, name: name)
                                            }
                                        }
                                    }
                                }
                            }.disabled(memorySnapshots.isEmpty)
                            Menu("Delete Memory Checkpoint") {
                                ForEach(memorySnapshots, id: \.self) { name in Button(name) { perform { try store().deleteMemorySnapshot(machine.id, name: name) } } }
                            }.disabled(memorySnapshots.isEmpty)
                        } label: {
                            Label("Memory", systemImage: "memorychip")
                        }
                        .menuStyle(.borderlessButton).fixedSize().disabled(working)
                        Button("Logs", systemImage: "doc.text") {
                            if let store = try? store() { NSWorkspace.shared.open(store.bundle(machine.id).appendingPathComponent("supervisor.log")) }
                        }.help("Open the machine supervisor log")
                        if status[machine.id] == "running" || status[machine.id] == "paused" {
                            Button(status[machine.id] == "paused" ? "Resume" : "Pause", systemImage: status[machine.id] == "paused" ? "play" : "pause") {
                                let command = status[machine.id] == "paused" ? "cont" : "stop"
                                perform { try store().control(machine.id).command(command) }
                            }.disabled(working)
                        }
                        if working { ProgressView().controlSize(.small) }
                        Button("Start", systemImage: "play.fill") { perform { try store().start(machine.id) } }
                            .disabled(status[machine.id] != "stopped" || working)
                        Button("Shut Down", systemImage: "power") { perform { try store().shutdown(machine.id) } }
                            .disabled(!["running", "paused", "prelaunch"].contains(status[machine.id] ?? "") || working)
                    }.padding(20)
                    Divider()
                    if status[machine.id] == "running" || status[machine.id] == "paused" || status[machine.id] == "prelaunch" {
                        DesktopView(
                            socket: QEMUArguments.socketDirectory(id: machine.id).appendingPathComponent("spice.sock"), shareClipboard: shareClipboard,
                            matchMacTyping: matchMacTyping, sharedDirectory: sharedDirectory, shareReadOnly: shareReadOnly, usbRequest: usbRequest
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .id("\(machine.id)-\(sessions[machine.id] ?? "")")
                    } else if status[machine.id] == "busy" {
                        ContentUnavailableView("Machine is busy", systemImage: "hourglass", description: Text("Wait for the current archive or state operation to finish."))
                    } else if status[machine.id] == "starting or unavailable" {
                        ContentUnavailableView(
                            "Waiting for machine control", systemImage: "hourglass",
                            description: Text("The machine is starting or its control connection is unavailable. Check its logs if this continues."))
                    } else {
                        ContentUnavailableView("Machine is stopped", systemImage: "desktopcomputer", description: Text("Start this machine to open its desktop."))
                    }
                }
            } else {
                ContentUnavailableView("Your Linux and Windows machines", systemImage: "desktopcomputer", description: Text("Select a machine from the library."))
            }
        }
        .sheet(isPresented: $creating) {
            MachineEditor { config, disk, iso in
                creating = false
                perform { _ = try store().create(config, disk: disk, media: iso) }
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
        .onChange(of: selected) { _, value in
            shareClipboard = false
            sharedDirectory = nil
            shareReadOnly = true
            usbRequest = 0
            savedSnapshots = []
            refresh()
        }
        .alert("Machine operation failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
        .task {
            refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if !working { refresh() }
            }
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
