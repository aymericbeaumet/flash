#!/usr/bin/env python3

import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    "notices", Path(__file__).with_name("build-third-party-notices.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class NoticeTests(unittest.TestCase):
    def test_retains_aggregate_upstream_license_attributions(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Cargo.toml").write_text("")
            (root / "LICENSE").write_text("Copyright Alice, Bob and embedded library authors")
            package = {"name": "crypto-sys", "version": "1.0", "manifest_path": str(root / "Cargo.toml")}
            report = {
                "licenses": [{"id": "Apache-2.0", "text": "Canonical Apache text",
                              "used_by": [{"crate": package}]}],
                "crates": [{"package": package}],
            }
            notices = module.Notices()
            module.add_rust(notices, report)
            self.assertIn("Copyright Alice, Bob and embedded library authors", notices.render())

    def test_shared_license_keeps_every_attribution(self):
        notices = module.Notices()
        notices.add("crate-b 2.0", "Copyright Alice\nPermission granted.")
        notices.add("crate-a 1.0", "Copyright Alice\nPermission granted.")
        text = notices.render()
        self.assertIn("crate-a 1.0\ncrate-b 2.0", text)
        self.assertEqual(text.count("Copyright Alice"), 1)

    def test_distinct_copyrights_are_never_deduplicated(self):
        notices = module.Notices()
        notices.add("crate-a", "Copyright Alice\nMIT")
        notices.add("crate-b", "Copyright Bob\nMIT")
        self.assertIn("Copyright Alice", notices.render())
        self.assertIn("Copyright Bob", notices.render())

    def test_plugin_data_licences_ship_under_their_source(self):
        with tempfile.TemporaryDirectory() as directory:
            plugin = Path(directory) / "searchproviders"
            (plugin / "notices").mkdir(parents=True)
            (plugin / "notices" / "kagisearch-bangs-LICENSE").write_text("Copyright (c) Kagi\nMIT")
            notices = module.Notices()
            module.add_plugin_data(notices, plugin)
            module.add_plugin_data(notices, Path(directory) / "no-notices")
            text = notices.render()
            self.assertIn("Plugin data: searchproviders / kagisearch-bangs", text)
            self.assertIn("Copyright (c) Kagi", text)

    def test_empty_or_missing_inspector_text_refuses_release(self):
        for report in ([], [{"name": "svelte", "version": "1", "identifier": "MIT"}]):
            with self.assertRaises(ValueError):
                module.add_inspector(module.Notices(), report)


if __name__ == "__main__":
    unittest.main()
