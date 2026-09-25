#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("audit", Path(__file__).with_name("verify-accessibility.py"))
audit = importlib.util.module_from_spec(spec); spec.loader.exec_module(audit)
ROOT = Path(__file__).resolve().parents[1]

class AccessibilityGateTests(unittest.TestCase):
    def testProductionIconControlsMeetMinimumContract(self):
        self.assertEqual(audit.verify(ROOT), [])

    def testMissingLabelValueAndHitRegionAreRejected(self):
        source = '''Button { save() } label: { Image(systemName: "plus").frame(minWidth: 28, minHeight: 28).contentShape(Rectangle()) }
            .accessibilityLabel(Text("translated")) .accessibilityValue(Text("state"))'''
        self.assertEqual(audit.control_errors(source), [])
        for token in ["accessibilityLabel", "accessibilityValue", "contentShape", "frame"]:
            self.assertTrue(audit.control_errors(source.replace(token, "removed")), token)

    def testTinyHitRegionRejected(self):
        source = '''Button { save() } label: { Image(systemName: "plus").frame(width: 8, height: 8).contentShape(Rectangle()) }
            .accessibilityLabel(Text("translated")) .accessibilityValue(Text("state"))'''
        self.assertTrue(audit.control_errors(source))

if __name__ == "__main__": unittest.main()
