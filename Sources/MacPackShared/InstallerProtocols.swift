import Foundation

@objc public protocol MacPackProgressReporting {
    func installerDidUpdate(
        requestID: String,
        stage: String,
        percent: Double,
        message: String
    )
}

@objc public protocol MacPackInstalling {
    func ping(withReply reply: @escaping (String) -> Void)

    func installPackage(
        atPath path: String,
        requestID: String,
        withReply reply: @escaping (Int, String) -> Void
    )
}

public struct InstallerProgressEvent: Equatable, Sendable {
    public let percent: Double?
    public let message: String?

    public init(percent: Double? = nil, message: String? = nil) {
        self.percent = percent
        self.message = message
    }
}

public enum InstallerOutputParser {
    public static func event(from rawLine: String) -> InstallerProgressEvent? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }

        if let range = line.range(of: "installer:%") {
            let value = line[range.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let percent = Double(value) {
                return InstallerProgressEvent(percent: min(max(percent / 100, 0), 1))
            }
        }

        for marker in ["installer:PHASE:", "installer:STATUS:", "installer:NOTE:"] {
            if let range = line.range(of: marker) {
                let message = line[range.upperBound...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !message.isEmpty {
                    return InstallerProgressEvent(message: message)
                }
            }
        }

        return nil
    }
}

public enum PackagePathValidator {
    public static let acceptedExtensions = ["pkg", "mpkg"]

    public static func validatedPath(
        _ path: String,
        fileManager: FileManager = .default
    ) throws -> String {
        guard path.hasPrefix("/") else {
            throw ValidationError.notAbsolute
        }

        let resolvedURL = URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let ext = resolvedURL.pathExtension.lowercased()
        guard acceptedExtensions.contains(ext) else {
            throw ValidationError.unsupportedExtension
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolvedURL.path, isDirectory: &isDirectory) else {
            throw ValidationError.notFound
        }

        return resolvedURL.path
    }

    public enum ValidationError: LocalizedError, Equatable {
        case notAbsolute
        case unsupportedExtension
        case notFound

        public var errorDescription: String? {
            switch self {
            case .notAbsolute:
                return "The package path must be absolute."
            case .unsupportedExtension:
                return "MacPack accepts .pkg and .mpkg installers."
            case .notFound:
                return "The package no longer exists."
            }
        }
    }
}

public enum OpenPackagePath {
    public static func root(
        from openPath: String,
        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)
    ) -> String? {
        var searchStart = openPath.startIndex

        while searchStart < openPath.endIndex {
            let packageRange = openPath.range(
                of: #"\.m?pkg(?:/|$)"#,
                options: [.regularExpression, .caseInsensitive],
                range: searchStart..<openPath.endIndex
            )
            guard let packageRange else { return nil }

            let endsWithSlash = openPath[packageRange].last == "/"
            let end = endsWithSlash
                ? openPath.index(before: packageRange.upperBound)
                : packageRange.upperBound
            let candidate = String(openPath[..<end])
            if fileExists(candidate) {
                return URL(fileURLWithPath: candidate)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                    .path
            }
            searchStart = packageRange.upperBound
        }

        return nil
    }
}
