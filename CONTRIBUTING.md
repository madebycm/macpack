# Contributing

Keep the common path calm: opening a package should enqueue it immediately, reveal only compact status, and require no interaction unless the package or macOS genuinely blocks.

Before opening a pull request:

```bash
swift run MacPackSelfTest
python3 SelfTests/test_vst_hook.py
(cd Resources/PostHooks/VSTCleanup && shasum -a 256 -c SNAPSHOT.sha256)
./scripts/build-app.sh --production
./scripts/build-pkg.sh --skip-build
codesign --verify --deep --strict --verbose=2 build/MacPack.app
```

Changes to XPC protocols, launchd registration, package-path validation, signing requirements, or Installer arguments should explain their privilege impact in the pull request. Never replace typed `Process.arguments` with shell interpolation.

The VST cleaner snapshot must be updated only from its canonical source directory:

```bash
./scripts/sync-vst-hook.sh /path/to/vstcleaner
```

The sync command copies only the eight allowlisted source files and regenerates their checksum manifest. Never vendor `.cache`, credentials, or local recovery directories.

The public minimum is macOS 13. Keep the UI an accessory app: no Dock icon and no menu-bar status item.
