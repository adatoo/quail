import tomllib
import unittest

from harness import config, site


class SiteTests(unittest.TestCase):
    def test_every_cell_has_text_and_a_source(self):
        with open(config.CONFIG / "features.toml", "rb") as f:
            features = tomllib.load(f)
        for row in features["row"]:
            for key, _ in site.COLUMNS:
                cell = row[key]
                self.assertTrue(cell["text"], row["feature"])
                self.assertTrue(cell["source"].startswith("https://"), (row["feature"], key))
        html = site.features_html(features)
        self.assertEqual(html.count("<tr>"), len(features["row"]) + 1)
        self.assertEqual(html.count('class="src"'), 4 * len(features["row"]))

    def test_only_the_marked_block_changes(self):
        page = "<h1>Keep</h1>\n<!-- bench:results -->\nold\n<!-- /bench:results -->\n<p>Keep too</p>"
        out = site.replace_between(page, "results", "new")
        self.assertEqual(out, "<h1>Keep</h1>\n<!-- bench:results -->\nnew\n<!-- /bench:results -->\n<p>Keep too</p>")
        with self.assertRaises(ValueError):
            site.replace_between(page, "features", "x")

    def test_without_a_report_the_page_says_results_are_coming(self):
        self.assertIn("will appear here", site.results_html(None))


if __name__ == "__main__":
    unittest.main()
