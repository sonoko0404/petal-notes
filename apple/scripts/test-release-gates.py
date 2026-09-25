#!/usr/bin/env python3
"""Independent adversarial fixtures for release decisions, not string-presence tests."""
import copy
import importlib.util
import json
import pathlib
import subprocess
import tempfile
import unittest
import sys
sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location("gates", pathlib.Path(__file__).with_name("release-gates.py"))
gates = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gates)

class ReleaseGatesTests(unittest.TestCase):
    def testBuildSettingsRequireBothTargetsAndStrictSwiftSix(self):
        rows = [{"target": name, "buildSettings": {"MACOSX_DEPLOYMENT_TARGET": "14.0", "SWIFT_VERSION": "6.0",
            "SWIFT_STRICT_CONCURRENCY": "complete", "ENABLE_APP_SANDBOX": "YES", "SWIFT_OPTIMIZATION_LEVEL": "-O",
            "SWIFT_COMPILATION_MODE": "wholemodule", "CODE_SIGN_ENTITLEMENTS": name + "/" + name + ".entitlements",
            "APP_GROUP_IDENTIFIER": "group.com.petalchecklist.shared", "ICLOUD_CONTAINER_IDENTIFIER": "iCloud.com.petalchecklist",
            "PETAL_APS_ENVIRONMENT": "production"}}
            for name in ["PetalChecklist", "PetalWidgets"]]
        self.assertEqual(gates.settings_errors(rows), [])
        self.assertTrue(gates.settings_errors(rows[:1]))
        for key in rows[0]["buildSettings"]:
            broken = copy.deepcopy(rows); broken[0]["buildSettings"][key] = "wrong"
            self.assertTrue(gates.settings_errors(broken), key)
        broken = copy.deepcopy(rows)
        broken[0]["buildSettings"]["PETAL_APS_ENVIRONMENT"] = "development"
        self.assertTrue(gates.settings_errors(broken), "Release APNs must reject development")
    def testPackagePrivacyDeclaresOnlyItsActualRequiredAPI(self):
        for package, category, reason in [("PetalPersistence", "FileTimestamp", "C617.1"), ("PetalActions", "UserDefaults", "1C8F.1")]:
            manifest = {"NSPrivacyTracking": False, "NSPrivacyTrackingDomains": [], "NSPrivacyCollectedDataTypes": [],
                "NSPrivacyAccessedAPITypes": [{"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategory" + category,
                    "NSPrivacyAccessedAPITypeReasons": [reason]}]}
            self.assertEqual(gates.privacy_errors(manifest, package=package), [])
            manifest["NSPrivacyAccessedAPITypes"] = []
            self.assertTrue(gates.privacy_errors(manifest, package=package))
    def testExternalSDKAndDirectNetworkClientRequireReview(self):
        self.assertEqual(gates.dependency_errors("import Foundation\nimport CloudKit\nimport PetalCore"), [])
        for source in ["import FirebaseAnalytics", "import UnknownSDK", "let client = URLSession.shared", '.package(url: "https://example.com/sdk", from: "1.0.0")']:
            self.assertTrue(gates.dependency_errors(source), source)
    def testNewUndeclaredRequiredReasonCategoryFailsReview(self):
        for source in ["let free = volumeAvailableCapacityKey", "let keyboards = activeInputModes", "statfs(path, &space)"]:
            self.assertTrue(gates.dependency_errors(source), source)

    def testPrivacyCategoryMustUseAppleSchemaName(self):
        manifest = self.manifest()
        manifest["NSPrivacyAccessedAPITypes"][0]["NSPrivacyAccessedAPIType"] = "FileTimestamp"
        self.assertTrue(gates.privacy_errors(manifest))
    def testBundleRejectsMissingSliceWrongOSAndMismatchedCapabilities(self):
        info = {"CFBundleIdentifier": "com.petalchecklist.mac", "CFBundleExecutable": "PetalChecklist",
            "LSMinimumSystemVersion": "14.0", "PetalAppGroupIdentifier": "group.com.petalchecklist.shared",
            "PetalCloudContainerIdentifier": "iCloud.com.petalchecklist"}
        self.assertEqual(gates.bundle_errors(["arm64", "x86_64"], info), [])
        self.assertTrue(gates.bundle_errors(["arm64"], info))
        for key in info:
            broken = dict(info); broken[key] = "wrong"
            self.assertTrue(gates.bundle_errors(["arm64", "x86_64"], broken), key)
        widget = dict(info, CFBundleIdentifier="com.petalchecklist.mac.widgets", CFBundleExecutable="PetalWidgets",
            NSExtension={"NSExtensionPointIdentifier": "com.apple.widgetkit-extension"})
        self.assertEqual(gates.bundle_errors(["arm64", "x86_64"], widget, True), [])
        del widget["NSExtension"]
        self.assertTrue(gates.bundle_errors(["arm64", "x86_64"], widget, True))
    def manifest(self, widget=False):
        reasons = {"FileTimestamp": ["C617.1"], "UserDefaults": ["1C8F.1"]}
        if not widget:
            reasons["UserDefaults"].append("CA92.1")
            reasons["SystemBootTime"] = ["35F9.1"]
        return {"NSPrivacyTracking": False, "NSPrivacyTrackingDomains": [], "NSPrivacyCollectedDataTypes": [],
            "NSPrivacyAccessedAPITypes": [{"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategory" + name,
                "NSPrivacyAccessedAPITypeReasons": codes} for name, codes in reasons.items()]}

    def testActualReasonsAreRequiredAndUnknownTrackingCollectionFailClosed(self):
        for widget in [True, False]:
            valid = self.manifest(widget)
            self.assertEqual(gates.privacy_errors(valid, widget), [])
            for key in valid:
                broken = copy.deepcopy(valid); del broken[key]
                self.assertTrue(gates.privacy_errors(broken, widget), key)
            for key, value in [("NSPrivacyTracking", True), ("NSPrivacyTracking", 0),
                ("NSPrivacyTrackingDomains", ["tracker.example"]), ("NSPrivacyCollectedDataTypes", [{}]),
                ("NSPrivacyAccessedAPITypes", []), ("unknown", "SECRET")]:
                broken = copy.deepcopy(valid); broken[key] = value
                self.assertTrue(gates.privacy_errors(broken, widget), key)
            broken = copy.deepcopy(valid)
            broken["NSPrivacyAccessedAPITypes"][0]["NSPrivacyAccessedAPITypeReasons"] = ["invented"]
            self.assertTrue(gates.privacy_errors(broken, widget))

    def runs(self, values):
        return [{"search_ms": x, "widget_save_ms": 20, "cold_editable_ms": None, "hot_focus_ms": None} for x in values]

    def testOnlyThreeConsecutiveRegressionsFailAndUnmeasuredUIIsBlocked(self):
        self.assertEqual(gates.performance(self.runs([301, 302, 303]))["search_ms"], "FAIL")
        self.assertEqual(gates.performance(self.runs([301, 299, 303]))["search_ms"], "PASS")
        self.assertEqual(gates.performance(self.runs([299, 298, 297]))["cold_editable_ms"], "BLOCKED")
        self.assertEqual(gates.performance(self.runs([299, 298, 297]))["widget_save_ms"], "PASS")
        with self.assertRaises(ValueError): gates.performance(self.runs([1, 2]))
        for value in [-1, float("nan"), float("inf"), "fast", True]:
            with self.assertRaises(ValueError): gates.performance(self.runs([1, 2, value]))

    def testAllFourBudgetsAreStrictAndMissingValuesNeverPass(self):
        for name, threshold in [("search_ms", 300), ("widget_save_ms", 1000), ("cold_editable_ms", 2000), ("hot_focus_ms", 300)]:
            runs = self.runs([1, 2, 3])
            for row in runs: row[name] = threshold
            self.assertEqual(gates.performance(runs)[name], "FAIL")
            runs[1][name] = None
            if name in ("search_ms", "widget_save_ms"):
                with self.assertRaises(ValueError): gates.performance(runs)
            else:
                self.assertEqual(gates.performance(runs)[name], "BLOCKED")

    def performanceCLI(self, logs):
        with tempfile.TemporaryDirectory() as tmp:
            paths = []
            for index, log in enumerate(logs):
                path = pathlib.Path(tmp) / (str(index) + ".log")
                path.write_text(log)
                paths.append(str(path))
            return subprocess.run([sys.executable, str(pathlib.Path(__file__).with_name("release-gates.py")),
                "performance", *paths], capture_output=True, text=True, timeout=10)

    def testCLIParsesWholeScientificValueAndPreservesThreeRunRule(self):
        log = "PETAL_PERF search_ms=1e9\nPETAL_PERF widget_save_ms=2.5e2\n** TEST SUCCEEDED **\n"
        result = self.performanceCLI([log] * 3)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        report = json.loads(result.stdout)
        self.assertEqual(report["runs"][0]["search_ms"], 1000000000)
        self.assertEqual(report["results"]["search_ms"], "FAIL")
        result = self.performanceCLI([log, log.replace("1e9", "2.5e2"), log])
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["results"]["search_ms"], "PASS")
        self.assertEqual(report["results"]["cold_editable_ms"], "BLOCKED")
        self.assertEqual(report["results"]["hot_focus_ms"], "BLOCKED")

    def testCLIRejectsInvalidOrMissingRequiredValueInAnyRun(self):
        valid = "PETAL_PERF search_ms=250\nPETAL_PERF widget_save_ms=300\n** TEST SUCCEEDED **\n"
        for key, original in [("search_ms", "250"), ("widget_save_ms", "300")]:
            for token in ["250garbage", "-1", "NaN", "inf", "1e999", "", "250 extra", "250_000"]:
                with self.subTest(key=key, token=token):
                    broken = valid.replace(key + "=" + original, key + "=" + token)
                    result = self.performanceCLI([valid, broken, valid])
                    self.assertNotEqual(result.returncode, 0, result.stdout)
            missing = valid.replace("PETAL_PERF " + key + "=" + original + "\n", "")
            for logs in [[missing] * 3, [valid, missing, valid]]:
                with self.subTest(key=key, missing=logs):
                    self.assertNotEqual(self.performanceCLI(logs).returncode, 0)
            for duplicate in [original, "NaN", "-1", ""]:
                with self.subTest(key=key, duplicate=duplicate):
                    result = self.performanceCLI([valid, valid + "PETAL_PERF " + key + "=" + duplicate + "\n", valid])
                    self.assertNotEqual(result.returncode, 0, result.stdout)

    def testCLIAllowsAbsentUIButRejectsPresentMalformedUIAndUnsuccessfulRun(self):
        valid = "PETAL_PERF search_ms=250\nPETAL_PERF widget_save_ms=300\n** TEST SUCCEEDED **\n"
        result = self.performanceCLI([valid] * 3)
        self.assertEqual(result.returncode, 0, result.stderr)
        for key in ["cold_editable_ms", "hot_focus_ms"]:
            for token in ["NaN", "-1", "250garbage", ""]:
                with self.subTest(key=key, token=token):
                    result = self.performanceCLI([valid, valid + "PETAL_PERF " + key + "=" + token + "\n", valid])
                    self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertNotEqual(self.performanceCLI([valid, valid.replace("** TEST SUCCEEDED **", "** TEST FAILED **"), valid]).returncode, 0)
        self.assertNotEqual(self.performanceCLI([valid, valid]).returncode, 0)

if __name__ == "__main__": unittest.main()
