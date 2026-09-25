#!/usr/bin/env python3
from pathlib import Path
import subprocess
import tempfile
import unittest

class DiagnosticAPIGateTests(unittest.TestCase):
    def testStringOverloadCannotSilentlyOpenTheEventBoundary(self):
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "Diagnostics.swift"
            source.write_text((root / "PetalChecklist/App/Diagnostics.swift").read_text() + '\nextension Diagnostics { func record(_ message: String) {} }\n')
            result = subprocess.run(["python3", str(root / "scripts/verify-diagnostics.py"), "--source", str(source)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn("content accepted", result.stdout)

if __name__ == "__main__": unittest.main()
