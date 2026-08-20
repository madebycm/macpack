import Foundation

final class HelperLifecycle {
    static let shared = HelperLifecycle()

    private let queue = DispatchQueue(label: "com.macpack.installer.lifecycle")
    private var activeInstalls = 0
    private var pendingExit: DispatchWorkItem?

    private init() {}

    func beginInstall() {
        queue.sync {
            pendingExit?.cancel()
            pendingExit = nil
            activeInstalls += 1
        }
    }

    func finishInstall() {
        queue.async { [self] in
            activeInstalls = max(0, activeInstalls - 1)
            guard activeInstalls == 0 else { return }

            let work = DispatchWorkItem {
                Darwin.exit(EXIT_SUCCESS)
            }
            pendingExit = work
            queue.asyncAfter(deadline: .now() + 2, execute: work)
        }
    }
}
