import Foundation
import MacPackShared

final class InstallerListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let clientRequirement: String

    override init() {
        clientRequirement = Self.loadClientRequirement()
        super.init()
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        connection.setCodeSigningRequirement(clientRequirement)
        connection.exportedInterface = NSXPCInterface(with: MacPackInstalling.self)
        connection.exportedObject = InstallerService()
        connection.remoteObjectInterface = NSXPCInterface(with: MacPackProgressReporting.self)
        connection.resume()
        return true
    }

    private static func loadClientRequirement() -> String {
        let candidates = [
            "/Library/Application Support/MacPack/client.requirement",
            Bundle.main.url(forResource: "ClientRequirement", withExtension: "txt")?.path
        ].compactMap { $0 }

        for path in candidates {
            if let requirement = try? String(contentsOfFile: path, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !requirement.isEmpty {
                return requirement
            }
        }

        return "identifier \"\(MacPackConstants.appBundleIdentifier)\""
    }
}
