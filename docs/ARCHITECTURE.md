# Architecture

MacPack’s product constraint is unusually sharp: after one deliberate system setup, opening an installer package must begin installation immediately without leaving a privileged process resident all day.

## Components

### MacPack.app

An AppKit/SwiftUI accessory application (`LSUIElement = true`) that:

- declares `Viewer` support for the three installer package UTIs;
- observes Apple Installer launches and recovers package paths from its open files;
- receives explicitly routed URLs through `application(_:open:)`;
- stages a user-readable copy under its Application Support directory before crossing the root boundary;
- owns the persistent serial queue in `~/Library/Application Support/MacPack/queue.json`;
- parses structured progress emitted by `installer -verboseR`;
- presents a nonactivating `NSPanel` only while there is relevant status;
- shows preferences and the queue when the app itself is opened;
- uses `SMAppService.mainApp` for login startup.

Apple documents [`LSUIElement`](https://developer.apple.com/documentation/bundleresources/information-property-list/lsuielement) and [`application(_:open:)`](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/application%28_%3Aopen%3A%29).

## Finder routing

Current macOS does not allow a third-party app to become Finder’s real default for installer packages. Installer’s LaunchServices declarations carry Apple’s private `apple-default-no-override` flag; since macOS 13.3, Finder offers only Installer and disables the Get Info “Open with” control. This is documented by the current [Suspicious Package FAQ](https://www.mothersruin.com/software/SuspiciousPackage/faq.html#finder-open-with) and is independently reproducible on macOS 26.

MacPack implements the current transparent workaround:

1. `NSWorkspace` launch and activation notifications wake the already-hidden login item only when Installer.app starts.
2. MacPack hides Installer before it presents normal installation chrome.
3. It inspects Installer’s vnode descriptors with `libproc`, falling back to `/usr/sbin/lsof` because package bundles are not consistently exposed as ordinary descriptors.
4. It accumulates all `.pkg` and `.mpkg` roots until the descriptor set is quiet, preventing a multi-open Apple Event from losing later packages.
5. With at least one valid package, MacPack terminates Installer and opens those URLs explicitly in itself. Without one, it unhides Installer and leaves normal behavior intact.

The event-driven pattern is grounded in the current [Suspicious Package Helper implementation](https://github.com/JayBrown/Suspicious-Package-Helper/blob/ad6cf55889a46bfd40cff27f0973d513586b4087/Suspicious%20Package%20Helper/main.swift#L53-L159). MacPack does not use Accessibility, Input Monitoring, Finder Sync, Apple Events, or an idle polling loop.

The user app then copies each package into `~/Library/Application Support/MacPack/Spool/<job UUID>/`. This is necessary because a root launch daemon does not inherit the interactive app’s TCC access to Downloads, Desktop, removable volumes, or other privacy-protected locations. A successful job removes its spool directory. macOS may ask for folder access the first time a protected location is used.

### MacPackInstaller

A Foundation-only launch daemon that:

- publishes the `com.macpack.installer` Mach service;
- requires the connecting process to satisfy MacPack’s designated signing requirement using `NSXPCConnection.setCodeSigningRequirement`;
- validates an absolute, existing `.pkg` or `.mpkg` path;
- invokes `/usr/sbin/installer` directly with an argument array;
- streams structured phase and percentage events back over bidirectional XPC;
- executes code-controlled post-install hooks after Installer exits successfully;
- exits two seconds after outstanding work completes.

Apple documents privileged Mach connections through [`NSXPCConnection.Options.privileged`](https://developer.apple.com/documentation/foundation/nsxpcconnection/options/privileged) and peer restriction through [`setCodeSigningRequirement`](https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement%28_%3A%29).

## Registration modes

MacPack supports both current distribution shapes because they have different consent behavior.

1. **One-prompt package install.** `MacPack.pkg` writes the signed app, helper, client requirement, and launchd plist into protected system locations. The package’s one administrator authorization is the durable privilege boundary. Apple’s current Service Management SDK explicitly says legacy daemons already installed in `/Library/LaunchDaemons` continue to bootstrap because writing there is permission-protected.
2. **Modern drag-install mode.** The app also embeds its helper and `BundleProgram` launchd descriptor in the layout required by `SMAppService.daemon(plistName:)`. A signed and notarized app can register it from Preferences. macOS requires an administrator to approve this background item in System Settings before first use.

`SMAppService` is Apple’s macOS 13+ replacement for `SMJobBless`; its [`register()` documentation](https://developer.apple.com/documentation/servicemanagement/smappservice/register%28%29) confirms that a daemon is bootstrapped at each boot only after administrator approval. MacPack does not use deprecated `AuthorizationExecuteWithPrivileges`, deprecated `SMJobBless`, a setuid executable, or sudoers modification.

The installed job is demand-driven through `MachServices`; it has neither `KeepAlive` nor `RunAtLoad`. launchd retains registration, not a resident root process.

## Post-install hooks

Post-install hooks are a product extension point, not a general automation surface. `Resources/PostHooks/hooks.json` declares built-in hooks using a versioned manifest. The helper accepts only known runner enum values, validates identifiers and relative entrypoints, and recursively rejects resources that are symlinks, non-root-owned, or group/world-writable before executing anything. There is no XPC method or UI for adding a command.

The first built-in hook vendors the canonical `vst_cleaner.py` and its imported `specifics` modules byte-for-byte. `SNAPSHOT.sha256` makes source drift explicit, while `scripts/sync-vst-hook.sh` provides a narrow update path that never copies the alias’s password cache. A small adapter supplies the login user’s home and recovery directory, bypasses the cleaner’s interactive sudo/cache path because the helper is already root, and runs the unchanged Python 3.10-oriented source through a temporary postponed-annotation compatibility layer on Apple’s Python 3.9. `PYTHONDONTWRITEBYTECODE=1` prevents Python from modifying signed app resources.

The VST cleanup runs with its normal defaults: Waves and Max for Live cleanup enabled, broken-code-signature scanning disabled. Immediately after a new install, Ableton’s database can legitimately lag behind the filesystem. The adapter handles that narrow case by reading only BOM entries from the installed package and moving a remaining VST3 only when that same package declared an exact same-stem AU+VST3 pair, the AU now exists on disk, and neither `NEVER_REMOVE` nor `PREFER_VST3` applies. The unchanged canonical cleaner still owns every global cleanup decision.

Most moved items go to `~/Library/Application Support/MacPack/Cleaned Plugins`; Ableton-shadowed VST3 bundles retain the cleaner’s `/usr/local/vst3-cleaned` destination. The adapter applies the cleaner’s CrashReporter preference to the connecting login user rather than root. Output is capped in memory and recorded at `/Library/Logs/MacPack/vst-cleanup.log`.

Hook completion is part of the serial queue. A hook timeout or failure is reported as a warning on the successful install and does not falsely change `/usr/sbin/installer`’s result or attempt a package rollback.

## Package types

Apple does not publish contemporary `UTType` constants for Installer packages. The signed Installer.app in macOS 26.5 declares:

- `com.apple.installer-package`
- `com.apple.installer-meta-package`
- `com.apple.installer-package-archive`

MacPack declares all three as separate document types because the first two are directory packages and the third is a flat archive. The declarations support explicit opens and drag/drop, but Apple’s protected Installer binding prevents them from controlling Finder’s default choice.

## Queue and failure semantics

The user app is the only queue owner and issues one XPC install at a time. An item transitions through:

```text
staging → waiting (optional confirmation) | queued → installing → post-processing → installed | failed
```

An app restart recovers `installing` or `post-processing` as `queued`. A helper disconnect is a normal failed state, never an implicit fallback to `sudo`. The UI stays visible for failures and offers an explicit retry.

Clicking a queued row moves that item ahead of the other queued jobs. The active install and post-hook are never interrupted.

Installer percentage output is optional. Missing progress produces an indeterminate bar rather than invented progress. Successful exit status is the source of truth; `/var/log/install.log` remains macOS’s detailed audit log.

## Signing and release

Every executable is signed inside-out. The app’s designated requirement is captured at build time and installed root-owned beside the daemon. Production release requires:

- Developer ID Application signature for the app and helper;
- Hardened Runtime and secure timestamps;
- Developer ID Installer signature for the outer package;
- notarization and stapling.

See Apple’s [notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
