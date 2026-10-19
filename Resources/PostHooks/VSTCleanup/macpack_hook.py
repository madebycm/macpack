#!/usr/bin/python3
"""MacPack adapter for the canonical vst_cleaner.py implementation."""

from __future__ import annotations

import importlib
import os
from pathlib import Path
from pathlib import PurePosixPath
import subprocess
import sqlite3
import sys
import tempfile

_ORIGINAL_SUBPROCESS_RUN = subprocess.run
_ROOT_COMMANDS = {
    "cp": "/bin/cp",
    "mkdir": "/bin/mkdir",
    "mv": "/bin/mv",
}
_CANONICAL_FILES = (
    "vst_cleaner.py",
    "specifics/__init__.py",
    "specifics/ableton_dedup.py",
    "specifics/broken.py",
    "specifics/fabfilter.py",
    "specifics/m4l.py",
    "specifics/revoice.py",
    "specifics/usage.py",
)
_POSTPONED_ANNOTATIONS = b"from __future__ import annotations\n"
_PLUGIN_SUFFIXES = (".component", ".vst3")


def _load_canonical_cleaner():
    """Load the unchanged Python 3.10 source on Apple's Python 3.9."""
    source_root = Path(__file__).resolve().parent
    compatibility_tree = tempfile.TemporaryDirectory(prefix="macpack-vst-hook-")
    compatibility_root = Path(compatibility_tree.name)

    try:
        for relative_path in _CANONICAL_FILES:
            source = source_root / relative_path
            target = compatibility_root / relative_path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(_POSTPONED_ANNOTATIONS + source.read_bytes())

        sys.path.insert(0, str(compatibility_root))
        cleaner = importlib.import_module("vst_cleaner")
    except Exception:
        compatibility_tree.cleanup()
        raise

    return cleaner, compatibility_tree


