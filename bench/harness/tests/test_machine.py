import unittest

from harness import machine


class MachineTests(unittest.TestCase):
    def test_pressure_is_read_from_powermetrics(self):
        text = "*** Sampled system activity ***\n\n**** Thermal pressure ****\n\nCurrent pressure level: Moderate\n"
        self.assertEqual(machine.parse_pressure(text), "Moderate")
        self.assertIsNone(machine.parse_pressure("no thermal section"))

    def test_hotter_follows_the_pressure_order(self):
        self.assertTrue(machine.hotter("Heavy", "Moderate"))
        self.assertFalse(machine.hotter("Nominal", "Nominal"))
        self.assertFalse(machine.hotter("Moderate", "Heavy"))
        # Unreadable is never treated as hot: the run goes on and records it.
        self.assertFalse(machine.hotter(None, "Nominal"))

    def test_spotlight_state_per_volume(self):
        text = (
            "/:\n\tIndexing enabled. \n"
            "/System/Volumes/Data:\n\tIndexing enabled. \n"
            "/Volumes/Backup:\n\tIndexing disabled.\n"
        )
        self.assertEqual(machine.parse_mdutil(text), {
            "/": True, "/System/Volumes/Data": True, "/Volumes/Backup": False,
        })

    def test_competing_servers_are_recognised_by_executable(self):
        for name, path in [
            ("Quail", "/Applications/Quail.app/Contents/MacOS/Quail"),
            ("quail-server", "/Applications/Quail.app/Contents/MacOS/quail-server"),
            ("llama-server", "/opt/llama/llama-server"),
            ("ollama", "/usr/local/bin/ollama"),
        ]:
            self.assertTrue(machine.COMPETITORS[name].search(path), path)
        self.assertFalse(machine.COMPETITORS["Quail"].search("/Applications/QuailHelper.app/Contents/MacOS/X"))


if __name__ == "__main__":
    unittest.main()
