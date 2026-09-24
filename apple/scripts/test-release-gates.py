#!/usr/bin/env python3
"""Independent adversarial fixtures for release decisions, not string-presence tests."""
import copy
import importlib.util
import pathlib
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
            "APP_GROUP_IDENTIFIER": "group.com.petalchecklist.shared", "ICLOUD_CONTAINER_IDENTIFIER": "iCloud.com.petalchecklist"}}
            for name in ["PetalChecklist", "PetalWidgets"]]
        self.assertEqual(gates.settings_errors(rows), [])
        self.assertTrue(gates.settings_errors(rows[:1]))
        for key in rows[0]["buildSettings"]:
            broken = copy.deepcopy(rows); broken[0]["buildSettings"][key] = "wrong"
            self.assertTrue(gates.settings_errors(broken), key)
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
            self.assertEqual(gates.performance(runs)[name], "BLOCKED")

if __name__ == "__main__": unittest.main()
