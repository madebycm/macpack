import Foundation
import MacPackShared
import ServiceManagement

enum IntegrationState: Equatable {
    case checking
    case ready
    case needsApproval
    case notConfigured
    case unavailable(String)

    var label: String {
        switch self {
        case .checking: return "Checking…"
        case .ready: return "Ready"
        case .needsApproval: return "Approval needed"
        case .notConfigured: return "Not configured"
        case .unavailable: return "Unavailable"
        }
    }
}

@MainActor
enum SystemIntegration {
    static func loginItemState() -> IntegrationState {
        switch SMAppService.mainApp.status {
        case .enabled: return .ready
        case .requiresApproval: return .needsApproval
        case .notRegistered: return .notConfigured
        case .notFound: return .unavailable("MacPack must live in /Applications.")
        @unknown default: return .unavailable("Unknown login-item state.")
        }
    }

    static func setLaunchAtLogin(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status != .notRegistered else { return }
            try service.unregister()
        }
    }

    static func helperRegistrationState() -> IntegrationState {
        let legacyURL = URL(fileURLWithPath: MacPackConstants.legacyPlistPath)
        if FileManager.default.fileExists(atPath: legacyURL.path) {
            guard FileManager.default.isExecutableFile(atPath: MacPackConstants.legacyHelperPath) else {
                return .unavailable("The installed helper is missing. Reinstall MacPack to repair it.")
            }
            switch SMAppService.statusForLegacyPlist(at: legacyURL) {
            case .enabled: return .ready
            case .requiresApproval: return .needsApproval
            case .notRegistered: return .notConfigured
            case .notFound: return .unavailable("The installed helper is missing.")
            @unknown default: return .unavailable("Unknown helper state.")
            }
        }

        let service = SMAppService.daemon(plistName: MacPackConstants.helperPlistName)
        switch service.status {
        case .enabled: return .ready
        case .requiresApproval: return .needsApproval
        case .notRegistered: return .notConfigured
        case .notFound:
            let embeddedHelper = Bundle.main.bundleURL.appendingPathComponent(
                "Contents/Library/HelperTools/\(MacPackConstants.helperExecutableName)"
            )
            let embeddedPlist = Bundle.main.bundleURL.appendingPathComponent(
                "Contents/Library/LaunchDaemons/\(MacPackConstants.helperPlistName)"
            )
            if FileManager.default.isExecutableFile(atPath: embeddedHelper.path),
               FileManager.default.fileExists(atPath: embeddedPlist.path) {
                return .notConfigured
            }
            return .unavailable("MacPack's embedded installer service is missing. Reinstall MacPack.")
        @unknown default: return .unavailable("Unknown helper state.")
        }
    }

    static func registerModernHelper() throws -> IntegrationState {
        guard !FileManager.default.fileExists(atPath: MacPackConstants.legacyPlistPath) else {
            throw NSError(
                domain: MacPackConstants.appBundleIdentifier,
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Reinstall MacPack with its installer package to repair the installed service."]
            )
        }

        let service = SMAppService.daemon(plistName: MacPackConstants.helperPlistName)
        // A missing registration can be reported as notFound even when the
        // embedded plist and helper exist. Enable must register in either case.
        switch service.status {
        case .enabled:
            try service.unregister()
            try service.register()
        case .notRegistered, .notFound:
            try service.register()
        case .requiresApproval:
            break
        @unknown default:
            break
        }
        return helperRegistrationState()
    }

    static func openBackgroundItemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

}
