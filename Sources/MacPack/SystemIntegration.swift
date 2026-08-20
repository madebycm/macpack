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
        case .notFound: return .unavailable("Install MacPack in /Applications first.")
        @unknown default: return .unavailable("Unknown helper state.")
        }
    }

    static func registerModernHelper() throws -> IntegrationState {
        let service = SMAppService.daemon(plistName: MacPackConstants.helperPlistName)
        if service.status == .notRegistered {
            try service.register()
        }
        return helperRegistrationState()
    }

    static func openBackgroundItemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

}
