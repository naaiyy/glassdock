import Foundation
import Testing

@testable import GlassDockMenuKit

@Suite("Menu-bar popover presentation")
@MainActor
struct StatusPopoverControllerTests {
    @Test("content leaves the native popover material unobstructed")
    func contentUsesNativePopoverMaterial() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repository.appending(path: "Sources/GlassDockMenuKit/MenuViews.swift"),
            encoding: .utf8
        )
        let popoverSource = try #require(
            source.split(separator: "private struct PopoverHeader", maxSplits: 1).first
        )

        #expect(!popoverSource.contains(".background("))
    }

    @Test("containers are the default destination")
    func containersAreDefault() {
        let model = MenuModel()

        #expect(model.selectedSection == .containers)
    }

    @Test("machines opens the companion without controlling the container daemon")
    func opensMachines() {
        var launches = 0
        let model = MenuModel(launchMachines: { launches += 1 })
        model.errorMessage = "Previous error"
        model.openMachines()
        #expect(launches == 1)
        #expect(model.errorMessage == nil)
        #expect(model.snapshot == nil)
        #expect(model.selectedSection == .containers)
    }

    @Test("missing machine companion reports a recoverable launch error")
    func reportsMissingCompanion() {
        let model = MenuModel(launchMachines: {
            throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Machine app is missing"])
        })
        model.openMachines()
        #expect(model.errorMessage == "Machine app is missing")
    }

    @Test("status-item activation toggles one anchored popover")
    func togglesPopover() {
        let popover = TestPopover()
        let focus = TestApplicationFocus()
        let controller = StatusPopoverController(popover: popover, applicationFocus: focus)

        controller.togglePopover()

        #expect(popover.showCount == 1)
        #expect(popover.closeCount == 0)
        #expect(focus.activateCount == 1)

        controller.togglePopover()
        controller.didClosePopover()

        #expect(popover.showCount == 1)
        #expect(popover.closeCount == 1)
        #expect(focus.restoreCount == 1)
    }

    @Test("an outside-click close restores the previous application")
    func restoresFocusAfterTransientClose() {
        let popover = TestPopover()
        let focus = TestApplicationFocus()
        let controller = StatusPopoverController(popover: popover, applicationFocus: focus)

        controller.togglePopover()
        popover.isShown = false
        controller.didClosePopover()

        #expect(focus.restoreCount == 1)
    }
}

@MainActor
private final class TestPopover: StatusPopoverPresenting {
    var isShown = false
    var showCount = 0
    var closeCount = 0

    func show() {
        showCount += 1
        isShown = true
    }

    func close() {
        closeCount += 1
        isShown = false
    }
}

@MainActor
private final class TestApplicationFocus: ApplicationFocusControlling {
    var activateCount = 0
    var restoreCount = 0

    func activateForPopover() {
        activateCount += 1
    }

    func restorePreviousApplication() {
        restoreCount += 1
    }
}
