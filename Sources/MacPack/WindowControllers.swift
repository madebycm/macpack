import AppKit
import Combine
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let window: NSWindow

    init(model: MacPackModel) {
        let rootView = SettingsView(model: model)
        let hostingController = NSHostingController(rootView: rootView)
        window = NSWindow(contentViewController: hostingController)
        window.title = "MacPack"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = true
        window.setContentSize(NSSize(width: 820, height: 560))
        window.minSize = NSSize(width: 760, height: 500)
        window.center()
        window.isReleasedWhenClosed = false
    }

    func show() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class HUDWindowController {
    private var panel: NSPanel?
    private let model: MacPackModel
    private let openQueue: () -> Void
    private var cancellables = Set<AnyCancellable>()

    init(model: MacPackModel, openQueue: @escaping () -> Void) {
        self.model = model
        self.openQueue = openQueue

        model.$isHUDVisible
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] visible in
                self?.setVisible(visible)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.position() }
            .store(in: &cancellables)
    }

    private func makePanelIfNeeded() -> NSPanel {
        if let panel { return panel }

        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 58),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.contentViewController = NSHostingController(
            rootView: HUDView(model: model, openQueue: openQueue)
        )
        newPanel.level = .floating
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        newPanel.backgroundColor = .clear
        newPanel.isOpaque = false
        newPanel.hasShadow = true
        newPanel.hidesOnDeactivate = false
        newPanel.isReleasedWhenClosed = false
        newPanel.isExcludedFromWindowsMenu = true
        newPanel.becomesKeyOnlyIfNeeded = true
        newPanel.alphaValue = 0
        panel = newPanel
        return newPanel
    }

    private func position() {
        guard let panel,
              let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        let origin = NSPoint(
            x: frame.maxX - panel.frame.width - 16,
            y: frame.maxY - panel.frame.height - 14
        )
        panel.setFrameOrigin(origin)
    }

    private func setVisible(_ visible: Bool) {
        guard visible || panel != nil else { return }
        let panel = makePanelIfNeeded()
        position()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if visible {
            panel.orderFrontRegardless()
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = visible ? 1 : 0
        } completionHandler: { [weak panel] in
            if !visible { panel?.orderOut(nil) }
        }
    }
}
