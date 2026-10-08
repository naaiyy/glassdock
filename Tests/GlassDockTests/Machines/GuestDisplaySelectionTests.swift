import Testing

@testable import GlassDockMachines

@Suite("Guest display selection")
struct GuestDisplaySelectionTests {
    @Test func acceleratedAdapterSupersedesFirmwarePrimary() {
        #expect(
            GuestDisplaySelection.preferredIndex(in: [
                .init(accelerated: false, primary: true, width: 960, height: 768),
                .init(accelerated: true, primary: false, width: 1920, height: 1080),
            ]) == 1)
    }
    @Test func emptyGPUDoesNotHideUsableFirmware() {
        #expect(
            GuestDisplaySelection.preferredIndex(in: [
                .init(accelerated: false, primary: true, width: 960, height: 768),
                .init(accelerated: true, primary: false, width: 0, height: 0),
            ]) == 0)
    }
    @Test func noActiveSurfaceHasNoSelection() {
        #expect(GuestDisplaySelection.preferredIndex(in: []) == nil)
        #expect(GuestDisplaySelection.preferredIndex(in: [.init(accelerated: true, primary: true, width: 0, height: 768)]) == nil)
    }
}
