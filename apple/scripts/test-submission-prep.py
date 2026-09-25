#!/usr/bin/env python3
"""Focused fail-closed checks for local submission artifacts."""
import copy
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = Path(__file__).with_name("verify-submission-prep.py")


class SubmissionPrepTests(unittest.TestCase):
    def module(self):
        spec = importlib.util.spec_from_file_location("submission_prep", SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_actual_local_preparation_passes_but_distribution_stays_blocked(self):
        result = subprocess.run([sys.executable, str(SCRIPT), str(ROOT)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["local_preparation"], "PASS")
        self.assertEqual(report["distribution"], "BLOCKED")

    def test_settings_reject_development_release_and_inconsistent_identifiers(self):
        spec = importlib.util.spec_from_file_location("submission_prep", SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        base = {"PetalChecklist": {"PETAL_APS_ENVIRONMENT": "production", "APP_BUNDLE_IDENTIFIER": "com.petalchecklist.mac",
            "WIDGET_BUNDLE_IDENTIFIER": "com.petalchecklist.mac.widgets", "APP_GROUP_IDENTIFIER": "group.com.petalchecklist.shared",
            "ICLOUD_CONTAINER_IDENTIFIER": "iCloud.com.petalchecklist", "PRODUCT_BUNDLE_IDENTIFIER": "com.petalchecklist.mac",
            "CODE_SIGN_ENTITLEMENTS": "PetalChecklist/PetalChecklist.entitlements", "DEVELOPMENT_TEAM": "", "PETAL_FEEDBACK_EMAIL": ""},
            "PetalWidgets": {"PETAL_APS_ENVIRONMENT": "production", "APP_BUNDLE_IDENTIFIER": "com.petalchecklist.mac",
            "WIDGET_BUNDLE_IDENTIFIER": "com.petalchecklist.mac.widgets", "APP_GROUP_IDENTIFIER": "group.com.petalchecklist.shared",
            "ICLOUD_CONTAINER_IDENTIFIER": "iCloud.com.petalchecklist", "PRODUCT_BUNDLE_IDENTIFIER": "com.petalchecklist.mac.widgets",
            "CODE_SIGN_ENTITLEMENTS": "PetalWidgets/PetalWidgets.entitlements", "DEVELOPMENT_TEAM": "", "PETAL_FEEDBACK_EMAIL": ""}}
        debug = copy.deepcopy(base)
        for row in debug.values(): row["PETAL_APS_ENVIRONMENT"] = "development"
        self.assertEqual(module.settings_errors(base, debug), [])
        broken = copy.deepcopy(base); broken["PetalWidgets"]["PETAL_APS_ENVIRONMENT"] = "development"
        self.assertTrue(module.settings_errors(broken, debug))
        broken = copy.deepcopy(base); broken["PetalWidgets"]["APP_GROUP_IDENTIFIER"] = "group.other"
        self.assertTrue(module.settings_errors(broken, debug))
        broken = copy.deepcopy(base); broken["PetalWidgets"]["ICLOUD_CONTAINER_IDENTIFIER"] = "iCloud.other"
        self.assertTrue(module.settings_errors(broken, debug))
        broken = copy.deepcopy(base); broken["PetalChecklist"]["WIDGET_BUNDLE_IDENTIFIER"] = "com.other.widget"
        self.assertTrue(module.settings_errors(broken, debug))

    def test_metadata_and_gate_mutations_fail_closed(self):
        module = self.module()
        metadata = {locale: (ROOT / f"docs/release/app-store-metadata-{locale}.md").read_text()
            for locale in ("en", "zh-Hans")}
        readiness = (ROOT / "docs/release/release-readiness.md").read_text()
        beta = (ROOT / "docs/validation/testflight-four-week-report.md").read_text()
        self.assertEqual(module.document_errors(metadata, readiness, beta), [])
        broken = dict(metadata); broken["en"] = broken["en"].replace("Support URL:", "Support link:")
        self.assertTrue(module.document_errors(broken, readiness, beta))
        broken = dict(metadata); broken["en"] = broken["en"].replace("Keywords: todo,desktop,reminders,notes,focus,organize", "Keywords: todo,xx")
        self.assertTrue(module.document_errors(broken, readiness, beta))
        broken = dict(metadata); broken["en"] = broken["en"].replace("PROPOSED / UNPUBLISHED / UNVERIFIED", "VERIFIED / PUBLISHED")
        self.assertTrue(module.document_errors(broken, readiness, beta))
        self.assertTrue(module.document_errors(metadata, readiness.replace("| Developer Program membership | BLOCKED |", "| Developer Program membership | PASS |"), beta))
        self.assertTrue(module.document_errors(metadata, readiness, beta.replace("Market gate: NOT RUN", "Market gate: PASS")))
        self.assertTrue(module.document_errors(metadata, readiness, beta.replace("| First 20 who added a desktop Widget | NOT RUN |", "| First 20 who added a desktop Widget | 14 |")))

    def test_empty_actual_metadata_fields_and_final_beta_decision_fail_closed(self):
        module = self.module()
        metadata = {locale: (ROOT / f"docs/release/app-store-metadata-{locale}.md").read_text()
            for locale in ("en", "zh-Hans")}
        readiness = (ROOT / "docs/release/release-readiness.md").read_text()
        beta = (ROOT / "docs/validation/testflight-four-week-report.md").read_text()
        for label in ("Subtitle", "Version notes"):
            with self.subTest(label=label):
                broken = dict(metadata)
                broken["en"], replacements = re.subn(r"(?m)^" + re.escape(label) + r": [^\n]+$", label + ":", broken["en"])
                self.assertEqual(replacements, 1)
                self.assertIn("en: missing " + label, module.document_errors(broken, readiness, beta))
        changed = beta.replace("Current decision: NOT RUN.", "Current decision: PASS.")
        self.assertNotEqual(changed, beta)
        self.assertIn("Beta decision falsely marked complete", module.document_errors(metadata, readiness, changed))

    def test_actual_effective_product_settings_and_selected_entitlements_fail_closed(self):
        module = self.module()
        release = module.build_rows(ROOT, "Release")
        debug = module.build_rows(ROOT, "Debug")
        self.assertEqual(module.settings_errors(release, debug), [])
        for configuration, rows in (("Release", release), ("Debug", debug)):
            with self.subTest(configuration=configuration, setting="PRODUCT_BUNDLE_IDENTIFIER"):
                broken = copy.deepcopy(rows)
                broken["PetalWidgets"]["PRODUCT_BUNDLE_IDENTIFIER"] = "com.other.app.widgets"
                args = (broken, debug) if configuration == "Release" else (release, broken)
                self.assertTrue(module.settings_errors(*args))
            with self.subTest(configuration=configuration, setting="CODE_SIGN_ENTITLEMENTS"):
                broken = copy.deepcopy(rows)
                broken["PetalWidgets"]["CODE_SIGN_ENTITLEMENTS"] = "PetalWidgets/Development.entitlements"
                args = (broken, debug) if configuration == "Release" else (release, broken)
                self.assertTrue(module.settings_errors(*args))
                self.assertTrue(module.entitlement_errors(ROOT, *args))
        self.assertEqual(module.entitlement_errors(ROOT, release, debug), [])


if __name__ == "__main__": unittest.main()
