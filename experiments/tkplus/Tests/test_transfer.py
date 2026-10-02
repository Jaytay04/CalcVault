"""Compile and run the unchanged synthetic C fixture; never load a guest IPA."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class TransferFixtureTests(unittest.TestCase):
    def test_compiled_c11_fixture(self):
        compiler = shutil.which("clang")
        if compiler is None and os.name == "nt":
            candidate = Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "LLVM/bin/clang.exe"
            if candidate.is_file():
                compiler = str(candidate)
        if compiler is None:
            self.fail("C compilation NOT RUN: clang is required, not a passing skip.")

        experiment = Path(__file__).resolve().parents[1]
        # This directory holds only generated synthetic build output. Retain it
        # for inspection instead of deleting anything in the project.
        output_directory = Path(tempfile.mkdtemp(prefix="tkplus-transfer-"))
        executable = output_directory / ("transfer_tests.exe" if os.name == "nt" else "transfer_tests")
        compile_result = subprocess.run(
            [compiler, "-std=c11", "-Wall", "-Wextra", "-Wpedantic", "-Werror", "-DNDEBUG",
             str(experiment / "Core/TKPTransfer.c"), str(experiment / "Tests/transfer_tests.c"),
             "-o", str(executable)],
            capture_output=True, text=True, timeout=60, check=False,
        )
        self.assertEqual(compile_result.returncode, 0, compile_result.stdout + compile_result.stderr)
        run_result = subprocess.run(
            [str(executable)], capture_output=True, text=True, timeout=60, check=False,
        )
        self.assertEqual(run_result.returncode, 0, run_result.stdout + run_result.stderr)
        self.assertRegex(run_result.stdout.strip(), r"^PASS: [1-9][0-9]* checks$")
        print(run_result.stdout.strip())


if __name__ == "__main__":
    unittest.main()
