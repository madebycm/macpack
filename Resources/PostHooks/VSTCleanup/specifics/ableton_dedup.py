"""Ableton-aware AU/VST3 dedup — hardened, filesystem-first.

Goal: in Ableton's browser, show exactly ONE format per plugin — AU
when it actually works in Live, else VST3. Never lose a plugin.

A VST3 on disk is "shadowed" by AU iff ANY of these match-paths hold:

  Path A — same-stem .component on disk:
    Same bundle stem (case-insensitive) as the .vst3, and that
    .component's Info.plist codes appear in Live's index. Catches
    plugins where AU and VST3 share filenames (UADx, FabFilter, etc).

  Path B — Live display-name link:
    Live indexes both an AU and a VST3 entry under the same display
    name, that AU's codes appear in a real on-disk .component, and
    the .vst3 file's stem matches the name (exact or
    "<vendor> <name>" suffix). Catches plugins where AU and VST3
    bundle filenames differ (iZotope Nectar 4 → .vst3 is
    "Nectar 4 Auto-Level.vst3", .component is
    "iZNectar4Auto-LevelAUHook.component").

If neither path matches, the VST3 stays. NEVER lose a plugin.

What we explicitly catch:
  - Animation Station (.component exists, declares `aumi`, Live skips
    MIDI Processor AUs → no Live index entry → no match → kept).
  - Rolling Sampler (Live's DB has stale AU entry but .component was
    uninstalled → no on-disk codes match → kept).
  - UADx 1176 Rev A (same-stem .component on disk, codes indexed by
    Live → moved via Path A).
  - FabFilter Pro-Q 4 (same-stem .component → moved via Path A; also
    matches via Path B since Live's "Pro-Q 4" name suffixes the file).
  - Nectar 4 Auto-Level (different .component stem; same display name
    in Live → moved via Path B).

What we do NOT use:
  - ``Live-plugins-1.db`` for path resolution — Live rebuilds it and
    its dev_identifier→path mapping goes stale the moment files move.
    The filesystem is the only stable truth source for "which .vst3
    files actually exist".
"""

import plistlib
import sqlite3
from pathlib import Path

ABLETON_DB_DIR = Path.home() / "Library/Application Support/Ableton/Live Database"

_SYSTEM_COMPONENTS = Path("/Library/Audio/Plug-Ins/Components")
_USER_COMPONENTS = Path.home() / "Library/Audio/Plug-Ins/Components"
_SYSTEM_VST3 = Path("/Library/Audio/Plug-Ins/VST3")
_USER_VST3 = Path.home() / "Library/Audio/Plug-Ins/VST3"


# ---------------------------------------------------------------------------
# Live database locator
# ---------------------------------------------------------------------------


def _find_files_db() -> Path | None:
    """Most recent ``Live-files-NNNNN.db`` (browser/display index)."""
    if not ABLETON_DB_DIR.is_dir():
        return None
    cands = sorted(ABLETON_DB_DIR.glob("Live-files-*.db"), key=lambda p: p.name)
    return cands[-1] if cands else None


# ---------------------------------------------------------------------------
# AU code helpers — Apple's 4-char tags are stored as big-endian uint32
# in Live's DB and as 4-char strings in Info.plist.
# ---------------------------------------------------------------------------


def _be4(s: str) -> int:
    if not s:
        return 0
    b = s.encode("ascii", errors="replace")[:4].ljust(4, b"\x00")
    return int.from_bytes(b, "big")


def _parse_au_device_id(device_id: str) -> tuple[int, int, int] | None:
    """Decode ``(type, subtype, mfr)`` from ``device:au:cat:MFR:SUB:TYPE``."""
    parts = device_id.split(":")
    if len(parts) < 6:
        return None
    try:
        mfr, sub, typ = int(parts[-3]), int(parts[-2]), int(parts[-1])
    except ValueError:
        return None
    return (typ, sub, mfr)


def _read_au_codes(component: Path) -> set[tuple[int, int, int]]:
    """Return ``{(type, subtype, manufacturer)}`` triples from a .component."""
    info = component / "Contents/Info.plist"
    if not info.is_file():
        return set()
    try:
        with info.open("rb") as f:
            plist = plistlib.load(f)
    except Exception:
        return set()
    out: set[tuple[int, int, int]] = set()
    for ac in plist.get("AudioComponents", []) or []:
        t = ac.get("type")
        s = ac.get("subtype")
        m = ac.get("manufacturer")
        if t and s and m:
            out.add((_be4(t), _be4(s), _be4(m)))
    return out


