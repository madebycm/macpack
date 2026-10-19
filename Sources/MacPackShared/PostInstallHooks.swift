import Foundation

public enum MacPackInstallStage {
    public static let installing = "installing"
    public static let postProcessing = "post-processing"
}

public struct PostInstallHookManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let hooks: [PostInstallHookDescriptor]

    public init(schemaVersion: Int, hooks: [PostInstallHookDescriptor]) {
        self.schemaVersion = schemaVersion
        self.hooks = hooks
    }
}

public struct PostInstallHookDescriptor: Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let progressMessage: String
    public let phase: PostInstallHookPhase
    public let runner: PostInstallHookRunnerKind
    public let entrypoint: String
    public let timeoutSeconds: Int

    public init(
        id: String,
        displayName: String,
        progressMessage: String,
        phase: PostInstallHookPhase,
        runner: PostInstallHookRunnerKind,
        entrypoint: String,
        timeoutSeconds: Int
    ) {
        self.id = id
        self.displayName = displayName
        self.progressMessage = progressMessage
        self.phase = phase
        self.runner = runner
        self.entrypoint = entrypoint
        self.timeoutSeconds = timeoutSeconds
    }
}

public enum PostInstallHookPhase: String, Codable, Sendable {
    case afterSuccessfulInstall
}

public enum PostInstallHookRunnerKind: String, Codable, Sendable {
    case python3
}

public enum PostInstallHookOutput {
    public static func summary(displayName: String, output: String) -> String {
        let lines = output
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        let moved = lines.last(where: {
            $0.hasPrefix("Moved ") && $0.contains("plugin(s)")
        })
        let freshInstall = lines.last(where: {
            $0.hasPrefix("MacPack fresh-install VST3 cleanup: moved ")
        })

        if let moved, let freshInstall {
            return "\(displayName): \(moved.lowercasedFirst); \(freshInstall.afterColon)"
        }
        if let freshInstall {
            return "\(displayName): \(freshInstall.afterColon)"
        }
        if let moved {
            return "\(displayName): \(moved.lowercasedFirst)"
        }
        if lines.contains(where: { $0.hasPrefix("Nothing to clean.") }) {
            return "\(displayName): nothing to clean"
        }
        if let warning = lines.last(where: {
            $0.hasPrefix("Found duplicates but failed")
                || $0.hasPrefix("Failed to move")
        }) {
            return "\(displayName): \(warning.lowercasedFirst)"
        }
        return "\(displayName) complete"
    }
}

private extension String {
    var lowercasedFirst: String {
        guard let first else { return self }
        return first.lowercased() + String(dropFirst())
    }

    var afterColon: String {
        guard let colon = firstIndex(of: ":") else { return self }
        return self[index(after: colon)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
