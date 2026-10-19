import Darwin
import Foundation
import MacPackShared

struct PostInstallUserContext {
    let uid: uid_t
    let gid: gid_t
    let userName: String
    let homeDirectory: String

    init?(connection: NSXPCConnection) {
        let uid = connection.effectiveUserIdentifier
        guard uid != 0, let record = getpwuid(uid) else { return nil }

        let userName = String(cString: record.pointee.pw_name)
        let homeDirectory = String(cString: record.pointee.pw_dir)
        guard !userName.isEmpty, homeDirectory.hasPrefix("/") else { return nil }

        self.uid = uid
        gid = connection.effectiveGroupIdentifier
        self.userName = userName
        self.homeDirectory = homeDirectory
    }
}

enum PostInstallHookRunner {
    private static let hookRoot = URL(
        fileURLWithPath: "/Applications/MacPack.app/Contents/Resources/PostHooks",
        isDirectory: true
    )
    private static let manifestName = "hooks.json"
    private static let logRoot = URL(
        fileURLWithPath: "/Library/Logs/MacPack",
        isDirectory: true
    )
    private static let maximumOutputBytes = 4 * 1_024 * 1_024

    static func runAfterSuccessfulInstall(
        packagePath: String,
        userContext: PostInstallUserContext?,
        progress: (String) -> Void
    ) -> String {
        let manifest: PostInstallHookManifest
        do {
            manifest = try loadManifest()
        } catch {
            return "Installed · cleanup unavailable: \(error.localizedDescription)"
        }

        let hooks = manifest.hooks.filter { $0.phase == .afterSuccessfulInstall }
        guard !hooks.isEmpty else { return "Installed" }
        guard let userContext else {
            return "Installed · cleanup skipped: login user unavailable"
        }

        var summaries: [String] = []
        for hook in hooks {
            progress(hook.progressMessage)
            let outcome = run(
                hook: hook,
                packagePath: packagePath,
                userContext: userContext
            )
            summaries.append(outcome.summary)
        }

        restoreRecoveryOwnership(for: userContext)
        return (["Installed"] + summaries).joined(separator: " · ")
    }

    private static func loadManifest() throws -> PostInstallHookManifest {
        try validateSecureTree(at: hookRoot)

        let manifestURL = hookRoot.appendingPathComponent(manifestName, isDirectory: false)
        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw HookError.invalidManifest("could not read \(manifestName)")
        }

        let manifest: PostInstallHookManifest
        do {
            manifest = try JSONDecoder().decode(PostInstallHookManifest.self, from: data)
        } catch {
            throw HookError.invalidManifest("could not decode \(manifestName)")
        }

        guard manifest.schemaVersion == 1 else {
            throw HookError.invalidManifest("unsupported schema version")
        }

        var identifiers: Set<String> = []
        for hook in manifest.hooks {
            guard hook.id.range(
                of: #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#,
                options: .regularExpression
            ) != nil else {
                throw HookError.invalidManifest("invalid hook identifier")
            }
            guard identifiers.insert(hook.id).inserted else {
                throw HookError.invalidManifest("duplicate hook identifier")
            }
            guard !hook.displayName.isEmpty, !hook.progressMessage.isEmpty else {
                throw HookError.invalidManifest("hook labels cannot be empty")
            }
            _ = try entrypointURL(for: hook)
        }

