import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = MacPackModel()
    private let suppressInitialWindow = ProcessInfo.processInfo.arguments.contains("--background")
    private var settingsWindowController: SettingsWindowController?
    private var hudWindowController: HUDWindowController!
    private var installerInterceptor: InstallerInterceptor!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        installerInterceptor = InstallerInterceptor { [weak self] urls in
            self?.routePackagesToMacPack(urls)
        }
        installerInterceptor.start()
        hudWindowController = HUDWindowController(model: model) { [weak self] in
            self?.showSettings()
        }
        model.onNeedsAttention = { [weak self] in
            self?.showSettings()
        }

        let arguments = ProcessInfo.processInfo.arguments
        model.start(firstRun: arguments.contains("--first-run"))
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        model.enqueue(urls: urls)
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        guard !suppressInitialWindow, !Self.wasLaunchedAsLoginItem else {
            return false
        }
        DispatchQueue.main.async { [weak self] in self?.showSettings() }
        return false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showSettings()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(model: model)
        }
        settingsWindowController?.show()
        model.refreshSystemState()
    }

    private func routePackagesToMacPack(_ urls: [URL]) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = false

        NSWorkspace.shared.open(
            urls,
            withApplicationAt: Bundle.main.bundleURL,
            configuration: configuration
        ) { [weak self] _, error in
            if let error {
                DispatchQueue.main.async {
                    self?.model.reportRoutingError(error)
                }
            }
        }
    }

    private static var wasLaunchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAELaunchedAsLogInItem) != nil
    }
}
