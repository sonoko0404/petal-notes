#!/usr/bin/env python3
"""Exercise failure propagation using a copied release driver and controlled tools."""
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import sys
import tempfile
import unittest

class ReleaseDriverTests(unittest.TestCase):
    def testInvalidPerformanceEvidenceStopsDriverBeforeBuildAndArchive(self):
        # Keep the real driver and performance parser; isolate expensive unrelated gates
        # and xcodebuild so malformed-log fixtures never invoke UI, signing or cloud work.
        cases = ["1e9", "250garbage", "-1", "NaN", "inf", "1e999", "", None]
        for key in ["search_ms", "widget_save_ms"]:
            for token in cases:
                with self.subTest(key=key, token=token), tempfile.TemporaryDirectory() as tmp:
                    root = Path(tmp) / "apple"; scripts = root / "scripts"; scripts.mkdir(parents=True)
                    for name in ["verify-release.sh", "release-gates.py"]:
                        shutil.copyfile(Path(__file__).with_name(name), scripts / name)
                    for name in ["test.sh", "verify-localization.sh"]:
                        (scripts / name).write_text("#!/bin/zsh\nexit 0\n")
                    subprocess.run(["git", "init", "-q", str(root)], check=True)
                    subprocess.run(["git", "-C", str(root), "add", "."], check=True)
                    subprocess.run(["git", "-C", str(root), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "fixture"], check=True)
                    bins = Path(tmp) / "bin"; bins.mkdir()
                    python = bins / "python3"
                    python.write_text('#!/bin/zsh\nif [[ "$1" == */release-gates.py && "$2" == performance ]]; then\n'
                        + 'exec ' + shlex.quote(sys.executable) + ' "$@"\nfi\nexit 0\n')
                    xcode = bins / "xcodebuild"
                    xcode.write_text('#!/bin/zsh\ncase "$1" in\n'
                        'test) print -r -- "$PERFORMANCE_LOG";;\n'
                        'build|clean|archive) print invoked >> "$BUILD_MARKER";;\nesac\n')
                    python.chmod(0o755); xcode.chmod(0o755)
                    values = {"search_ms": "250", "widget_save_ms": "300"}; values[key] = token
                    log = "".join("PETAL_PERF " + name + "=" + value + "\n" for name, value in values.items() if value is not None)
                    log += "** TEST SUCCEEDED **\n"
                    marker = Path(tmp) / "build-invoked"
                    env = dict(os.environ, PATH=str(bins) + os.pathsep + os.environ["PATH"],
                        PERFORMANCE_LOG=log, BUILD_MARKER=str(marker))
                    result = subprocess.run(["zsh", str(scripts / "verify-release.sh")], env=env,
                        capture_output=True, text=True, timeout=15)
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertIn("performance: FAIL", result.stdout)
                    self.assertNotIn("performance: PASS", result.stdout)
                    self.assertFalse(marker.exists(), result.stdout)

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
