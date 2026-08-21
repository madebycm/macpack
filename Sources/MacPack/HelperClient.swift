import Foundation
import MacPackShared

final class HelperClient {
    typealias ProgressHandler = (
        _ stage: String,
        _ percent: Double?,
        _ message: String?
    ) -> Void
    typealias CompletionHandler = (_ exitCode: Int, _ summary: String) -> Void

    private var activeRequest: ActiveRequest?

    func ping(completion: @escaping (Bool) -> Void) {
        let connection = makeConnection(exportedObject: nil)
        let gate = CompletionGate()

        connection.invalidationHandler = {
            gate.run { DispatchQueue.main.async { completion(false) } }
        }
        connection.interruptionHandler = {
            gate.run { DispatchQueue.main.async { completion(false) } }
        }
        connection.activate()

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            gate.run {
                connection.invalidate()
                DispatchQueue.main.async { completion(false) }
            }
        }) as? MacPackInstalling else {
            connection.invalidate()
            completion(false)
            return
        }

        proxy.ping { response in
            gate.run {
                connection.invalidate()
                DispatchQueue.main.async { completion(response == "ready") }
            }
        }
    }

    func install(
        job: InstallJob,
        progress: @escaping ProgressHandler,
        completion: @escaping CompletionHandler
    ) {
        let receiver = ProgressReceiver(requestID: job.id.uuidString, handler: progress)
        let connection = makeConnection(exportedObject: receiver)
        let request = ActiveRequest(connection: connection, receiver: receiver)
        activeRequest = request

        let fail: (String) -> Void = { [weak self, weak request] message in
            guard let request else { return }
            request.gate.run {
                request.connection.invalidate()
                DispatchQueue.main.async {
                    if self?.activeRequest === request {
                        self?.activeRequest = nil
                    }
                    completion(Int(EX_UNAVAILABLE), message)
                }
            }
        }

        connection.invalidationHandler = {
            fail("The installer service disconnected.")
        }
        connection.interruptionHandler = {
            fail("The installer service was interrupted.")
        }
        connection.activate()

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            fail("Could not reach the installer service: \(error.localizedDescription)")
        }) as? MacPackInstalling else {
            fail("Could not create the installer service connection.")
            return
        }

        proxy.installPackage(atPath: job.path, requestID: job.id.uuidString) {
            [weak self, weak request] exitCode, summary in
            guard let request else { return }
            request.gate.run {
                request.connection.invalidate()
                DispatchQueue.main.async {
                    if self?.activeRequest === request {
                        self?.activeRequest = nil
                    }
                    completion(exitCode, summary)
                }
            }
        }
    }

    private func makeConnection(exportedObject: Any?) -> NSXPCConnection {
        let connection = NSXPCConnection(
            machServiceName: MacPackConstants.helperMachService,
            options: .privileged
        )
        connection.setCodeSigningRequirement(
            "identifier \"\(MacPackConstants.helperMachService)\""
        )
        connection.remoteObjectInterface = NSXPCInterface(with: MacPackInstalling.self)

        if let exportedObject {
            connection.exportedInterface = NSXPCInterface(with: MacPackProgressReporting.self)
            connection.exportedObject = exportedObject
        }

        return connection
    }
}

private final class ActiveRequest {
    let connection: NSXPCConnection
    let receiver: ProgressReceiver
    let gate = CompletionGate()

    init(connection: NSXPCConnection, receiver: ProgressReceiver) {
        self.connection = connection
        self.receiver = receiver
    }
}

private final class ProgressReceiver: NSObject, MacPackProgressReporting {
    private let requestID: String
    private let handler: HelperClient.ProgressHandler

    init(requestID: String, handler: @escaping HelperClient.ProgressHandler) {
        self.requestID = requestID
        self.handler = handler
    }

    func installerDidUpdate(
        requestID: String,
        stage: String,
        percent: Double,
        message: String
    ) {
        guard requestID == self.requestID else { return }
        DispatchQueue.main.async { [handler] in
            handler(
                stage,
                percent >= 0 ? percent : nil,
                message.isEmpty ? nil : message
            )
        }
    }
}

private final class CompletionGate {
    private let lock = NSLock()
    private var completed = false

    func run(_ action: () -> Void) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        lock.unlock()
        action()
    }
}
