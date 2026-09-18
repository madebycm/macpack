# Changelog

## Unreleased

- Packages inside other apps' sandbox containers (auto-updater downloads such as Shottr's) are left to Installer.app instead of being intercepted into a staging copy macOS app-data protection denies.
- A freshly routed package whose staging still fails is handed back to Installer.app so the install proceeds normally, with a one-shot interception bypass that prevents a recapture loop.
- Code-controlled, manifest-driven post-install hook platform with a dedicated queue phase and persistent cleanup status.
- Exact canonical `vst` alias cleanup, including Ableton, FabFilter, Revoice Pro, Waves, and Max for Live special cases.
- Recoverable cleaned-plugin storage, root-helper execution without another password prompt, checksum fixtures, and focused regression tests.
- Package-BOM evidence for cleaning fresh exact AU/VST3 pairs before Ableton’s index catches up, while preserving every protected/prefer-VST3 exception.
- A substantially smaller, active-screen-bounded corner HUD and click-to-prioritize queue rows.

## 0.1.0 — 2026-08-21

- Hidden `.pkg`/`.mpkg` Finder interceptor with an immediate persistent queue.
- Multi-package capture with direct `libproc` inspection and a tested `lsof` fallback.
- Per-job staging for packages in macOS privacy-protected folders.
- Tiny nonactivating corner progress panel and full queue/preferences window.
- Signature-restricted privileged XPC installer with launch-on-demand lifecycle.
- One-time package installer, login startup, queue recovery, and retry.
- Reproducible app/package scripts, self-tests, CI verification, and notarization hook.
