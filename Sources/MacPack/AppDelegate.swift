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
        model.onStagingHandBack = { [weak self] url in
            self?.handBackToInstaller(url)
        }

        let arguments = ProcessInfo.processInfo.arguments
        model.start(firstRun: arguments.contains("--first-run"))
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        model.enqueue(urls: urls)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Approval happens in System Settings. Returning to MacPack must
        // reconnect the queue even if setup's short retry window has ended.
        model.refreshSystemState()
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

    /// Reopens a package MacPack could not stage with Apple's Installer so
    /// the install still proceeds through the normal macOS flow. The bypass
    /// keeps the interceptor from re-capturing this exact launch and looping
    /// back into the same failing staging attempt.
    private func handBackToInstaller(_ url: URL) {
        let normalized = url.standardizedFileURL.resolvingSymlinksInPath()
        installerInterceptor.bypass(path: normalized.path)
        guard let installer = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.installer"
        ) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [normalized],
            withApplicationAt: installer,
            configuration: configuration
        ) { _, _ in }
    }

    private static var wasLaunchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAELaunchedAsLogInItem) != nil
    }
}
