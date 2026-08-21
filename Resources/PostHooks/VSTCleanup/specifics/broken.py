"""Broken plugin detection — codesign signature verification.

The goal here is *load-failure* detection, not strict-mode lint. Many
working plugins (iZotope, JUCE-based vendors) ship with "unsealed contents
in the bundle root" — codesign reports it as an error but macOS happily
loads them. We deliberately ignore those false positives.

What we DO catch (macOS 13+ loader will refuse):

  - "bundle format unrecognized" — bundle structure corrupt
  - "directory or signature have been modified" — tampered after signing
  - "a sealed resource is missing or invalid" — partial install / corruption
  - "invalid resource directory" / "invalid signature" — corruption
  - "no resources" with mismatched signature

What we DON'T catch (vendor packaging quirks, but plugins still load):

  - "unsealed contents present in the bundle root" (iZotope Neutron 5,
    many JUCE plugins) — works fine in Live, just sloppy packaging
  - "code object is not signed at all" — legacy plugins (Waves WaveShell,
    AIR, some old freeware) — usually load OK in user-space hosts;
    add to KEEP_BROKEN if a specific one is flagged unjustly

Cleaner moves matches to ``/tmp/removed_plugins/Broken_Codesign/``
(recoverable until reboot). Skip with ``skipbroken`` argument.
"""

import subprocess
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

_PLUGIN_SUFFIXES = {".vst3", ".vst", ".component", ".aaxplugin", ".clap"}

# Substrings in codesign's stderr that indicate a *load-failing* broken
# plugin. Matched case-insensitively against combined stdout+stderr.
#
# Deliberately NOT included (false positives that load fine):
#   - "sealed"      → "unsealed contents in bundle root" (iZotope, JUCE)
#   - "not signed"  → legacy unsigned plugins (Waves WaveShell, etc.)
_BROKEN_PATTERNS = (
    "modified",         # "directory or signature have been modified"
    "invalid resource", # "invalid resource directory"
    "invalid signature",
    "missing",          # "a sealed resource is missing or invalid"
    "unrecognized",     # "bundle format unrecognized, invalid, or unsuitable"
    "format unrecog",
    "no resources",     # "code has no resources but signature indicates..."
)

# Bundles that fail codesign but are intentionally kept
# (e.g. local dev builds, intentionally modified plugins).
# Stem is matched case-insensitively, no extension.
KEEP_BROKEN: set[str] = {
    "birds",        # the user's own dev plugin
    "neuralnote",   # local build
    "organica",     # local build
}

# Per-plugin codesign timeout. Most plugins finish in <1s; we cap at 10s
# to bound worst-case runs across hundreds of bundles.
_CODESIGN_TIMEOUT_SEC = 10

# Parallel workers for codesign verification (I/O-bound).
_MAX_WORKERS = 10


def _check_codesign(path: Path) -> tuple[Path, str | None]:
    """Run codesign --verify on path.

    We use plain ``--verify`` (not ``--strict``) and filter the output to
    avoid false positives on plugins with sloppy-but-loadable signatures.

    Returns:
        (path, None) if codesign passes or fails with a benign reason.
        (path, error_message) if codesign reports a real load-blocking issue.
        (path, None) on timeout/OSError (treat as inconclusive — keep plugin).
    """
    try:
        result = subprocess.run(
            ["codesign", "--verify", str(path)],
            capture_output=True,
            text=True,
            timeout=_CODESIGN_TIMEOUT_SEC,
        )
    except (subprocess.TimeoutExpired, OSError):
        return path, None

    if result.returncode == 0:
        return path, None

    msg = (result.stdout + result.stderr).lower()
    if any(p in msg for p in _BROKEN_PATTERNS):
        # Strip the path prefix from the message for cleaner reporting.
        clean = (result.stdout + result.stderr).strip()
        clean = clean.split(": ", 1)[1] if ": " in clean else clean
        return path, clean.splitlines()[0] if clean else "broken signature"

    return path, None


def find_broken(plugin_dirs: list[Path]) -> list[tuple[Path, str]]:
    """Find plugins with broken/invalid code signatures.

    Args:
        plugin_dirs: All plugin directories to scan (system + user, all formats).

    Returns:
        List of ``(path, reason)`` tuples for plugins that fail codesign
        with a load-blocking error.
    """
    candidates: list[Path] = []
    for folder in plugin_dirs:
        if not folder.is_dir():
            continue
        for item in folder.iterdir():
            if item.suffix.lower() not in _PLUGIN_SUFFIXES:
                continue
            if item.stem.lower() in KEEP_BROKEN:
                continue
            candidates.append(item)

    if not candidates:
        return []

    broken: list[tuple[Path, str]] = []
    with ThreadPoolExecutor(max_workers=_MAX_WORKERS) as executor:
        for path, reason in executor.map(_check_codesign, candidates):
            if reason is not None:
                broken.append((path, reason))

    return broken
