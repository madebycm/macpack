# MacPack

Double-click a `.pkg`. It installs. That is the whole idea.

MacPack replaces the repetitive Installer.app sequence—Continue, Agree, destination, Install, password or Touch ID, then keep/delete—with a hidden serial queue and one tiny corner progress surface. Open more packages while one is running and they line up automatically.

No Dock icon. No menu-bar item. No shell windows. No password prompt per package.

> Status: v0.1 source release for macOS 13 and later. The public build pipeline is ready for Developer ID signing and notarization; until those credentials are attached, build locally from source as shown below.

## Install

The source install is one command after cloning:

```bash
git clone https://github.com/madebycm/macpack.git
cd macpack
./scripts/install-local.sh
```

macOS asks for administrator approval once while installing MacPack itself. The first package opened from Downloads, Desktop, or another privacy-protected folder may also produce the normal one-time folder-access prompt. After that, ordinary package installs require no confirmation or authentication.

To open the queue or change options later, open **MacPack** from `/Applications`. It stays completely hidden otherwise.

## What it does

- Handles all three package types declared by Apple’s current Installer.app: flat `.pkg`, legacy bundle `.pkg`, and `.mpkg`.
- Transparently catches Finder package opens even though current macOS hard-locks those types to Installer.app.
- Installs immediately by default; an optional confirmation mode is available.
- Serializes every package into a persistent queue.
- Lets you click any queued package to make it the next install without interrupting active work.
- Shows parseable Installer progress when available and a calm indeterminate state otherwise.
- Replaces existing payload files according to the package’s own rules—exactly as `/usr/sbin/installer` does.
- Runs built-in post-install hooks before advancing the queue, including the bundled VST duplicate cleaner.
- Preserves cleaned plug-ins for recovery instead of deleting them.
- Starts the UI agent at login without a Dock or status-bar presence.
- Keeps the root installer registered with launchd across boots, but launches it only on demand and exits it two seconds after the queue goes idle.
- Survives app restarts by restoring unfinished queue entries.

## How the one-time authorization works

MacPack does not cache a password and does not weaken `sudo`.

```text
.pkg double-click
        ↓ Finder launches Apple Installer (macOS-protected binding)
hidden MacPack app observes → hides Installer → recovers every package path
        ↓ user-readable staging copy → persistent queue + corner HUD
        ↓ signature-restricted privileged XPC
launchd root helper (on demand only)
        ↓ argv, never a shell
/usr/sbin/installer -verboseR -pkg … -target /
        ↓ only after a successful install
signed, built-in post-install hooks → next queued package
```

The initial MacPack package places a root-owned helper and launchd descriptor in macOS’s protected `/Library` locations. launchd holds the Mach-service registration across boots. The helper is therefore already privileged when MacPack requests an install, which removes the meaningless repeated authentication ceremony without caching credentials.

Since macOS 13.3, Finder intentionally refuses third-party default handlers for installer packages. MacPack therefore watches only for Apple Installer launching, reads its package paths, hides and terminates it, and routes those paths into the queue. If no valid package is found, MacPack unhides Installer and gets out of the way. This requires no Accessibility, Input Monitoring, Apple Events, or permanent polling.

The XPC service accepts only a client matching the MacPack app’s build-time designated code-signing requirement. Paths are sent as typed XPC arguments and passed to Installer as an argument array—never interpolated into a shell command.

## Built-in VST cleanup

After each successful package install, MacPack runs the same cleanup logic as the project’s canonical `vst` CLI alias. The exact source snapshot is vendored under `Resources/PostHooks/VSTCleanup` and covered by checksum and behavior tests. It includes the Ableton-aware AU/VST3 matching, `vsx` and Melodyne protection, Stellarizer/Glitchwork/Textureloom VST3 preference, FabFilter version and Mono/SC cases, conditional Revoice Pro legacy cleanup, Waves cleanup, and Max for Live `.adv` dedup. Slow broken-code-signature scanning remains off, matching the alias default.

Fresh installs have one timing wrinkle: Ableton cannot index a plug-in before it exists. MacPack therefore reads the just-installed package’s BOM and bridges that indexing gap only when the package itself contains an exact same-stem AU+VST3 pair and the AU exists after installation. The canonical `NEVER_REMOVE` and `PREFER_VST3` exceptions still win. This lets a fresh package such as Lucid clean its VST3 immediately without weakening the cleaner’s global Ableton-aware sweep.

