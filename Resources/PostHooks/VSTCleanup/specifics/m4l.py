"""Max for Live duplicate-preset cleanup.

When a user installs an `.amxd` device (e.g. ``Press4Acid.amxd``) and
also has an ``.adv`` preset with the same stem in their User Library,
the ``.adv`` is dead weight — the device file *is* the device, and a
matching ``.adv`` next to it almost always came from an accidental
"Save Default Preset" or a duplicate import.

We don't hardcode the Max for Live directory. Live tracks every
indexed file in its SQLite database (``Live-files-NNNNN.db``), and
the User Library is recorded explicitly in the ``places`` table with
``folder_kind = 1``. Walking ``files.parent_id`` to root rebuilds an
absolute filesystem path for any indexed file.

Schema reference (see ``specifics/usage.py`` for file-type magic):
    files     — file_id, parent_id, file_type, name, place_id
    places    — file_id, folder_kind, level, name
    ancestors — file_id, ancestor_id  (transitive parent closure)

We only consider ``.adv`` files inside the User Library subtree (via
``ancestors``). ``.amxd`` matches span the whole index — a stock-Live
``.amxd`` deserves dedup against a same-named user ``.adv`` too.
"""

import sqlite3
from pathlib import Path

ABLETON_DB_DIR = Path.home() / "Library/Application Support/Ableton/Live Database"

# File-type magic numbers (4-byte big-endian ASCII codes treated as int).
_FILE_TYPE_AMXD = 1634562093  # Max for Live device (.amxd)
_FILE_TYPE_ADV = 1633973805   # Audio Device preset (.adv)

# folder_kind = 1 marks the User Library root in the `places` table.
_FOLDER_KIND_USER_LIBRARY = 1


def _find_live_files_db() -> Path | None:
    """Locate the most recent ``Live-files-NNNNN.db`` (highest version wins)."""
    if not ABLETON_DB_DIR.is_dir():
        return None
    candidates = sorted(ABLETON_DB_DIR.glob("Live-files-*.db"), key=lambda p: p.name)
    return candidates[-1] if candidates else None


def _strip_tilde(name: str) -> str:
    """Strip a single leading ``~`` from a path segment, if present."""
    return name[1:] if name.startswith("~") and len(name) > 1 else name


def _build_path(conn: sqlite3.Connection, file_id: int) -> Path | None:
    """Reconstruct an absolute filesystem path for a Live-DB file_id.

    Walks ``files.parent_id`` upward. The DB root is the row with
    ``name = '/'``; we stop there and prepend ``/``.

    Ableton encodes well-known folders (``~Music``, ``~Ableton``, etc.)
    with a literal ``~`` prefix in the DB — those tildes are NOT on
    disk. But users may also have folders that genuinely start with
    ``~`` on disk. We resolve this by trying the literal path first
    (preserves user's real tilde-prefixed folders) and falling back to
    a tilde-stripped variant if the literal doesn't exist.
    """
    raw_parts: list[str] = []
    current = file_id
    seen: set[int] = set()
    while current and current not in seen:
        seen.add(current)
        row = conn.execute(
            "SELECT parent_id, name FROM files WHERE file_id = ?",
            (current,),
        ).fetchone()
        if row is None:
            return None
        parent, name = row
        if name == "/":
            break
        raw_parts.append(name)
        if parent == 0:
            break
        current = parent
    if not raw_parts:
        return None

    raw_parts.reverse()
    literal = Path("/" + "/".join(raw_parts))
    if literal.exists():
        return literal

    stripped = Path("/" + "/".join(_strip_tilde(p) for p in raw_parts))
    if stripped.exists():
        return stripped

    # Neither resolves — return the stripped form as the best guess so
    # callers can report a sensible-looking path even if the file is
    # gone (e.g. moved/renamed since Live last scanned).
    return stripped


def find_user_library(conn: sqlite3.Connection | None = None) -> Path | None:
    """Return the absolute path to Live's User Library, or ``None``.

    Caller may pass an open connection to avoid reopening the DB; if
    omitted, a temporary read-only connection is opened and closed.
    """
    own_conn = False
    if conn is None:
        db = _find_live_files_db()
        if db is None:
            return None
        try:
            conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        except sqlite3.OperationalError:
            return None
        own_conn = True
    try:
        row = conn.execute(
            "SELECT file_id FROM places WHERE folder_kind = ? LIMIT 1",
            (_FOLDER_KIND_USER_LIBRARY,),
        ).fetchone()
        if row is None:
            return None
        return _build_path(conn, int(row[0]))
    finally:
        if own_conn:
            conn.close()


def find_redundant_adv() -> tuple[Path | None, list[tuple[Path, str]]]:
    """Find ``.adv`` files in the User Library shadowed by an ``.amxd``.

    Returns a tuple ``(user_library_path, matches)`` where ``matches`` is
    a list of ``(adv_path, amxd_name)`` pairs. ``user_library_path`` is
    ``None`` if the DB or User Library couldn't be located — in that
    case ``matches`` is empty.

    Only ``.adv`` files whose stem matches an indexed ``.amxd`` (case-
    insensitive, anywhere in the index) are returned, and only when the
    ``.adv`` lives inside the User Library subtree. Factory presets
    bundled in Live.app are never touched.
    """
    db = _find_live_files_db()
    if db is None:
        return None, []

    try:
        conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    except sqlite3.OperationalError:
        return None, []

    try:
        user_lib_row = conn.execute(
            "SELECT file_id FROM places WHERE folder_kind = ? LIMIT 1",
            (_FOLDER_KIND_USER_LIBRARY,),
        ).fetchone()
        if user_lib_row is None:
            return None, []
        user_lib_id = int(user_lib_row[0])
        user_lib_path = _build_path(conn, user_lib_id)

        # Map .amxd stems to their canonical filename (for reporting).
        amxd_by_stem: dict[str, str] = {}
        for (name,) in conn.execute(
            "SELECT name FROM files WHERE file_type = ?",
            (_FILE_TYPE_AMXD,),
        ):
            stem = Path(name).stem.lower()
            # First-seen wins; arbitrary but deterministic enough for reports.
            amxd_by_stem.setdefault(stem, name)
        if not amxd_by_stem:
            return user_lib_path, []

        # All .adv files in the User Library subtree.
        adv_rows = conn.execute(
            """
            SELECT f.file_id, f.name
              FROM files f
              JOIN ancestors a ON a.file_id = f.file_id
             WHERE f.file_type = ?
               AND a.ancestor_id = ?
            """,
            (_FILE_TYPE_ADV, user_lib_id),
        ).fetchall()

        matches: list[tuple[Path, str]] = []
        for file_id, name in adv_rows:
            stem = Path(name).stem.lower()
            amxd_name = amxd_by_stem.get(stem)
            if amxd_name is None:
                continue
            adv_path = _build_path(conn, int(file_id))
            if adv_path is None or not adv_path.exists():
                continue
            matches.append((adv_path, amxd_name))

        # Stable order: by path.
        matches.sort(key=lambda pair: str(pair[0]).lower())
        return user_lib_path, matches
    finally:
        conn.close()
