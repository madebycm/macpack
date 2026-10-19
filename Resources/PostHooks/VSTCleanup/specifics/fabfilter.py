"""FabFilter version cleanup — remove older plugin versions when newer ones exist.

Scans all plugin directories for FabFilter bundles and flags old versions
for removal when a newer version of the same plugin is installed.
E.g. Pro-Q 2 is removed if Pro-Q 3 is found (across all formats).

Also removes obsolete VST2-era mono/sidechain variants like
"FabFilter Pro-C 2 (Mono).vst" — newer FabFilter VST3 plugins handle
mono/sidechain internally.
"""

import re
from pathlib import Path

# Each sub-list is oldest → newest.  Only the highest installed version is kept;
# everything older is flagged for removal across all formats.
FABFILTER_FAMILIES: list[list[str]] = [
    ["FabFilter Pro-Q", "FabFilter Pro-Q 2", "FabFilter Pro-Q 3", "FabFilter Pro-Q 4"],
    ["FabFilter Pro-C", "FabFilter Pro-C 2", "FabFilter Pro-C 3"],
    ["FabFilter Pro-L", "FabFilter Pro-L 2"],
    ["FabFilter Pro-R", "FabFilter Pro-R 2"],
    ["FabFilter Saturn", "FabFilter Saturn 2"],
    ["FabFilter Timeless", "FabFilter Timeless 2", "FabFilter Timeless 3"],
    ["FabFilter Volcano", "FabFilter Volcano 2", "FabFilter Volcano 3"],
    ["FabFilter Twin", "FabFilter Twin 2", "FabFilter Twin 3"],
]

_PLUGIN_SUFFIXES = {".vst3", ".vst", ".component", ".aaxplugin", ".clap"}

# VST2-era FabFilter variants — newer VST3 versions handle these internally.
_FF_VARIANT_RE = re.compile(r"\s*\((Mono|SC|SC Mono)\)$", re.IGNORECASE)


def _strip_ff_variant(stem: str) -> str:
    """Strip FabFilter mono/sidechain variant suffixes from a plugin stem."""
    return _FF_VARIANT_RE.sub("", stem)


def find_obsolete(plugin_dirs: list[Path]) -> list[Path]:
    """Return paths of FabFilter plugins superseded by a newer installed version
    or obsolete mono/sidechain VST2 variants.

    Args:
        plugin_dirs: All plugin directories to scan (system + user, all formats).

    Returns:
        Paths to remove.
    """
    # Map raw stem -> paths, and stripped stem -> paths (for variant matching)
    stem_to_paths: dict[str, list[Path]] = {}

    for folder in plugin_dirs:
        if not folder.is_dir():
            continue
        for item in folder.iterdir():
            if item.suffix.lower() in _PLUGIN_SUFFIXES:
                stem_to_paths.setdefault(item.stem.lower(), []).append(item)

    to_remove: list[Path] = []

    # 1) Version family cleanup: remove older versions when newer exists.
    #    Also match variant stems (e.g. "Pro-C 2 (Mono)" -> "Pro-C 2").
    for family in FABFILTER_FAMILIES:
        highest = -1
        for idx, name in enumerate(family):
            if name.lower() in stem_to_paths:
                highest = idx

        if highest <= 0:
            continue

        obsolete_names = {family[idx].lower() for idx in range(highest)}
        for stem, paths in stem_to_paths.items():
            stripped = _strip_ff_variant(stem)
            if stripped in obsolete_names:
                to_remove.extend(paths)

    # 2) Mono/SC variant cleanup: remove any FabFilter (Mono)/(SC)/(SC Mono)
    #    VST2 variant when the base plugin exists in VST3.
    vst3_stems = set()
    for folder in plugin_dirs:
        if not folder.is_dir():
            continue
        for item in folder.iterdir():
            if item.suffix.lower() == ".vst3":
                vst3_stems.add(item.stem.lower())

    for stem, paths in stem_to_paths.items():
        if not stem.startswith("fabfilter "):
            continue
        stripped = _strip_ff_variant(stem)
        if stripped == stem:
            continue  # no variant suffix — skip
        # Flag if the base plugin exists in VST3
        if stripped in vst3_stems:
            for p in paths:
                if p not in to_remove:
                    to_remove.append(p)

    return to_remove