# ---------------------------------------------------------------------------
# Filesystem scan: AU codes indexed by .component bundle stem, plus the
# union of all codes for quick membership checks.
# ---------------------------------------------------------------------------


def _scan_components_on_disk() -> tuple[
    dict[str, set[tuple[int, int, int]]], set[tuple[int, int, int]]
]:
    """Return ``(codes_by_stem, all_codes)``.

    ``codes_by_stem`` maps each .component's lowercased bundle stem to
    the set of AU code triples its Info.plist declares.
    ``all_codes`` is the union — every code triple that has SOME real
    .component on disk.
    """
    codes_by_stem: dict[str, set[tuple[int, int, int]]] = {}
    all_codes: set[tuple[int, int, int]] = set()
    for cd in (_SYSTEM_COMPONENTS, _USER_COMPONENTS):
        if not cd.is_dir():
            continue
        for comp in cd.glob("*.component"):
            codes = _read_au_codes(comp)
            if codes:
                codes_by_stem[comp.stem.lower()] = codes
                all_codes |= codes
    return codes_by_stem, all_codes


# ---------------------------------------------------------------------------
# Live DB scan: per-display-name AU codes + which names have VST3 entries
# ---------------------------------------------------------------------------


def _live_au_codes_by_name(
    files_db: Path,
) -> tuple[
    dict[str, set[tuple[int, int, int]]],
    set[str],
    set[tuple[int, int, int]],
]:
    """Return ``(au_codes_by_name, vst3_names, live_au_codes_union)``."""
    conn = sqlite3.connect(f"file:{files_db}?mode=ro", uri=True)
    try:
        rows = conn.execute(
            "SELECT name, device_id FROM files "
            "WHERE device_id LIKE 'device:au:%' OR device_id LIKE 'device:vst3:%'"
        ).fetchall()
    finally:
        conn.close()

    au_codes_by_name: dict[str, set[tuple[int, int, int]]] = {}
    vst3_names: set[str] = set()
    live_au_codes: set[tuple[int, int, int]] = set()
    for name, devid in rows:
        key = (name or "").strip().lower()
        if not key or not devid:
            continue
        if devid.startswith("device:au:"):
            codes = _parse_au_device_id(devid)
            if codes is not None:
                au_codes_by_name.setdefault(key, set()).add(codes)
                live_au_codes.add(codes)
        elif devid.startswith("device:vst3:"):
            vst3_names.add(key)
    return au_codes_by_name, vst3_names, live_au_codes


# ---------------------------------------------------------------------------
# VST3 walker + stem matcher
# ---------------------------------------------------------------------------


def _iter_vst3_files(root: Path):
    if not root.is_dir():
        return
    for path in root.rglob("*.vst3"):
        if any(parent.suffix.lower() == ".vst3" for parent in path.parents):
            continue
        yield path


def _all_vst3_files() -> list[Path]:
    out: list[Path] = []
    seen: set[Path] = set()
    for root in (_SYSTEM_VST3, _USER_VST3):
        for v in _iter_vst3_files(root):
            if v in seen:
                continue
            seen.add(v)
            out.append(v)
    return out


def _stem_matches_name(stem_lower: str, name_lower: str) -> bool:
    """Exact match, or stem ending with `" <name>"` so vendor-prefixed
    files like ``FabFilter Pro-Q 4.vst3`` match Live's ``Pro-Q 4``."""
    if not name_lower:
        return False
    if stem_lower == name_lower:
        return True
    if stem_lower.endswith(" " + name_lower):
        return True
    return False


# ---------------------------------------------------------------------------
# Core shadowing predicate — used by both forward (on disk) and backup
# audit (already moved) — so the logic stays consistent.
# ---------------------------------------------------------------------------