def _run_root_command(
    command: list[str], timeout: int | None = None
) -> tuple[bool, str | None]:
    """Replace the cleaner's sudo retry with its already-root MacPack context."""
    if not command or command[0] not in _ROOT_COMMANDS:
        return False, "command is not allowed by the MacPack hook adapter"

    executable = _ROOT_COMMANDS[command[0]]
    try:
        result = _ORIGINAL_SUBPROCESS_RUN(
            [executable, *command[1:]],
            capture_output=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return False, f"command timed out after {timeout} seconds"
    except OSError as exc:
        return False, str(exc)

    if result.returncode == 0:
        return True, None
    output = (result.stderr or b"") + (result.stdout or b"")
    return False, output.decode(errors="ignore").strip() or "command failed"


def _run_user_defaults(command, *args, **kwargs):
    """Write CrashReporter preferences to the login user, not root's domain."""
    if (
        isinstance(command, (list, tuple))
        and command
        and Path(command[0]).name == "defaults"
    ):
        user_name = os.environ["MACPACK_LOGIN_USER"]
        command = [
            "/usr/bin/sudo",
            "-H",
            "-u",
            user_name,
            "/usr/bin/defaults",
            *command[1:],
        ]
    return _ORIGINAL_SUBPROCESS_RUN(command, *args, **kwargs)


def _plugin_stems_from_bom_output(output: str) -> dict[str, set[str]]:
    """Collect top-level AU/VST3 bundle stems from `lsbom -s` output."""
    stems = {suffix: set() for suffix in _PLUGIN_SUFFIXES}
    for line in output.splitlines():
        for component in PurePosixPath(line.strip()).parts:
            lowered = component.lower()
            for suffix in _PLUGIN_SUFFIXES:
                if lowered.endswith(suffix):
                    stems[suffix].add(lowered[: -len(suffix)])
                    break
    return stems


def _package_plugin_pair_stems(package_path: str) -> set[str]:
    """Return exact AU+VST3 stems proven to be payloads of this package."""
    package = Path(package_path)
    with tempfile.TemporaryDirectory(prefix="macpack-package-boms-") as temporary:
        bom_paths: list[Path] = []
        temporary_root = Path(temporary)

        if package.is_file():
            try:
                listing = _ORIGINAL_SUBPROCESS_RUN(
                    ["/usr/bin/xar", "-tf", str(package)],
                    capture_output=True,
                    text=True,
                    timeout=30,
                    check=False,
                )
            except (OSError, subprocess.TimeoutExpired):
                return set()
            if listing.returncode != 0:
                return set()

            entries = []
            for raw_entry in listing.stdout.splitlines():
                entry = PurePosixPath(raw_entry)
                if (
                    entry.name == "Bom"
                    and not entry.is_absolute()
                    and ".." not in entry.parts
                ):
                    entries.append(raw_entry)
            if not entries:
                return set()

            try:
                extraction = _ORIGINAL_SUBPROCESS_RUN(
                    [
                        "/usr/bin/xar",
                        "-xf",
                        str(package),
                        "-C",
                        str(temporary_root),
                        *entries,
                    ],
                    capture_output=True,
                    timeout=60,
                    check=False,
                )
            except (OSError, subprocess.TimeoutExpired):
                return set()
            if extraction.returncode != 0:
                return set()
            bom_paths = [temporary_root / entry for entry in entries]
        elif package.is_dir():
            bom_paths = list(package.rglob("Archive.bom"))

        collected = {suffix: set() for suffix in _PLUGIN_SUFFIXES}
        for bom_path in bom_paths:
            try:
                result = _ORIGINAL_SUBPROCESS_RUN(
                    ["/usr/bin/lsbom", "-s", str(bom_path)],
                    capture_output=True,
                    text=True,
                    timeout=30,
                    check=False,
                )
            except (OSError, subprocess.TimeoutExpired):
                continue
            if result.returncode != 0:
                continue
            stems = _plugin_stems_from_bom_output(result.stdout)
            for suffix in _PLUGIN_SUFFIXES:
                collected[suffix].update(stems[suffix])

    return collected[".component"] & collected[".vst3"]


def _move_fresh_vst3_pairs(vst_cleaner, packaged_pairs: set[str]):
    """Bridge Ableton's indexing lag only for format pairs in this package."""
    all_au_names = (
        vst_cleaner.get_au_names(vst_cleaner.SYSTEM_COMPONENTS_PATH)
        | vst_cleaner.get_au_names(vst_cleaner.USER_COMPONENTS_PATH)
    )
    eligible = (
        (packaged_pairs & all_au_names)
        - vst_cleaner.NEVER_REMOVE
        - vst_cleaner.PREFER_VST3
    )
    if not eligible:
        return [], 0

    moved = []
    bytes_moved = 0
    candidates = (
        vst_cleaner.list_bundles(vst_cleaner.SYSTEM_VST3_PATH, ".vst3")
        + vst_cleaner.list_bundles(vst_cleaner.USER_VST3_PATH, ".vst3")
    )
    for path in candidates:
        if vst_cleaner.plugin_base_name(path) not in eligible:
            continue
        if not vst_cleaner.ensure_dir(vst_cleaner.VST3_CLEANED_PATH):
            continue
        size = vst_cleaner.get_size(path)
        ok, error = vst_cleaner.move_path(path, vst_cleaner.VST3_CLEANED_PATH)
        if ok:
            moved.append(path.name)
            bytes_moved += size
        else:
            print(f"MacPack fresh-install VST3 cleanup failed: {path} -> {error}")

    if moved:
        print(
            f"MacPack fresh-install VST3 cleanup: moved {len(moved)} "
            f"plugin(s) ({vst_cleaner.human_size(bytes_moved)})"
        )
        for name in moved:
            print(f"  - {name}")
        print()
    return moved, bytes_moved


def _ableton_diagnostics_or_skip(diagnostics):
    try:
        return diagnostics()
    except sqlite3.Error as exc:
        return {"error": f"Live database unavailable: {exc}"}


def _ableton_matches_or_skip(find_matches):
    try:
        return find_matches()
    except sqlite3.Error as exc:
        print(f"MacPack skipped Ableton-aware VST3 cleanup: {exc}")
        return None, []


def main() -> int:
    if os.geteuid() != 0:
        print("MacPack VST cleanup must run inside the root installer helper.", file=sys.stderr)
        return 77

    recovery_path = os.environ.get("MACPACK_CLEANED_PLUGIN_PATH")
    login_user = os.environ.get("MACPACK_LOGIN_USER")
    package_path = os.environ.get("MACPACK_PACKAGE_PATH")
    if not recovery_path or not login_user:
        print("MacPack did not provide the hook user context.", file=sys.stderr)
        return 78

    vst_cleaner, compatibility_tree = _load_canonical_cleaner()
    packaged_pairs = _package_plugin_pair_stems(package_path) if package_path else set()

    # Keep the canonical cleaner byte-for-byte. These are the only integration
    # overrides: recoverable storage, no password cache, no nested sudo,
    # and skipping DB-dependent cleanup when Live's index cannot be read.
    vst_cleaner.DEFAULT_TMP_PATH = Path(recovery_path)
    vst_cleaner.CACHE_FILE = Path(recovery_path) / ".macpack-no-password-cache"
    vst_cleaner.run_with_sudo_retry = _run_root_command
    vst_cleaner.subprocess.run = _run_user_defaults
    original_diagnostics = vst_cleaner.ableton_diagnostics
    original_matches = vst_cleaner.find_vst3_shadowed_by_au
    vst_cleaner.ableton_diagnostics = lambda: _ableton_diagnostics_or_skip(
        original_diagnostics
    )
    vst_cleaner.find_vst3_shadowed_by_au = lambda: _ableton_matches_or_skip(
        original_matches
    )

    try:
        vst_cleaner.main()
        _move_fresh_vst3_pairs(vst_cleaner, packaged_pairs)
        vst_cleaner.list_recent_plugins()
        vst_cleaner.configure_crash_reporter(enable=False)
    finally:
        vst_cleaner.subprocess.run = _ORIGINAL_SUBPROCESS_RUN
        vst_cleaner.ableton_diagnostics = original_diagnostics
        vst_cleaner.find_vst3_shadowed_by_au = original_matches
        compatibility_tree.cleanup()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
