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
