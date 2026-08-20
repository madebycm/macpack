# Contributing

Keep the common path calm: opening a package should enqueue it immediately, reveal only compact status, and require no interaction unless the package or macOS genuinely blocks.

Before opening a pull request:

```bash
swift run MacPackSelfTest
./scripts/build-app.sh --production
./scripts/build-pkg.sh --skip-build
codesign --verify --deep --strict --verbose=2 build/MacPack.app
```

Changes to XPC protocols, launchd registration, package-path validation, signing requirements, or Installer arguments should explain their privilege impact in the pull request. Never replace typed `Process.arguments` with shell interpolation.

The public minimum is macOS 13. Keep the UI an accessory app: no Dock icon and no menu-bar status item.
