"""Plugin usage reporting from Ableton Live's file database.

Live tracks ``use_count`` per file in ``Live-files-<version>.db`` (SQLite).
This module queries that database and prints the most-used plugins and
Max for Live devices in markdown-table format — useful for deciding
which plugins are workhorses vs install-and-forget.

Schema reference:
    table:  files
    cols:   use_count INTEGER, file_type INTEGER, name TEXT

File-type magic numbers (4-byte big-endian ASCII codes treated as int):
    1886156135  third-party plugin device file (VST3/AU)
    1634562093  Max for Live device (.amxd)
    1684434020  Live built-in device
    1633969965  .adg (Audio Device Group / Rack)
    1633973805  .adv (Audio Device preset)
    1634497325  .als (Live Set)
    2002875949  audio sample (.wav/.aif)
"""

import sqlite3
from pathlib import Path

ABLETON_DB_DIR = Path.home() / "Library/Application Support/Ableton/Live Database"

# File-type identifiers from Ableton's database.
_FILE_TYPE_PLUGIN = 1886156135   # third-party VST3/AU
_FILE_TYPE_AMXD = 1634562093     # Max for Live device
_FILE_TYPE_STOCK = 1684434020    # Live built-in device


def _find_live_files_db() -> Path | None:
    """Locate the most recent ``Live-files-NNNNN.db`` (highest version wins)."""
    if not ABLETON_DB_DIR.is_dir():
        return None
    candidates = sorted(
        ABLETON_DB_DIR.glob("Live-files-*.db"),
        key=lambda p: p.name,
    )
    return candidates[-1] if candidates else None


def _query_top(
    conn: sqlite3.Connection,
    file_type: int,
    min_count: int,
) -> list[tuple[int, str]]:
    """Return [(use_count, name), ...] for files with use_count > min_count."""
    rows = conn.execute(
        "SELECT use_count, name FROM files "
        "WHERE file_type = ? AND use_count > ? "
        "ORDER BY use_count DESC, name ASC",
        (file_type, min_count),
    ).fetchall()
    return [(int(c), str(n)) for c, n in rows]


def _print_table(title: str, header: str, rows: list[tuple[int, str]]) -> None:
    print(f"## {title}\n")
    if not rows:
        print(f"_(none with use_count > threshold)_\n")
        return
    print(f"| Uses | {header} |")
    print("|---:|---|")
    for count, name in rows:
        print(f"| {count} | {name} |")
    print(f"\n_{len(rows)} entries_\n")


def print_usage_report(min_count: int = 10) -> None:
    """Print markdown-style tables of most-used plugins and AMXDs.

    Args:
        min_count: Only include entries with use_count strictly greater
            than this value. Defaults to 10.
    """
    db = _find_live_files_db()
    if db is None:
        print(f"# Ableton usage report\n")
        print(f"Database not found at: {ABLETON_DB_DIR}")
        print("Has Live been launched on this machine?")
        return

    try:
        conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    except sqlite3.OperationalError as exc:
        print(f"Failed to open Ableton database: {exc}")
        return

    plugins = _query_top(conn, _FILE_TYPE_PLUGIN, min_count)
    amxds = _query_top(conn, _FILE_TYPE_AMXD, min_count)
    stock = _query_top(conn, _FILE_TYPE_STOCK, min_count)
    conn.close()

    print(f"# Ableton usage report\n")
    print(f"Source: `{db.name}`")
    print(f"Threshold: `use_count > {min_count}`\n")

    _print_table(
        f"Third-party plugins (use_count > {min_count})",
        "Plugin",
        plugins,
    )
    _print_table(
        f"Max for Live devices (use_count > {min_count})",
        "Device",
        amxds,
    )
    _print_table(
        f"Ableton stock devices (use_count > {min_count})",
        "Device",
        stock,
    )
