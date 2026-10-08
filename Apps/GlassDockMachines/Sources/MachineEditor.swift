import AppKit
import GlassDockMachines
import SwiftUI

struct MachineEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var configuration: MachineConfiguration
    @State private var disk: URL?
    @State private var iso: URL?
    @State private var error: String?
    private let existing: Bool
    private let submit: (MachineConfiguration, URL?, URL?) -> Void

    init(existing: MachineConfiguration? = nil, submit: @escaping (MachineConfiguration, URL?, URL?) -> Void) {
        self.existing = existing != nil
        _configuration = State(initialValue: existing ?? MachineConfiguration(name: "Linux", operatingSystem: .linux))
        self.submit = submit
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                MachineEmblem(system: configuration.operatingSystem, size: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text(existing ? "Machine Settings" : "New Machine").font(.title2.weight(.semibold))
                    Text(existing ? "Changes apply the next time you start this machine." : "Make room for another operating system.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(24)
            Form {
                if !existing {
                    Section("Identity") {
                        TextField("Name", text: $configuration.name)
                        Picker("Operating system", selection: $configuration.operatingSystem) {
                            Text("Linux ARM64").tag(MachineOS.linux)
                            Text("Windows ARM64").tag(MachineOS.windows)
                        }
                    }
                }
                Section("Resources") {
                    Stepper("Processors: \(configuration.cpuCount) cores", value: $configuration.cpuCount, in: 1...64)
                    Stepper("Memory: \(configuration.memoryMiB / 1024) GB", value: $configuration.memoryMiB, in: 1024...65536, step: 1024)
                    if !existing { Stepper("Disk: \(configuration.diskGiB) GB", value: $configuration.diskGiB, in: 8...2048, step: 8) }
                }
                Section("Display & Devices") {
                    Picker("Graphics", selection: $configuration.graphics) {
                        Text("Basic display").tag(MachineGraphics.basic)
                        if configuration.operatingSystem == .linux { Text("VirGL (Linux)").tag(MachineGraphics.virgl) }
                        if configuration.operatingSystem == .windows { Text("Neptune / DXMT (experimental)").tag(MachineGraphics.neptune) }
                    }
                    Toggle("Audio output", isOn: Binding(get: { configuration.audioEnabled == true }, set: { configuration.audioEnabled = $0 }))
                    Toggle("USB forwarding", isOn: Binding(get: { configuration.usbEnabled == true }, set: { configuration.usbEnabled = $0 }))
                    if configuration.graphics == .neptune {
                        Text("Requires the signed Triton ARM64 guest driver. Direct3D compatibility is experimental.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !existing {
                    Section {
                        HStack {
                            LabeledContent("Disk image", value: disk?.lastPathComponent ?? "Create an empty disk")
                            Button("Choose…") { disk = chooseFile() }.accessibilityLabel("Choose Disk Image")
                            if disk != nil { Button("Clear") { disk = nil }.accessibilityLabel("Clear Disk Image") }
                        }
                        HStack {
                            LabeledContent("Installer", value: iso?.lastPathComponent ?? "No installer selected")
                            Button("Choose…") { iso = chooseFile() }.accessibilityLabel("Choose ARM64 Installer ISO")
                            if iso != nil { Button("Clear") { iso = nil }.accessibilityLabel("Clear Installer ISO") }
                        }
                    } header: {
                        Text("Installation")
                    } footer: {
                        Text("Choose ARM64 media. Files are copied into the machine. Windows requires installation and a suitable license.")
                    }
                }
            }
            .formStyle(.grouped)
            .monospacedDigit()
            .onChange(of: configuration.operatingSystem) { _, _ in configuration.graphics = .basic }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                    .textSelection(.enabled).padding(.horizontal, 24).padding(.bottom, 12)
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(existing ? "Save Changes" : "Create Machine") {
                    do {
                        try configuration.validate()
                        submit(configuration, disk, iso)
                    } catch { self.error = error.localizedDescription }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(configuration.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(20)
        }
        .frame(width: 560, height: existing ? 520 : 720)
    }
    private func chooseFile() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
