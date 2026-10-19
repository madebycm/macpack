"""Synchro Arts Revoice Pro — remove the legacy VST3 when a newer build exists.

Revoice Pro ships three plugin bundles on macOS:

  - "Revoice Pro Link (Legacy).vst3"   ← old VST3 (32-bit-era naming)
  - "Revoice Pro Monitor.vst3"         ← separate monitoring plugin (keep)
  - "RevoiceProLink.component"         ← current AU
  - "RevoiceProLink.vst3"              ← current VST3 (when installed)

The Ableton-aware dedup pass can't catch the legacy bundle because its
stem ("Revoice Pro Link (Legacy)") doesn't match the modern bundle's
stem ("RevoiceProLink"). This specific handles that name mismatch.

The legacy VST3 is flagged ONLY when a current Revoice Pro Link build
is also present (AU .component or modern VST3) — so we never delete
the only working copy.

The "Revoice Pro Monitor" plugin is a separate utility and is always
kept.
"""

from pathlib import Path

# Legacy bundle filenames to flag.  Matched case-insensitively.
_LEGACY_STEMS = {
    "revoice pro link (legacy)",
}

# Modern bundle stems that, if present in any plugin dir, prove the
# current Revoice Pro Link is installed and the legacy copy is safe to drop.
_MODERN_STEMS = {
    "revoiceprolink",
}

_PLUGIN_SUFFIXES = {".vst3", ".vst", ".component", ".aaxplugin", ".clap"}


def find_obsolete(plugin_dirs: list[Path]) -> list[Path]:
    """Return paths of legacy Revoice Pro bundles superseded by the modern build.

    Args:
        plugin_dirs: All plugin directories to scan (system + user, all formats).

    Returns:
        Paths to remove. Empty if no modern Revoice Pro Link is installed.
    """
    legacy_paths: list[Path] = []
    has_modern = False

    for folder in plugin_dirs:
        if not folder.is_dir():
            continue
        for item in folder.iterdir():
            if item.suffix.lower() not in _PLUGIN_SUFFIXES:
                continue
            stem = item.stem.lower()
            if stem in _LEGACY_STEMS:
                legacy_paths.append(item)
            elif stem in _MODERN_STEMS:
                has_modern = True

    if not has_modern:
        return []
    return legacy_paths