Most moved items are recoverable from `~/Library/Application Support/MacPack/Cleaned Plugins`; Ableton-shadowed VST3 bundles keep the canonical alias destination `/usr/local/vst3-cleaned`. Full output from the latest run is written to `/Library/Logs/MacPack/vst-cleanup.log`.

The hook also preserves the alias’s CrashReporter behavior: the login user’s `com.apple.CrashReporter DialogType` is set to `none`. Crash reports are still written normally.

Hooks are code-controlled product extensions, not user commands. There is intentionally no hook editor or arbitrary-command preference. Contributors can add a typed runner and signed manifest entry; see [Architecture](docs/ARCHITECTURE.md#post-install-hooks).

If Ableton's database is locked or unreadable, the hook skips database-dependent VST3 matching and continues the remaining cleanup. It keeps VST3s whose AU compatibility cannot be verified; exact AU/VST3 pairs proven by the just-installed package still use the fresh-install rule above.

See [Architecture](docs/ARCHITECTURE.md) for the platform decisions and Apple references.

## Preferences

- **Install immediately** — enabled by default. Disable it to hold new packages until you click Install.
- **Corner progress** — show or hide the minimal 218 × 40 pt floating progress panel.
- **Start at login** — uses `SMAppService.mainApp`; MacPack remains an accessory app with no Dock/menu-bar item.
- **Finder routing** — verify that the hidden package-open interceptor is ready.
- **Installer service** — verify the installed service or register the modern embedded daemon when using a drag-installed, notarized build.

If packages are waiting and the installer service is unavailable, reinstall MacPack with `./scripts/install-local.sh` to restore its protected helper and reload its launchd registration. For a drag-installed build, use **Enable** and approve MacPack under Login Items. The queue reconnects during setup and whenever you return to the app.

To check the actual privileged connection without opening the queue or installing anything:

```bash
/Applications/MacPack.app/Contents/MacOS/MacPack --check-installer-service
```

This check reports `ready` only after the helper replies, fails within five seconds if it cannot connect, and exits with a nonzero status on failure.

## Build and verify

Requirements: macOS 13+, Swift 6 toolchain, and Command Line Tools.

```bash
swift run MacPackSelfTest
python3 SelfTests/test_vst_hook.py
(cd Resources/PostHooks/VSTCleanup && shasum -a 256 -c SNAPSHOT.sha256)
./scripts/build-app.sh --production
./scripts/build-pkg.sh --skip-build
```

Outputs:

- `build/MacPack.app`
- `dist/MacPack-0.1.0.pkg`

For local iteration, `./devbuild.sh` increments `.CM_DEV_BUILD`, rebuilds the stable app path, signs it with the first local code-signing identity, relaunches it, and streams logs. Dev builds show their build number in the settings window and progress HUD.

For public distribution, set `CODESIGN_IDENTITY` to a **Developer ID Application** identity and `INSTALLER_SIGNING_IDENTITY` to a **Developer ID Installer** identity. Then notarize and staple the package:

```bash
export CODESIGN_IDENTITY='Developer ID Application: Example (TEAMID)'
export INSTALLER_SIGNING_IDENTITY='Developer ID Installer: Example (TEAMID)'
./scripts/build-pkg.sh
./scripts/notarize.sh dist/MacPack-0.1.0.pkg YOUR_NOTARYTOOL_KEYCHAIN_PROFILE
```

## Honest limits

MacPack removes Installer’s generic ceremony. macOS can still block or interrupt a package that is untrusted, incompatible, requires a system extension/privacy approval, insists on a restart, or rejects the target in its own scripts. There is no supported “overwrite absolutely everything” Installer flag; package-authored behavior still wins.

MacPack cannot literally become Finder’s default `.pkg` application: Apple marks Installer’s package declarations `apple-default-no-override`, and Finder disables its Open With control for them. The launch interception produces the intended double-click behavior while MacPack is running; if MacPack is not running, normal Installer.app behavior remains intact. See the grounded explanation in [Architecture](docs/ARCHITECTURE.md#finder-routing).

MacPack intentionally does not use `-allowUntrusted`, alter Gatekeeper rules, cache administrator credentials, add `NOPASSWD` sudoers entries, or expose a general privileged command runner.

## Contributing

Bug reports and focused pull requests are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md) before changing the privileged boundary.

MIT licensed.