def _stem_is_shadowed(
    stem_lower: str,
    codes_by_stem: dict[str, set[tuple[int, int, int]]],
    live_au_codes_union: set[tuple[int, int, int]],
    movable_names: list[str],
) -> bool:
    """True iff this .vst3 stem matches a shadowing path.

    Path A: same-stem .component on disk whose codes Live indexes.
    Path B: a movable Live name (both formats indexed, AU codes on
            disk) that stem-matches the .vst3.
    """
    # Path A
    same_stem_codes = codes_by_stem.get(stem_lower)
    if same_stem_codes and (same_stem_codes & live_au_codes_union):
        return True
    # Path B
    for name in movable_names:
        if _stem_matches_name(stem_lower, name):
            return True
    return False


def _compute_movable_names(
    au_codes_by_name: dict[str, set[tuple[int, int, int]]],
    vst3_names: set[str],
    on_disk_codes_union: set[tuple[int, int, int]],
) -> list[str]:
    """Live names where both formats are indexed AND AU codes are real."""
    names = [
        n for n, codes in au_codes_by_name.items()
        if n in vst3_names and (codes & on_disk_codes_union)
    ]
    # Longest-first so "Pro-Q 4" beats a hypothetical "Q 4".
    names.sort(key=len, reverse=True)
    return names


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def find_vst3_shadowed_by_au() -> tuple[Path | None, list[Path]]:
    """Return ``(files_db, vst3_paths)`` — .vst3 files safe to move aside."""
    files_db = _find_files_db()
    if files_db is None:
        return None, []

    codes_by_stem, on_disk_codes_union = _scan_components_on_disk()
    if not on_disk_codes_union:
        return files_db, []

    au_codes_by_name, vst3_names, live_au_codes_union = _live_au_codes_by_name(files_db)
    movable_names = _compute_movable_names(
        au_codes_by_name, vst3_names, on_disk_codes_union
    )

    matches: list[Path] = []
    seen: set[Path] = set()
    for vst3 in _all_vst3_files():
        if vst3 in seen:
            continue
        if _stem_is_shadowed(
            vst3.stem.lower(), codes_by_stem, live_au_codes_union, movable_names
        ):
            seen.add(vst3)
            matches.append(vst3)
    matches.sort(key=lambda p: str(p).lower())
    return files_db, matches


def find_wrongly_moved_in_backup(backup_dir: Path) -> list[tuple[Path, str]]:
    """Inverse audit: .vst3s in backup whose AU twin isn't loadable.

    Returns ``[(vst3_path, reason)]`` — these should be restored.
    """
    files_db = _find_files_db()
    if files_db is None or not backup_dir.is_dir():
        return []

    codes_by_stem, on_disk_codes_union = _scan_components_on_disk()
    au_codes_by_name, vst3_names, live_au_codes_union = _live_au_codes_by_name(files_db)
    movable_names = _compute_movable_names(
        au_codes_by_name, vst3_names, on_disk_codes_union
    )

    wrong: list[tuple[Path, str]] = []
    for vst3 in sorted(backup_dir.glob("*.vst3")):
        stem = vst3.stem.lower()
        # Strip __N collision suffix.
        if "__" in stem and stem.rsplit("__", 1)[-1].isdigit():
            stem = stem.rsplit("__", 1)[0]
        if not _stem_is_shadowed(
            stem, codes_by_stem, live_au_codes_union, movable_names
        ):
            wrong.append((vst3, "no real AU twin indexed by Live"))
    return wrong


def diagnostics() -> dict:
    """Pre-run sanity counts. Single-stop snapshot of what the dedup will do."""
    files_db = _find_files_db()
    if files_db is None:
        return {"error": "Live files-DB not found"}

    codes_by_stem, on_disk_codes_union = _scan_components_on_disk()
    au_codes_by_name, vst3_names, live_au_codes_union = _live_au_codes_by_name(files_db)
    movable_names = _compute_movable_names(
        au_codes_by_name, vst3_names, on_disk_codes_union
    )

    overlap = sum(1 for n in au_codes_by_name if n in vst3_names)

    _, to_move = find_vst3_shadowed_by_au()

    return {
        "components_on_disk": len(codes_by_stem),
        "au_code_triples_on_disk": len(on_disk_codes_union),
        "au_names_indexed_by_live": len(au_codes_by_name),
        "vst3_names_indexed_by_live": len(vst3_names),
        "name_overlap_au_and_vst3_in_live": overlap,
        "movable_names_after_disk_check": len(movable_names),
        "stale_au_only_in_live_db": overlap - len(movable_names),
        "vst3_to_move_after_match": len(to_move),
    }
