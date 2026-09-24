#!/usr/bin/env python3
"""Exercise failure propagation using a copied release driver and controlled tools."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

class ReleaseDriverTests(unittest.TestCase):
    def testFailedUpstreamTestCannotBeReportedAsSuccessfulRelease(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "apple"; scripts = root / "scripts"; scripts.mkdir(parents=True)
            driver = scripts / "verify-release.sh"
            shutil.copyfile(Path(__file__).with_name("verify-release.sh"), driver)
            (scripts / "test.sh").write_text("#!/bin/zsh\nexit 41\n")
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            subprocess.run(["git", "-C", str(root), "add", "."], check=True)
            subprocess.run(["git", "-C", str(root), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "fixture"], check=True)
            # Missing later tools also fail closed; the actual failed test must be retained in evidence.
            result = subprocess.run(["zsh", str(driver)], capture_output=True, text=True, timeout=15)
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn("tests: FAIL", result.stdout)

if __name__ == "__main__": unittest.main()
