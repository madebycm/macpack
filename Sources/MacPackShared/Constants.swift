import Foundation

public enum MacPackConstants {
    public static let appBundleIdentifier = "com.macpack.app"
    public static let helperMachService = "com.macpack.installer"
    public static let helperExecutableName = "MacPackInstaller"
    public static let helperPlistName = "com.macpack.installer.plist"
    public static let legacyHelperPath = "/Library/PrivilegedHelperTools/com.macpack.installer"
    public static let legacyPlistPath = "/Library/LaunchDaemons/com.macpack.installer.plist"

    public static let packageTypeIdentifiers = [
        "com.apple.installer-package",
        "com.apple.installer-meta-package",
        "com.apple.installer-package-archive"
    ]
}
