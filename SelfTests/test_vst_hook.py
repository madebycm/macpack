#!/usr/bin/python3

import importlib
from pathlib import Path
import sys
import tempfile
import unittest

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
        self.assertEqual(self.cleaner.NEVER_REMOVE, {"vsx"})
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

            for stem in ("Lucid", "Stellarizer", "VSX"):
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
                    {"lucid", "stellarizer", "vsx"},
                )
            finally:
                for key, value in original.items():
                    setattr(self.cleaner, key, value)

            self.assertEqual(moved, ["Lucid.vst3"])
            self.assertTrue((cleaned / "Lucid.vst3").exists())
            self.assertTrue((vst3 / "Stellarizer.vst3").exists())
            self.assertTrue((vst3 / "VSX.vst3").exists())

    def test_password_cache_is_not_vendored(self):
        self.assertFalse((HOOK_ROOT / ".cache").exists())
        self.assertEqual(list(HOOK_ROOT.rglob(".cache")), [])


if __name__ == "__main__":
    unittest.main()
