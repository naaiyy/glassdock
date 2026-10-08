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
        VStack(alignment: .leading, spacing: 20) {
            Text(existing ? "Machine Settings" : "New Machine").font(.title2.bold())
            Form {
                if !existing {
                    TextField("Name", text: $configuration.name)
                    Picker("Operating system", selection: $configuration.operatingSystem) {
                        Text("Linux ARM64").tag(MachineOS.linux)
                        Text("Windows ARM64").tag(MachineOS.windows)
                    }
                }
                Stepper("CPUs: \(configuration.cpuCount)", value: $configuration.cpuCount, in: 1...64)
                Stepper("Memory: \(configuration.memoryMiB / 1024) GB", value: $configuration.memoryMiB, in: 1024...65536, step: 1024)
                if !existing { Stepper("Disk: \(configuration.diskGiB) GB", value: $configuration.diskGiB, in: 8...2048, step: 8) }
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
                if !existing {
                    LabeledContent("Existing disk", value: disk?.lastPathComponent ?? "New empty disk")
                    Button("Choose Disk Image…") { disk = chooseFile() }
                    LabeledContent("Installer", value: iso?.lastPathComponent ?? "None")
                    Button("Choose ARM64 Installer ISO…") { iso = chooseFile() }
                    Text("Disk images and installers are copied into the machine. Windows requires installation and a suitable license.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(existing ? "Save" : "Create") {
                    do {
                        try configuration.validate()
                        submit(configuration, disk, iso)
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 440)
    }
    private func chooseFile() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
