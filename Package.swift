// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MacPack",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MacPack", targets: ["MacPack"]),
        .executable(name: "MacPackInstaller", targets: ["MacPackInstaller"]),
        .executable(name: "MacPackSelfTest", targets: ["MacPackSelfTest"])
    ],
    targets: [
        .target(
            name: "MacPackShared",
            path: "Sources/MacPackShared"
        ),
        .executableTarget(
            name: "MacPack",
            dependencies: ["MacPackShared"],
            path: "Sources/MacPack",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        ),
        .executableTarget(
            name: "MacPackInstaller",
            dependencies: ["MacPackShared"],
            path: "Sources/MacPackInstaller"
        ),
        .executableTarget(
            name: "MacPackSelfTest",
            dependencies: ["MacPackShared"],
            path: "SelfTests",
            exclude: ["test_vst_hook.py"]
        )
    ],
    swiftLanguageModes: [.v5]
)
