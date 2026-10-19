#!/usr/bin/python3

import importlib
import os
from pathlib import Path
import plistlib
import sqlite3
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

sys.dont_write_bytecode = True

REPO_ROOT = Path(__file__).resolve().parents[1]
HOOK_ROOT = REPO_ROOT / "Resources/PostHooks/VSTCleanup"
sys.path.insert(0, str(HOOK_ROOT))

import macpack_hook


class VSTHookTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cleaner, cls.compatibility_tree = macpack_hook._load_canonical_cleaner()
        cls.fabfilter = importlib.import_module("specifics.fabfilter")
        cls.revoice = importlib.import_module("specifics.revoice")
        cls.ableton = importlib.import_module("specifics.ableton_dedup")

    @classmethod
    def tearDownClass(cls):
        cls.compatibility_tree.cleanup()

    def test_exact_preference_exceptions_are_preserved(self):
        self.assertEqual(self.cleaner.NEVER_REMOVE, {"vsx", "melodyne"})
        self.assertEqual(
            self.cleaner.PREFER_VST3,
            {"stellarizer", "glitchwork", "textureloom"},
        )

    def test_fabfilter_old_family_version_is_obsolete(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            components = root / "Components"
            vst3 = root / "VST3"
            components.mkdir()
            vst3.mkdir()
            old = components / "FabFilter Pro-Q 2.component"
            current = vst3 / "FabFilter Pro-Q 4.vst3"
            old.mkdir()
            current.mkdir()

            obsolete = self.fabfilter.find_obsolete([components, vst3])

            self.assertIn(old, obsolete)
            self.assertNotIn(current, obsolete)

    def test_fabfilter_vst2_variant_requires_vst3_base(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            vst2 = root / "VST"
            vst3 = root / "VST3"
            vst2.mkdir()
            vst3.mkdir()
            removable = vst2 / "FabFilter Pro-G (Mono).vst"
            retained = vst2 / "FabFilter One (SC).vst"
            base = vst3 / "FabFilter Pro-G.vst3"
            removable.mkdir()
            retained.mkdir()
            base.mkdir()

            obsolete = self.fabfilter.find_obsolete([vst2, vst3])

            self.assertIn(removable, obsolete)
            self.assertNotIn(retained, obsolete)

    def test_revoice_legacy_requires_modern_link(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            legacy = root / "Revoice Pro Link (Legacy).vst3"
            monitor = root / "Revoice Pro Monitor.vst3"
            legacy.mkdir()
            monitor.mkdir()

            self.assertEqual(self.revoice.find_obsolete([root]), [])

            modern = root / "RevoiceProLink.component"
            modern.mkdir()
            obsolete = self.revoice.find_obsolete([root])

            self.assertEqual(obsolete, [legacy])
            self.assertNotIn(monitor, obsolete)

    def test_ableton_match_accepts_vendor_prefix_but_not_suffix(self):
        matcher = self.ableton._stem_matches_name
        self.assertTrue(matcher("fabfilter pro-q 4", "pro-q 4"))
        self.assertTrue(matcher("pro-q 4", "pro-q 4"))
        self.assertFalse(matcher("pro-q 4 midi fx", "pro-q 4"))

    def test_package_bom_finds_only_exact_au_vst3_pairs(self):
        stems = macpack_hook._plugin_stems_from_bom_output(
            """
            ./Library/Audio/Plug-Ins/Components/Lucid.component/Contents/Info.plist
            ./Library/Audio/Plug-Ins/VST3/Lucid.vst3/Contents/MacOS/Lucid
            ./Library/Audio/Plug-Ins/VST3/Only VST3.vst3/Contents/Info.plist
            """
        )
        self.assertEqual(stems[".component"], {"lucid"})
        self.assertEqual(stems[".vst3"], {"lucid", "only vst3"})
        self.assertEqual(stems[".component"] & stems[".vst3"], {"lucid"})

    def test_fresh_install_bridge_keeps_protected_exceptions(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            components = root / "Components"
            vst3 = root / "VST3"
            user_components = root / "User Components"
            user_vst3 = root / "User VST3"
            cleaned = root / "Cleaned"
            for folder in (components, vst3, user_components, user_vst3):
                folder.mkdir()

            for stem in ("Lucid", "Stellarizer", "VSX", "Melodyne"):
                (components / f"{stem}.component").mkdir()
                (vst3 / f"{stem}.vst3").mkdir()

            keys = (
                "SYSTEM_COMPONENTS_PATH",
                "USER_COMPONENTS_PATH",
                "SYSTEM_VST3_PATH",
                "USER_VST3_PATH",
                "VST3_CLEANED_PATH",
            )
            original = {key: getattr(self.cleaner, key) for key in keys}
            try:
                self.cleaner.SYSTEM_COMPONENTS_PATH = components
                self.cleaner.USER_COMPONENTS_PATH = user_components
                self.cleaner.SYSTEM_VST3_PATH = vst3
                self.cleaner.USER_VST3_PATH = user_vst3
                self.cleaner.VST3_CLEANED_PATH = cleaned

                moved, _ = macpack_hook._move_fresh_vst3_pairs(
                    self.cleaner,
                    {"lucid", "stellarizer", "vsx", "melodyne"},
                )
            finally:
                for key, value in original.items():
                    setattr(self.cleaner, key, value)

            self.assertEqual(moved, ["Lucid.vst3"])
            self.assertTrue((cleaned / "Lucid.vst3").exists())
            self.assertTrue((vst3 / "Stellarizer.vst3").exists())
            self.assertTrue((vst3 / "VSX.vst3").exists())
            self.assertTrue((vst3 / "Melodyne.vst3").exists())

    def test_password_cache_is_not_vendored(self):
        self.assertFalse((HOOK_ROOT / ".cache").exists())
        self.assertEqual(list(HOOK_ROOT.rglob(".cache")), [])

    def test_unreadable_ableton_database_does_not_abort_remaining_cleanup(self):
        diagnostics = Mock(side_effect=sqlite3.OperationalError("unable to open database file"))
        matches = Mock(side_effect=sqlite3.OperationalError("unable to open database file"))
        cleaner = SimpleNamespace(
            ableton_diagnostics=diagnostics,
            find_vst3_shadowed_by_au=matches,
            subprocess=SimpleNamespace(run=macpack_hook._ORIGINAL_SUBPROCESS_RUN),
            list_recent_plugins=Mock(),
            configure_crash_reporter=Mock(),
        )
        remaining_cleanup = Mock()

        def clean():
            self.assertIn("error", cleaner.ableton_diagnostics())
            self.assertEqual(cleaner.find_vst3_shadowed_by_au(), (None, []))
            remaining_cleanup()

        cleaner.main = clean
        compatibility_tree = Mock()
        with (
            patch.object(macpack_hook.os, "geteuid", return_value=0),
            patch.dict(os.environ, {
                "MACPACK_CLEANED_PLUGIN_PATH": "/test/recovery",
                "MACPACK_LOGIN_USER": "test-user",
                "MACPACK_PACKAGE_PATH": "/test/Example.pkg",
            }),
            patch.object(macpack_hook, "_load_canonical_cleaner", return_value=(cleaner, compatibility_tree)),
            patch.object(macpack_hook, "_package_plugin_pair_stems", return_value=set()),
            patch.object(macpack_hook, "_move_fresh_vst3_pairs") as fresh_cleanup,
        ):
            self.assertEqual(macpack_hook.main(), 0)

        remaining_cleanup.assert_called_once()
        fresh_cleanup.assert_called_once_with(cleaner, set())
        cleaner.list_recent_plugins.assert_called_once()
        cleaner.configure_crash_reporter.assert_called_once_with(enable=False)
        compatibility_tree.cleanup.assert_called_once()
        self.assertIs(cleaner.ableton_diagnostics, diagnostics)
        self.assertIs(cleaner.find_vst3_shadowed_by_au, matches)

    def test_readable_ableton_database_keeps_canonical_matches(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            components = root / "Components"
            vst3 = root / "VST3" / "Lucid.vst3"
            info = components / "Lucid.component" / "Contents" / "Info.plist"
            info.parent.mkdir(parents=True)
            vst3.mkdir(parents=True)
            info.write_bytes(plistlib.dumps({"AudioComponents": [{
                "type": "aufx", "subtype": "Lcid", "manufacturer": "Test",
            }]}))

            database = root / "Live-files-12300.db"
            au_type, subtype, manufacturer = (
                int.from_bytes(value.encode("ascii"), "big")
                for value in ("aufx", "Lcid", "Test")
            )
            with sqlite3.connect(database) as connection:
                connection.execute("CREATE TABLE files (name TEXT, device_id TEXT)")
                connection.executemany("INSERT INTO files VALUES (?, ?)", [
                    ("Lucid", f"device:au:cat:{manufacturer}:{subtype}:{au_type}"),
                    ("Lucid", "device:vst3:Lucid"),
                ])

            with patch.multiple(
                self.ableton,
                ABLETON_DB_DIR=root,
                _SYSTEM_COMPONENTS=components,
                _USER_COMPONENTS=root / "User Components",
                _SYSTEM_VST3=vst3.parent,
                _USER_VST3=root / "User VST3",
            ):
                diagnostics = macpack_hook._ableton_diagnostics_or_skip(
                    self.cleaner.ableton_diagnostics
                )
                matches = macpack_hook._ableton_matches_or_skip(
                    self.cleaner.find_vst3_shadowed_by_au
                )

            self.assertEqual(diagnostics["vst3_to_move_after_match"], 1)
            self.assertEqual(matches, (database, [vst3]))


if __name__ == "__main__":
    unittest.main()
