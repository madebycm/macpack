import Foundation
import MacPackShared

struct InstallerRunResult {
    let exitCode: Int
    let summary: String
}

enum InstallerRunner {
    static func run(
        packagePath: String,
        progress: @escaping (InstallerProgressEvent) -> Void
    ) -> InstallerRunResult {
        guard geteuid() == 0 else {
            return InstallerRunResult(
                exitCode: Int(EX_NOPERM),
                summary: "The installer service is not running as root."
            )
        }

        let validatedPath: String
        do {
            validatedPath = try PackagePathValidator.validatedPath(packagePath)
        } catch {
            return InstallerRunResult(
                exitCode: Int(EX_NOINPUT),
                summary: error.localizedDescription
            )
        }

        let installerArguments = ["-verboseR", "-pkg", validatedPath, "-target", "/"]
        let result = invoke(
            executablePath: "/usr/sbin/installer",
            arguments: installerArguments,
            progress: progress
        )
        guard result.exitCode != 0, shouldRetryWithRosetta(result) else {
            return result
        }

        // Old Packages.app distributions gate on an Intel-only CPU check that
        // fails when installer runs natively on Apple Silicon; the same package
        // installs cleanly when installer runs as x86_64 under Rosetta.
        progress(InstallerProgressEvent(message: "Retrying under Rosetta…"))
        let retried = invoke(
            executablePath: "/usr/bin/arch",
            arguments: ["-x86_64", "/usr/sbin/installer"] + installerArguments,
            progress: progress
        )
        return retried.exitCode == 0 ? retried : result
    }

    private static func invoke(
        executablePath: String,
        arguments: [String],
        progress: @escaping (InstallerProgressEvent) -> Void
    ) -> InstallerRunResult {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.standardOutput = output
        process.standardError = output
        process.environment = [
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"
        ]

        do {
            try process.run()
        } catch {
            return InstallerRunResult(
                exitCode: Int(EX_OSERR),
                summary: "Could not start macOS Installer: \(error.localizedDescription)"
            )
        }

        var pending = Data()
        var recentLines: [String] = []

        while true {
            let data = output.fileHandleForReading.availableData
            guard !data.isEmpty else { break }
            pending.append(data)
            consumeLines(
                from: &pending,
                recentLines: &recentLines,
                progress: progress
            )
        }

        if !pending.isEmpty, let tail = String(data: pending, encoding: .utf8) {
            consume(
                line: tail,
                recentLines: &recentLines,
                progress: progress
            )
        }

        process.waitUntilExit()
        let code = Int(process.terminationStatus)
        let fallback = code == 0 ? "Installed" : "macOS Installer exited with status \(code)."
        let summary = recentLines.last(where: { !$0.isEmpty }) ?? fallback
        return InstallerRunResult(exitCode: code, summary: summary)
    }

    private static func shouldRetryWithRosetta(_ result: InstallerRunResult) -> Bool {
        // Rosetta only exists on Apple Silicon, so this also excludes Intel Macs.
        guard FileManager.default.fileExists(
            atPath: "/Library/Apple/usr/share/rosetta/rosetta"
        ) else { return false }

        // Packages.app templates blank the failure message to a single space,
        // leaving a bare "installer: Error -"; other gate failures say the
        // package cannot be installed on this computer.
        if result.summary == "installer: Error -" { return true }
        if result.summary.contains("cannot be installed") { return true }
        return false
    }

    private static func consumeLines(
        from buffer: inout Data,
        recentLines: inout [String],
        progress: (InstallerProgressEvent) -> Void
    ) {
        let newline = Data([0x0A])
        while let range = buffer.range(of: newline) {
            let lineData = buffer[..<range.lowerBound]
            buffer.removeSubrange(...range.lowerBound)
            if let line = String(data: lineData, encoding: .utf8) {
                consume(line: line, recentLines: &recentLines, progress: progress)
            }
        }
    }

    private static func consume(
        line: String,
        recentLines: inout [String],
        progress: (InstallerProgressEvent) -> Void
    ) {
        let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        recentLines.append(clean)
        if recentLines.count > 20 {
            recentLines.removeFirst(recentLines.count - 20)
        }

        if let event = InstallerOutputParser.event(from: clean) {
            progress(event)
        }
    }
}
