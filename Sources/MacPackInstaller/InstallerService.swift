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
        let userContext = connection.flatMap { PostInstallUserContext(connection: $0) }
        let reporter = connection?.remoteObjectProxyWithErrorHandler { _ in }
            as? MacPackProgressReporting

        HelperLifecycle.shared.beginInstall()
        Self.installQueue.async {
            reporter?.installerDidUpdate(
                requestID: requestID,
                stage: MacPackInstallStage.installing,
                percent: -1,
                message: "Preparing…"
            )

            let result = InstallerRunner.run(packagePath: path) { event in
                reporter?.installerDidUpdate(
                    requestID: requestID,
                    stage: MacPackInstallStage.installing,
                    percent: event.percent ?? -1,
                    message: event.message ?? ""
                )
            }

            guard result.exitCode == 0 else {
                reply(result.exitCode, result.summary)
                connection?.scheduleSendBarrierBlock {
                    HelperLifecycle.shared.finishInstall()
                }
                return
            }

            let summary = PostInstallHookRunner.runAfterSuccessfulInstall(
                packagePath: path,
                userContext: userContext
            ) { message in
                reporter?.installerDidUpdate(
                    requestID: requestID,
                    stage: MacPackInstallStage.postProcessing,
                    percent: -1,
                    message: message
                )
            }

            reply(Int(EXIT_SUCCESS), summary)
            connection?.scheduleSendBarrierBlock {
                HelperLifecycle.shared.finishInstall()
            }
        }
    }
}
