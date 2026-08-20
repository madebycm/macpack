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
- Shows parseable Installer progress when available and a calm indeterminate state otherwise.
- Replaces existing payload files according to the package’s own rules—exactly as `/usr/sbin/installer` does.
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
```

The initial MacPack package places a root-owned helper and launchd descriptor in macOS’s protected `/Library` locations. launchd holds the Mach-service registration across boots. The helper is therefore already privileged when MacPack requests an install, which removes the meaningless repeated authentication ceremony without caching credentials.

Since macOS 13.3, Finder intentionally refuses third-party default handlers for installer packages. MacPack therefore watches only for Apple Installer launching, reads its package paths, hides and terminates it, and routes those paths into the queue. If no valid package is found, MacPack unhides Installer and gets out of the way. This requires no Accessibility, Input Monitoring, Apple Events, or permanent polling.

The XPC service accepts only a client matching the MacPack app’s build-time designated code-signing requirement. Paths are sent as typed XPC arguments and passed to Installer as an argument array—never interpolated into a shell command.

See [Architecture](docs/ARCHITECTURE.md) for the platform decisions and Apple references.

## Preferences

- **Install immediately** — enabled by default. Disable it to hold new packages until you click Install.
- **Corner progress** — show or hide the 300 × 58 pt floating progress panel.
- **Start at login** — uses `SMAppService.mainApp`; MacPack remains an accessory app with no Dock/menu-bar item.
- **Finder routing** — verify that the hidden package-open interceptor is ready.
- **Installer service** — verify the installed service or register the modern embedded daemon when using a drag-installed, notarized build.

## Build and verify

Requirements: macOS 13+, Swift 6 toolchain, and Command Line Tools.

```bash
swift run MacPackSelfTest
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
