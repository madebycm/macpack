import AppKit
import Darwin
import Foundation
import MacPackShared

/// Installer.app claims package types with Apple's private
/// `apple-default-no-override` LaunchServices flag. macOS therefore ignores
/// third-party default-handler requests for .pkg files. This observer turns
/// Installer's launch into the routing event without using an event tap,
/// Accessibility, Apple Events, or a polling process while idle.
final class InstallerInterceptor {
    private let workspace = NSWorkspace.shared
    private let inspectionQueue = DispatchQueue(
        label: "com.macpack.installer-interceptor",
        qos: .userInitiated
    )
    private let stateLock = NSLock()
    private var observerTokens: [NSObjectProtocol] = []
    private var inspectingPIDs = Set<pid_t>()
    private var bypassedPaths = Set<String>()
    private let onPackages: ([URL]) -> Void

    init(onPackages: @escaping ([URL]) -> Void) {
        self.onPackages = onPackages
    }

    deinit {
        stop()
    }

    /// Lets the next Installer launch for this exact package path proceed
    /// untouched. Used when a staged copy failed and the package was handed
    /// back to Installer.app, so the reopened Installer is not intercepted
    /// into the same failing staging attempt again. The bypass is consumed
    /// by one matching inspection, so a later manual open is handled normally.
    func bypass(path: String) {
        stateLock.lock()
        bypassedPaths.insert(path)
        stateLock.unlock()
    }

    func start() {
        guard observerTokens.isEmpty else { return }
        let center = workspace.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            observerTokens.append(
                center.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] notification in
                    self?.inspect(notification: notification)
                }
            )
        }
    }

    func stop() {
        let center = workspace.notificationCenter
        observerTokens.forEach(center.removeObserver)
        observerTokens.removeAll()
    }

    private func inspect(notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
              app.bundleIdentifier == "com.apple.installer" else { return }

        let pid = app.processIdentifier
        stateLock.lock()
        let inserted = inspectingPIDs.insert(pid).inserted
        stateLock.unlock()
        guard inserted else { return }

        // Hide before Installer creates visible chrome. If it was launched
        // manually without a package, it is restored after the short probe.
        _ = app.hide()

        inspectionQueue.async { [weak self] in
            guard let self else { return }
            let paths = findPackagePaths(processID: pid)
            let deferToInstaller = shouldDeferToInstaller(paths: paths)

            stateLock.lock()
            inspectingPIDs.remove(pid)
            stateLock.unlock()

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if paths.isEmpty || deferToInstaller {
                    if !app.isTerminated { _ = app.unhide() }
                    return
                }

                _ = app.terminate()
                onPackages(paths.map { URL(fileURLWithPath: $0) })

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if !app.isTerminated { _ = app.forceTerminate() }
                }
            }
        }
    }

    private func findPackagePaths(processID: pid_t) -> [String] {
        var discovered = Set<String>()
        var unchangedPolls = 0

        // Finder can deliver several package URLs to one Installer process in
        // consecutive Apple Events. Keep the process hidden while its open-file
        // set settles so terminating it for the first URL cannot drop the rest.
        for _ in 0..<30 {
            let paths = openFilePaths(processID: processID)
                .compactMap { OpenPackagePath.root(from: $0) }

            let previousCount = discovered.count
            discovered.formUnion(paths)
            if discovered.isEmpty {
                unchangedPolls = 0
            } else if discovered.count == previousCount {
                unchangedPolls += 1
                if unchangedPolls >= 8 { break }
            } else {
                unchangedPolls = 0
            }

            usleep(50_000)
        }

        return discovered.sorted()
    }

    /// Decides whether Installer must keep these packages instead of MacPack
    /// taking over. Two cases: the package was explicitly bypassed because a
    /// staging failure already handed it back once, or it sits inside another
    /// sandboxed app's container, which macOS app-data protection makes
    /// unreadable to MacPack — intercepting it would only kill the hosting
    /// app's own update flow.
    private func shouldDeferToInstaller(paths: [String]) -> Bool {
        guard !paths.isEmpty else { return false }

        stateLock.lock()
        let bypassed = paths.allSatisfy { bypassedPaths.contains($0) }
        if bypassed {
            paths.forEach { bypassedPaths.remove($0) }
        }
        stateLock.unlock()
        if bypassed { return true }

        return paths.contains { PackageOrigin.isInsideForeignAppContainer($0) }
    }

    private func openFilePaths(processID: pid_t) -> [String] {
        if let paths = openFilePathsViaLibproc(processID: processID) {
            let containsPackage = paths.contains {
                OpenPackagePath.root(from: $0) != nil
            }
            if containsPackage { return paths }
        }
        return openFilePathsViaLSOF(processID: processID)
    }

    /// Reads Installer's vnode descriptors in-process. This avoids repeatedly
    /// spawning `lsof` during the sub-second capture window.
    private func openFilePathsViaLibproc(processID: pid_t) -> [String]? {
        let descriptorSize = MemoryLayout<proc_fdinfo>.stride
        let requiredBytes = proc_pidinfo(
            processID,
            PROC_PIDLISTFDS,
            0,
            nil,
            0
        )
        guard requiredBytes > 0 else { return nil }

        // Leave headroom for descriptors opened between the sizing and read
        // calls. A later poll captures anything that arrives after this read.
        let capacity = (Int(requiredBytes) / descriptorSize) + 32
        var descriptors = [proc_fdinfo](
            repeating: proc_fdinfo(),
            count: capacity
        )
        let availableBytes = descriptors.withUnsafeMutableBytes { buffer in
            proc_pidinfo(
                processID,
                PROC_PIDLISTFDS,
                0,
                buffer.baseAddress,
                Int32(buffer.count)
            )
        }
        guard availableBytes > 0 else { return nil }

        let descriptorCount = min(
            Int(availableBytes) / descriptorSize,
            descriptors.count
        )
        var paths: [String] = []
        var inspectedVNode = false

        for descriptor in descriptors.prefix(descriptorCount)
        where descriptor.proc_fdtype == PROX_FDTYPE_VNODE {
            var vnode = vnode_fdinfowithpath()
            let bytesRead = withUnsafeMutablePointer(to: &vnode) { pointer in
                proc_pidfdinfo(
                    processID,
                    descriptor.proc_fd,
                    PROC_PIDFDVNODEPATHINFO,
                    pointer,
                    Int32(MemoryLayout<vnode_fdinfowithpath>.size)
                )
            }
            guard bytesRead == MemoryLayout<vnode_fdinfowithpath>.size else {
                continue
            }
            inspectedVNode = true

            let path = withUnsafePointer(to: &vnode.pvip.vip_path) { pointer in
                pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(MAXPATHLEN)
                ) {
                    String(cString: $0)
                }
            }
            if !path.isEmpty { paths.append(path) }
        }

        // A process with vnode descriptors but none readable is usually a
        // permissions boundary. Fall back to the established system tool.
        return inspectedVNode ? paths : nil
    }

    private func openFilePathsViaLSOF(processID: pid_t) -> [String] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-Fn", "-p", String(processID)]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let text = String(data: data, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { line in
                guard line.first == "n" else { return nil }
                return String(line.dropFirst())
            }
        } catch {
            return []
        }
    }

}