        return manifest
    }

    private static func run(
        hook: PostInstallHookDescriptor,
        packagePath: String,
        userContext: PostInstallUserContext
    ) -> HookOutcome {
        let entrypoint: URL
        do {
            entrypoint = try entrypointURL(for: hook)
        } catch {
            return HookOutcome(
                summary: "\(hook.displayName) warning: \(error.localizedDescription)"
            )
        }

        let recoveryURL = recoveryURL(for: userContext)
        let process = Process()
        let outputPipe = Pipe()
        let collector = OutputCollector(maximumBytes: maximumOutputBytes)
        let readerFinished = DispatchSemaphore(value: 0)
        let processFinished = DispatchSemaphore(value: 0)

        switch hook.runner {
        case .python3:
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [entrypoint.path]
        }

        process.currentDirectoryURL = entrypoint.deletingLastPathComponent()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        process.environment = environment(
            hook: hook,
            packagePath: packagePath,
            userContext: userContext,
            recoveryURL: recoveryURL
        )
        process.terminationHandler = { _ in
            processFinished.signal()
        }

        DispatchQueue.global(qos: .utility).async {
            collector.read(from: outputPipe.fileHandleForReading)
            readerFinished.signal()
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForWriting.closeFile()
            _ = readerFinished.wait(timeout: .now() + 2)
            let message = "Could not start hook: \(error.localizedDescription)"
            writeLog(hook: hook, output: message)
            return HookOutcome(summary: "\(hook.displayName) warning: could not start")
        }

        let timeout = min(max(hook.timeoutSeconds, 1), 3_600)
        var timedOut = false
        if processFinished.wait(timeout: .now() + .seconds(timeout)) == .timedOut {
            timedOut = true
            process.terminate()
            if processFinished.wait(timeout: .now() + 2) == .timedOut {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }

        process.waitUntilExit()
        outputPipe.fileHandleForWriting.closeFile()
        _ = readerFinished.wait(timeout: .now() + 5)

        var output = collector.output
        if collector.wasTruncated {
            output += "\n[MacPack truncated hook output after \(maximumOutputBytes) bytes.]\n"
        }
        writeLog(hook: hook, output: output)

        if timedOut {
            return HookOutcome(summary: "\(hook.displayName) warning: timed out")
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            return HookOutcome(
                summary: "\(hook.displayName) warning: failed (see /Library/Logs/MacPack)"
            )
        }

        return HookOutcome(
            summary: PostInstallHookOutput.summary(
                displayName: hook.displayName,
                output: output
            )
        )
    }

    private static func environment(
        hook: PostInstallHookDescriptor,
        packagePath: String,
        userContext: PostInstallUserContext,
        recoveryURL: URL
    ) -> [String: String] {
        [
            "HOME": userContext.homeDirectory,
            "USER": userContext.userName,
            "LOGNAME": userContext.userName,
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": "/tmp",
            "PYTHONDONTWRITEBYTECODE": "1",
            "PYTHONNOUSERSITE": "1",
            "MACPACK_HOOK_ID": hook.id,
            "MACPACK_PACKAGE_PATH": packagePath,
            "MACPACK_LOGIN_USER": userContext.userName,
            "MACPACK_CLEANED_PLUGIN_PATH": recoveryURL.path
        ]
    }

    private static func entrypointURL(
        for hook: PostInstallHookDescriptor
    ) throws -> URL {
        guard !hook.entrypoint.hasPrefix("/"),
              hook.entrypoint.split(separator: "/").allSatisfy({
                  $0 != "." && $0 != ".." && !$0.isEmpty
              }) else {
            throw HookError.invalidManifest("entrypoint must be a relative path")
        }

        let url = hookRoot
            .appendingPathComponent(hook.entrypoint, isDirectory: false)
            .standardizedFileURL
        guard url.path.hasPrefix(hookRoot.path + "/"),
              url.pathExtension == "py" else {
            throw HookError.invalidManifest("entrypoint is outside PostHooks")
        }
        return url
    }

    private static func validateSecureTree(at root: URL) throws {
        var pending = [root]
        while let url = pending.popLast() {
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0 else {
                throw HookError.insecureResources("missing \(url.lastPathComponent)")
            }

            let fileType = metadata.st_mode & mode_t(S_IFMT)
            guard fileType == mode_t(S_IFDIR) || fileType == mode_t(S_IFREG) else {
                throw HookError.insecureResources("links and special files are not allowed")
            }
            guard metadata.st_uid == 0,
                  metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0 else {
                throw HookError.insecureResources("resources must be root-owned and read-only")
            }

            if fileType == mode_t(S_IFDIR) {
                let children: [URL]
                do {
                    children = try FileManager.default.contentsOfDirectory(
                        at: url,
                        includingPropertiesForKeys: nil,
                        options: []
                    )
                } catch {
                    throw HookError.insecureResources("could not inspect hook resources")
                }
                pending.append(contentsOf: children)
            }
        }
    }

    private static func recoveryURL(for userContext: PostInstallUserContext) -> URL {
        URL(fileURLWithPath: userContext.homeDirectory, isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("MacPack", isDirectory: true)
            .appendingPathComponent("Cleaned Plugins", isDirectory: true)
    }

    private static func restoreRecoveryOwnership(for userContext: PostInstallUserContext) {
        let root = recoveryURL(for: userContext)
        guard root.path.hasPrefix(userContext.homeDirectory + "/Library/Application Support/MacPack/") else {
            return
        }

        var pending = [root]
        while let url = pending.popLast() {
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0 else { continue }
            let fileType = metadata.st_mode & mode_t(S_IFMT)

            if fileType == mode_t(S_IFDIR) {
                let children = try? FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: nil,
                    options: []
                )
                pending.append(contentsOf: children ?? [])
            }
            _ = lchown(url.path, userContext.uid, userContext.gid)
        }
    }

    private static func writeLog(hook: PostInstallHookDescriptor, output: String) {
        do {
            try FileManager.default.createDirectory(
                at: logRoot,
                withIntermediateDirectories: true
            )
            _ = chmod(logRoot.path, 0o755)

            let timestamp = ISO8601DateFormatter().string(from: Date())
            let contents = "MacPack post-install hook: \(hook.id)\nStarted: \(timestamp)\n\n\(output)"
            let logURL = logRoot.appendingPathComponent("\(hook.id).log")
            try Data(contents.utf8).write(to: logURL, options: .atomic)
            _ = chmod(logURL.path, 0o644)
        } catch {
            // Hook execution must not turn a successful package install into a failure.
        }
    }
}

private struct HookOutcome {
    let summary: String
}

private final class OutputCollector: @unchecked Sendable {
    private let maximumBytes: Int
    private let lock = NSLock()
    private var data = Data()
    private(set) var wasTruncated = false

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    var output: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }

    func read(from handle: FileHandle) {
        while true {
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }

            lock.lock()
            let remaining = maximumBytes - data.count
            if remaining > 0 {
                data.append(chunk.prefix(remaining))
            }
            if chunk.count > remaining {
                wasTruncated = true
            }
            lock.unlock()
        }
    }
}

private enum HookError: LocalizedError {
    case invalidManifest(String)
    case insecureResources(String)

    var errorDescription: String? {
        switch self {
        case let .invalidManifest(message):
            return "invalid hook manifest (\(message))"
        case let .insecureResources(message):
            return "unsafe hook resources (\(message))"
        }
    }
}
