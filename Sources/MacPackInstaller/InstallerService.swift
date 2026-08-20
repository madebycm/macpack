import Foundation
import MacPackShared

final class InstallerService: NSObject, MacPackInstalling {
    private static let installQueue = DispatchQueue(
        label: "com.macpack.installer.queue",
        qos: .userInitiated
    )

    func ping(withReply reply: @escaping (String) -> Void) {
        let connection = NSXPCConnection.current()
        HelperLifecycle.shared.beginInstall()
        reply(geteuid() == 0 ? "ready" : "not-root")
        connection?.scheduleSendBarrierBlock {
            HelperLifecycle.shared.finishInstall()
        }
    }

    func installPackage(
        atPath path: String,
        requestID: String,
        withReply reply: @escaping (Int, String) -> Void
    ) {
        let connection = NSXPCConnection.current()
        let reporter = connection?.remoteObjectProxyWithErrorHandler { _ in }
            as? MacPackProgressReporting

        HelperLifecycle.shared.beginInstall()
        Self.installQueue.async {
            reporter?.installerDidUpdate(
                requestID: requestID,
                percent: -1,
                message: "Preparing…"
            )

            let result = InstallerRunner.run(packagePath: path) { event in
                reporter?.installerDidUpdate(
                    requestID: requestID,
                    percent: event.percent ?? -1,
                    message: event.message ?? ""
                )
            }

            reply(result.exitCode, result.summary)
            connection?.scheduleSendBarrierBlock {
                HelperLifecycle.shared.finishInstall()
            }
        }
    }
}
