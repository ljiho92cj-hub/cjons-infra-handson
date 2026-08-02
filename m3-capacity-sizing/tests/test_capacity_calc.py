from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parents[1] / "capacity_calc.py"
SPEC = importlib.util.spec_from_file_location("capacity_calc", MODULE_PATH)
assert SPEC and SPEC.loader
capacity_calc = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(capacity_calc)


class CapacityCalcTest(unittest.TestCase):
    def test_workbook_golden_results(self) -> None:
        args = capacity_calc.build_parser().parse_args([])
        self.assertEqual(
            capacity_calc.workbook_results(args),
            {"cpu": 51, "memory": 118, "disk": 2320},
        )

    def test_default_csv_is_script_relative_and_valid(self) -> None:
        records = capacity_calc.load_series(capacity_calc.DEFAULT_DATA)
        self.assertEqual(len(records), 504)
        timestamps = [record["ts"] for record in records]
        self.assertEqual(len(timestamps), len(set(timestamps)))

    def test_cli_works_outside_module_directory(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            completed = subprocess.run(
                [sys.executable, str(MODULE_PATH), "--profile", "csv"],
                cwd=temp_dir,
                check=False,
                capture_output=True,
                text=True,
            )
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertIn("504 samples", completed.stdout)

    def test_zero_target_utilization_is_rejected(self) -> None:
        completed = subprocess.run(
            [sys.executable, str(MODULE_PATH), "--target-utilization", "0"],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(completed.returncode, 2)
        self.assertIn("ERROR:", completed.stdout)

    def test_percentile_boundaries(self) -> None:
        values = [1.0, 2.0, 3.0, 4.0]
        self.assertEqual(capacity_calc.percentile(values, 0), 1.0)
        self.assertEqual(capacity_calc.percentile(values, 100), 4.0)


if __name__ == "__main__":
    unittest.main()
