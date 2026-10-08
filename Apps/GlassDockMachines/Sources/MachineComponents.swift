import GlassDockMachines
import SwiftUI

struct MachineEmblem: View {
    let system: MachineOS
    let size: CGFloat
    var body: some View {
        Image(systemName: system == .macos ? "apple.logo" : system.isLinux ? "terminal" : "desktopcomputer")
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: size * 0.24))
            .accessibilityHidden(true)
    }
}

struct MachineStatus: View {
    let value: String?
    var body: some View {
        Label(MachineDisplayState(status: value).title, systemImage: MachineDisplayState(status: value).symbol)
            .font(.caption)
            .foregroundStyle(value == "running" ? Color.green : Color.secondary)
    }
}

struct ResourceTile: View {
    let title: String
    let value: String
    let symbol: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.medium)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}

struct MachineStartAppearance: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

struct MachineSidebarRow: View {
    let machine: MachineConfiguration
    let state: MachineDisplayState
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: machine.operatingSystem == .macos ? "apple.logo" : machine.operatingSystem.isLinux ? "terminal" : "desktopcomputer")
                .foregroundStyle(.secondary).frame(width: 18).accessibilityHidden(true)
            Text(machine.name).lineLimit(1)
            Spacer(minLength: 6)
            if state != .stopped {
                Image(systemName: state.symbol).font(.system(size: 11)).foregroundStyle(.secondary)
                    .help(state.title).accessibilityHidden(true)
            }
        }
        .padding(.vertical, 3)
        .help("\(machine.name) · \(state.title)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(machine.name), \(state.title)")
    }
}
