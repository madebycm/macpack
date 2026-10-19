import AppKit

@main
struct MacPackMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        if ProcessInfo.processInfo.arguments.contains("--check-installer-service") {
            let client = HelperClient()
            client.ping { ready in
                if ready {
                    print("Installer service: ready")
                } else {
                    let state = SystemIntegration.helperRegistrationState()
                    if case let .unavailable(message) = state {
                        print("Installer service: unavailable (\(message))")
                    } else {
                        print("Installer service: unavailable (\(state.label))")
                    }
                }
                exit(ready ? EXIT_SUCCESS : EX_UNAVAILABLE)
            }
            application.run()
            return
        }
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
