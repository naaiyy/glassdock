import sys
sys.dont_write_bytecode = True

import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest

root = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("refresh", root / "scripts/machines/guest/display-refresh.py")
refresh = importlib.util.module_from_spec(spec)
spec.loader.exec_module(refresh)


class DisplayRefreshTests(unittest.TestCase):
    def test_observed_spice_mode(self):
        state = """Screen 0: minimum 320 x 200, current 848 x 628, maximum 8192 x 8192
Virtual-1 connected primary 848x628+0+0 (normal)
   848x628       74.99 +
   848x628-0      0.06*
"""
        self.assertEqual(refresh.repairs(state), [("Virtual-1", 848, 628)])

    def test_healthy_and_unselected_modes_untouched(self):
        self.assertEqual(refresh.repairs("Virtual-1 connected 848x628+0+0\n   848x628-0 0.06\n   glassdock-848x628-60 59.82*\n"), [])

    def test_disconnected_output_ignored(self):
        self.assertEqual(refresh.repairs("Virtual-1 disconnected\n   848x628-0 0.06*\n"), [])

    def test_multiple_outputs_and_positions(self):
        state = "Virtual-1 connected 848x628+0+0\n 848x628-0 0.06*\nVirtual-2 connected 1920x1080+848+0\n 1920x1080-1 0.06*+\n"
        self.assertEqual(refresh.repairs(state), [("Virtual-1", 848, 628), ("Virtual-2", 1920, 1080)])

    def test_invalid_dimensions_and_rate(self):
        for mode in ["99999x628-0 0.06*", "848x628-0 nan*", "848x628-0 0.00*", "848x628-0 24.00*"]:
            self.assertEqual(refresh.repairs("Virtual-1 connected 848x628+0+0\n " + mode), [])

    def test_repair_uses_distribution_timings(self):
        calls = []
        def run(arguments, **options):
            calls.append(arguments)
            return SimpleNamespace(stdout='Modeline "848x628_60.00" 42.50 848 888 968 1088 628 631 641 653 -hsync +vsync\n')
        refresh.repair("Virtual-1", 848, 628, run)
        self.assertEqual(calls[0], ["cvt", "848", "628", "60"])
        self.assertEqual(calls[1][0:4], ["xrandr", "--newmode", "glassdock-848x628-60", "42.50"])
        self.assertEqual(calls[-1], ["xrandr", "--output", "Virtual-1", "--mode", "glassdock-848x628-60"])


if __name__ == "__main__":
    unittest.main()
