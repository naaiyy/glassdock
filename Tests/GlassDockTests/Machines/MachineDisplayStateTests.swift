import Testing

@testable import GlassDockMachines

@Suite("Machine library presentation")
struct MachineDisplayStateTests {
    @Test(
        "unavailable and unknown states never offer stopped-machine actions",
        arguments: [nil, "starting or unavailable", "busy", "unknown", "shutdown", "guest-panicked"] as [String?])
    func unavailableIsNotStopped(status: String?) {
        let state = MachineDisplayState(status: status)
        #expect(!state.canStart)
        #expect(!state.canPause)
        #expect(!state.canShutDown)
        #expect(!state.showsDesktop)
    }

    @Test("only stopped machines can start or change configuration")
    func stoppedActions() {
        let state = MachineDisplayState(status: "stopped")
        #expect(state.canStart)
        #expect(!state.showsDesktop)
        #expect(!state.canShutDown)
    }

    @Test("running and paused machines keep the desktop available", arguments: ["running", "paused"])
    func liveDesktop(status: String) {
        let state = MachineDisplayState(status: status)
        #expect(state.showsDesktop)
        #expect(state.canPause)
        #expect(state.canShutDown)
        #expect(!state.canStart)
    }

    @Test("prelaunch shows a connecting desktop without a pause action")
    func prelaunch() {
        let state = MachineDisplayState(status: "prelaunch")
        #expect(state.title == "Starting")
        #expect(state.showsDesktop)
        #expect(state.canShutDown)
        #expect(!state.canPause)
        #expect(!state.canStart)
    }

    @Test("state labels preserve distinction without relying on color")
    func labels() {
        #expect(MachineDisplayState(status: nil).title == "Checking…")
        #expect(MachineDisplayState(status: "paused").title == "Paused")
        #expect(MachineDisplayState(status: "starting or unavailable").title == "Connecting…")
        #expect(MachineDisplayState(status: "guest-panicked").symbol == "exclamationmark.circle")
    }
}
