/// Maps runtime status to presentation and permitted library actions.
/// An unavailable control connection must never be presented as a stopped VM.
public enum MachineDisplayState: Equatable, Sendable {
    case checking, stopped, running, paused, starting, busy, unavailable
    case other(String)

    public init(status: String?) {
        switch status {
        case nil: self = .checking
        case "stopped": self = .stopped
        case "running": self = .running
        case "paused": self = .paused
        case "prelaunch": self = .starting
        case "busy": self = .busy
        case "starting or unavailable": self = .unavailable
        case .some(let value): self = .other(value)
        }
    }

    public var title: String {
        switch self {
        case .checking: "Checking…"
        case .stopped: "Stopped"
        case .running: "Running"
        case .paused: "Paused"
        case .starting: "Starting"
        case .busy: "Busy"
        case .unavailable: "Connecting…"
        case .other(let value): value.capitalized
        }
    }
    public var symbol: String {
        switch self {
        case .running: "play.circle.fill"
        case .paused: "pause.circle.fill"
        case .stopped: "stop.circle"
        case .other: "exclamationmark.circle"
        default: "clock"
        }
    }
    public var canStart: Bool { self == .stopped }
    public var canPause: Bool { self == .running || self == .paused }
    public var showsDesktop: Bool { canPause || self == .starting }
    public var canShutDown: Bool { showsDesktop }
}
