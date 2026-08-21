import Darwin
import Foundation
import MacPackShared

private var failures: [String] = []

private func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    if condition() {
        print("✓ \(name)")
    } else {
        failures.append(name)
        print("✗ \(name)")
    }
}

check(
    InstallerOutputParser.event(from: "installer:%42.500000")
        == InstallerProgressEvent(percent: 0.425),
    "parses installer percentage"
)
check(
    InstallerOutputParser.event(from: "installer:%120")
        == InstallerProgressEvent(percent: 1),
    "clamps installer percentage"
)
check(
    InstallerOutputParser.event(from: "installer:PHASE:Preparing the disk…")
        == InstallerProgressEvent(message: "Preparing the disk…"),
    "parses installer phase"
)
check(
    InstallerOutputParser.event(from: "installer: Package name is Example") == nil,
    "ignores ordinary verbose output"
)

let hookManifestJSON = #"""
{
  "schemaVersion": 1,
  "hooks": [
    {
      "id": "vst-cleanup",
      "displayName": "VST cleanup",
      "progressMessage": "Cleaning plug-in duplicates…",
      "phase": "afterSuccessfulInstall",
      "runner": "python3",
      "entrypoint": "VSTCleanup/macpack_hook.py",
      "timeoutSeconds": 900
    }
  ]
}
"""#.data(using: .utf8)!

do {
    let manifest = try JSONDecoder().decode(
        PostInstallHookManifest.self,
        from: hookManifestJSON
    )
    check(
        manifest.hooks.first?.phase == .afterSuccessfulInstall,
        "decodes a built-in post-install hook manifest"
    )
    check(
        manifest.hooks.first?.runner == .python3,
        "decodes the allowlisted Python hook runner"
    )
} catch {
    failures.append("decodes a built-in post-install hook manifest")
    print("✗ decodes a built-in post-install hook manifest: \(error)")
}

check(
    PostInstallHookOutput.summary(
        displayName: "VST cleanup",
        output: "Moved 12 plugin(s) (1.3 GB)\n"
    ) == "VST cleanup: moved 12 plugin(s) (1.3 GB)",
    "summarizes moved plug-ins"
)
check(
    PostInstallHookOutput.summary(
        displayName: "VST cleanup",
        output: "Nothing to clean. No duplicate formats found.\n"
    ) == "VST cleanup: nothing to clean",
    "summarizes an empty cleanup"
)
check(
    PostInstallHookOutput.summary(
        displayName: "VST cleanup",
        output: """
        Moved 2 plugin(s) (151.6 MB)
        MacPack fresh-install VST3 cleanup: moved 1 plugin(s) (25.0 MB)
        """
    ) == "VST cleanup: moved 2 plugin(s) (151.6 MB); moved 1 plugin(s) (25.0 MB)",
    "combines canonical and fresh-install cleanup summaries"
)

let primaryHUDOrigin = HUDScreenPlacement.origin(
    visibleFrame: CGRect(x: 0, y: 0, width: 1_880, height: 1_050),
    windowSize: CGSize(width: 218, height: 40),
    margin: 10
)
check(
    primaryHUDOrigin == CGPoint(x: 1_652, y: 1_000),
    "keeps the HUD inside a visible frame reduced by the Dock"
)

let leftScreenFrame = CGRect(x: -1_920, y: -120, width: 1_920, height: 1_080)
let leftHUDOrigin = HUDScreenPlacement.origin(
    visibleFrame: leftScreenFrame,
    windowSize: CGSize(width: 218, height: 40),
    margin: 10
)
check(
    leftHUDOrigin.x >= leftScreenFrame.minX
        && leftHUDOrigin.x + 218 <= leftScreenFrame.maxX
        && leftHUDOrigin.y >= leftScreenFrame.minY
        && leftHUDOrigin.y + 40 <= leftScreenFrame.maxY,
    "clamps the HUD on a negative-coordinate secondary display"
)
check(
    OpenPackagePath.root(
        from: "/Users/producer/Ümlaut.pkg/Contents/distribution",
        fileExists: { $0 == "/Users/producer/Ümlaut.pkg" }
    ) == "/Users/producer/Ümlaut.pkg",
    "finds the outer package from an open file descriptor"
)
check(
    OpenPackagePath.root(
        from: "/Users/producer/session.wav",
        fileExists: { _ in true }
    ) == nil,
    "ignores non-package file descriptors"
)

let packageURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("macpack-self-test-\(UUID().uuidString).pkg")
do {
    try Data().write(to: packageURL)
    defer { try? FileManager.default.removeItem(at: packageURL) }
    let validatedPath = try PackagePathValidator.validatedPath(packageURL.path)
    check(
        validatedPath == packageURL.path,
        "accepts an existing flat package"
    )
} catch {
    failures.append("accepts an existing flat package")
    print("✗ accepts an existing flat package: \(error)")
}

do {
    _ = try PackagePathValidator.validatedPath("Example.pkg")
    check(false, "rejects a relative path")
} catch {
    check(
        error as? PackagePathValidator.ValidationError == .notAbsolute,
        "rejects a relative path"
    )
}

let zipURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("macpack-self-test-\(UUID().uuidString).zip")
do {
    try Data().write(to: zipURL)
    defer { try? FileManager.default.removeItem(at: zipURL) }
    do {
        _ = try PackagePathValidator.validatedPath(zipURL.path)
        check(false, "rejects an unsupported extension")
    } catch {
        check(
            error as? PackagePathValidator.ValidationError == .unsupportedExtension,
            "rejects an unsupported extension"
        )
    }
} catch {
    failures.append("rejects an unsupported extension")
    print("✗ prepares unsupported-extension fixture: \(error)")
}

if failures.isEmpty {
    print("All MacPack self-tests passed.")
    exit(EXIT_SUCCESS)
}

print("\(failures.count) self-test(s) failed: \(failures.joined(separator: ", "))")
exit(EXIT_FAILURE)
