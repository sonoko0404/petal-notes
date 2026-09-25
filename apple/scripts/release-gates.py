#!/usr/bin/env python3
"""Closed release decisions; manual observations never default to passed."""
import argparse
import json
import math
import pathlib
import plistlib
import re
import subprocess

BUDGETS = {"search_ms": 300, "widget_save_ms": 1000, "cold_editable_ms": 2000, "hot_focus_ms": 300}
OPTIONAL_UI_METRICS = {"cold_editable_ms", "hot_focus_ms"}
def settings_errors(rows):
    errors = []
    targets = {item["target"]: item["buildSettings"] for item in rows}
    for name in ["PetalChecklist", "PetalWidgets"]:
        settings = targets.get(name, {})
        expected = {"MACOSX_DEPLOYMENT_TARGET": "14.0", "SWIFT_VERSION": "6.0", "SWIFT_STRICT_CONCURRENCY": "complete",
            "ENABLE_APP_SANDBOX": "YES", "SWIFT_OPTIMIZATION_LEVEL": "-O", "SWIFT_COMPILATION_MODE": "wholemodule",
            "CODE_SIGN_ENTITLEMENTS": name + "/" + name + ".entitlements", "APP_GROUP_IDENTIFIER": "group.com.petalchecklist.shared",
            "ICLOUD_CONTAINER_IDENTIFIER": "iCloud.com.petalchecklist", "PETAL_APS_ENVIRONMENT": "production"}
        for key, value in expected.items():
            if settings.get(key) != value: errors.append(name + ": invalid " + key)
    return errors
def bundle_errors(architectures, info, widget=False):
    errors = []
    if set(architectures) != {"arm64", "x86_64"}: errors.append("Missing universal architecture")
    expected = {"CFBundleIdentifier": "com.petalchecklist.mac.widgets" if widget else "com.petalchecklist.mac",
        "CFBundleExecutable": "PetalWidgets" if widget else "PetalChecklist", "LSMinimumSystemVersion": "14.0",
        "PetalAppGroupIdentifier": "group.com.petalchecklist.shared", "PetalCloudContainerIdentifier": "iCloud.com.petalchecklist"}
    for key, value in expected.items():
        if info.get(key) != value: errors.append("Invalid " + key)
    if widget and info.get("NSExtension", {}).get("NSExtensionPointIdentifier") != "com.apple.widgetkit-extension":
        errors.append("Missing Widget extension point")
    return errors

def dependency_errors(source):
    allowed = {"Foundation", "SwiftUI", "AppKit", "WidgetKit", "AppIntents", "CloudKit", "SwiftData", "Observation",
        "Darwin", "CryptoKit", "UserNotifications", "UniformTypeIdentifiers", "Carbon", "Combine", "CoreGraphics", "OSLog",
        "PetalCore", "PetalPersistence", "PetalSync", "PetalActions", "PetalNotifications", "PetalImportExport", "PetalDesignSystem"}
    errors = ["Unreviewed module " + name for name in re.findall(r"^\s*(?:@preconcurrency\s+)?import\s+(\w+)", source, re.M) if name not in allowed]
    if re.search(r"\b(?:URLSession|URLRequest|NWConnection|NSURLConnection)\b|\.package\s*\(\s*url:", source):
        errors.append("Unreviewed network client or external package")
    if re.search(r"\b(?:volumeAvailableCapacityKey|volumeAvailableCapacityForImportantUsageKey|volumeAvailableCapacityForOpportunisticUsageKey|volumeTotalCapacityKey|systemFreeSize|systemSize|statfs|statvfs|fstatfs|fstatvfs|activeInputModes)\b", source):
        errors.append("New required-reason category needs source and manifest review")
    return errors

def privacy_errors(value, widget=False, package=None):
    expected = {"FileTimestamp": {"C617.1"}, "UserDefaults": {"1C8F.1"}}
    if not widget:
        expected["UserDefaults"].add("CA92.1")
        expected["SystemBootTime"] = {"35F9.1"}
    if package == "PetalPersistence": expected = {"FileTimestamp": {"C617.1"}}
    elif package == "PetalActions": expected = {"UserDefaults": {"1C8F.1"}}
    errors = []
    keys = {"NSPrivacyTracking", "NSPrivacyTrackingDomains", "NSPrivacyCollectedDataTypes", "NSPrivacyAccessedAPITypes"}
    if not isinstance(value, dict) or set(value) != keys: return ["Unexpected privacy schema"]
    if value["NSPrivacyTracking"] is not False: errors.append("Tracking must be explicitly false")
    if value["NSPrivacyTrackingDomains"] != [] or value["NSPrivacyCollectedDataTypes"] != []:
        errors.append("Developer collection/tracking contradicts audited local/private-iCloud architecture")
    actual = {}
    try:
        for item in value["NSPrivacyAccessedAPITypes"]:
            if set(item) != {"NSPrivacyAccessedAPIType", "NSPrivacyAccessedAPITypeReasons"}: raise ValueError()
            if not item["NSPrivacyAccessedAPIType"].startswith("NSPrivacyAccessedAPICategory"): raise ValueError()
            name = item["NSPrivacyAccessedAPIType"].removeprefix("NSPrivacyAccessedAPICategory")
            codes = item["NSPrivacyAccessedAPITypeReasons"]
            if name in actual or not isinstance(codes, list) or len(set(codes)) != len(codes): raise ValueError()
            actual[name] = set(codes)
        if actual != expected: errors.append("Required reasons differ from reviewed source/dependency inventory")
    except (TypeError, ValueError, KeyError, AttributeError): errors.append("Invalid required-reason schema")
    return errors

def performance(runs):
    if len(runs) != 3: raise ValueError("Exactly three consecutive Release runs required")
    result = {}
    for name, limit in BUDGETS.items():
        values = [row.get(name) for row in runs]
        for value in values:
            if value is None and name not in OPTIONAL_UI_METRICS:
                raise ValueError("Missing required duration: " + name)
            if value is not None and (type(value) not in (int, float) or not math.isfinite(value) or value < 0):
                raise ValueError("Invalid duration: " + name)
        result[name] = "BLOCKED" if None in values else "FAIL" if all(v >= limit for v in values) else "PASS"
    return result

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["privacy", "performance", "source", "archive", "settings"])
    parser.add_argument("paths", nargs="+")
    args = parser.parse_args()
    if args.mode == "settings":
        root = pathlib.Path(args.paths[0])
        result = subprocess.run(["xcodebuild", "-showBuildSettings", "-json", "-project", str(root / "PetalChecklist.xcodeproj"),
            "-alltargets", "-configuration", "Release", "CODE_SIGNING_ALLOWED=NO"], check=True, capture_output=True, text=True)
        rows = json.loads(result.stdout); errors = settings_errors(rows); entitlement_report = {}
        for name in ["PetalChecklist", "PetalWidgets"]:
            with (root / name / (name + ".entitlements")).open("rb") as stream: entitlements = plistlib.load(stream)
            expected = {"com.apple.developer.aps-environment": "$(PETAL_APS_ENVIRONMENT)", "com.apple.security.app-sandbox": True,
                "com.apple.security.application-groups": ["$(APP_GROUP_IDENTIFIER)"],
                "com.apple.developer.icloud-container-identifiers": ["$(ICLOUD_CONTAINER_IDENTIFIER)"],
                "com.apple.developer.icloud-services": ["CloudKit"]}
            if name == "PetalChecklist": expected["com.apple.security.files.user-selected.read-write"] = True
            if entitlements != expected: errors.append(name + ": entitlement review required")
            entitlement_report[name] = entitlements
        print(json.dumps({"settings": "FAIL" if errors else "PASS", "errors": errors, "configuredEntitlements": entitlement_report,
            "buildSettings": rows, "signing": "Unsigned local validation only; configured entitlements are not provisioned entitlements"}, indent=2))
        return bool(errors)
    if args.mode == "source":
        root = pathlib.Path(args.paths[0]); failures = []; inventory = []
        for base in [root / "PetalChecklist", root / "PetalWidgets", root / "Packages/PetalKit/Sources"]:
            for path in sorted(base.rglob("*.swift")):
                if "PetalTestSupport" in path.parts: continue
                source = path.read_text()
                failures += [str(path.relative_to(root)) + ": " + x for x in dependency_errors(source)]
                for number, line in enumerate(source.splitlines(), 1):
                    if re.search(r"UserDefaults|@AppStorage|systemUptime|contentModificationDate|fileCreationDate|mach_absolute_time|statfs|volumeAvailableCapacity", line):
                        inventory.append({"source": str(path.relative_to(root)), "line": number, "API": line.strip()})
        package = root / "Packages/PetalKit/Package.swift"
        failures += dependency_errors(package.read_text().replace("import PackageDescription", ""))
        print(json.dumps({"source_audit": "FAIL" if failures else "PASS", "errors": failures, "required_API_inventory": inventory}, indent=2))
        return bool(failures)
    if args.mode == "archive":
        return archive_audit(pathlib.Path(args.paths[0]))
    if args.mode == "privacy":
        failures = []
        for name in args.paths:
            path = pathlib.Path(name)
            subprocess.run(["plutil", "-lint", str(path)], check=True)
            package = next((name for name in ["PetalPersistence", "PetalActions"] if name in str(path)), None)
            with path.open("rb") as stream: failures += privacy_errors(plistlib.load(stream), "PetalWidgets" in str(path), package)
        print(json.dumps({"privacy": "FAIL" if failures else "PASS", "errors": failures}, indent=2))
        return bool(failures)
    runs = []
    for name in args.paths:
        text = pathlib.Path(name).read_text()
        values = {}
        for key in BUDGETS:
            # Consume the entire value, not a numeric prefix (e.g. 1e9 or 250garbage).
            matches = re.findall(r"\bPETAL_PERF " + key + r"=([^\r\n]*)", text)
            if len(matches) > 1: raise ValueError("Repeated metric in run: " + key)
            if matches and not re.fullmatch(r"[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?", matches[0].strip()):
                raise ValueError("Malformed duration: " + key)
            values[key] = float(matches[0]) if matches else None
        if "** TEST SUCCEEDED **" not in text: raise ValueError("Unsuccessful Release test run: " + name)
        runs.append(values)
    result = performance(runs)
    print(json.dumps({"configuration": "Release", "budgets_ms": BUDGETS, "runs": runs, "results": result}, indent=2))
    return "FAIL" in result.values()

def archive_audit(archive):
    app = archive / "Products/Applications/PetalChecklist.app"
    widget = app / "Contents/PlugIns/PetalWidgets.appex"
    errors = []; products = []
    for bundle, extension in [(app, False), (widget, True)]:
        with (bundle / "Contents/Info.plist").open("rb") as stream: info = plistlib.load(stream)
        binary = bundle / "Contents/MacOS" / info["CFBundleExecutable"]
        architectures = subprocess.check_output(["xcrun", "lipo", "-archs", str(binary)], text=True).split()
        errors += bundle_errors(architectures, info, extension)
        manifest = bundle / "Contents/Resources/PrivacyInfo.xcprivacy"
        subprocess.run(["plutil", "-lint", str(manifest)], check=True, stdout=subprocess.DEVNULL)
        with manifest.open("rb") as stream: errors += privacy_errors(plistlib.load(stream), extension)
        for package in ["PetalPersistence", "PetalActions"]:
            resource = bundle / "Contents/Resources" / ("PetalKit_" + package + ".bundle/Contents/Resources/PrivacyInfo.xcprivacy")
            with resource.open("rb") as stream: errors += privacy_errors(plistlib.load(stream), package=package)
        for locale in ["en", "zh-Hans"]:
            for table in (["Widgets", "InfoPlist"] if extension else ["Localizable", "Widgets", "InfoPlist"]):
                resource = bundle / "Contents/Resources" / (locale + ".lproj") / (table + ".strings")
                if not resource.is_file(): errors.append("Missing localized resource: " + str(resource))
        for arch in architectures:
            build = subprocess.check_output(["xcrun", "vtool", "-arch", arch, "-show-build", str(binary)], text=True)
            if not re.search(r"minos\s+14\.0\b", build): errors.append(str(binary) + ": incorrect Mach-O deployment target")
        sign = subprocess.run(["codesign", "-dvv", "--entitlements", ":-", str(bundle)], capture_output=True, text=True)
        products.append({"product": bundle.name, "architectures": architectures, "minimumOS": info.get("LSMinimumSystemVersion"),
            "privacyManifest": str(manifest), "codesignExit": sign.returncode, "codesign": sign.stdout + sign.stderr,
            "provisioned": (bundle / "Contents/embedded.provisionprofile").exists()})
    libraries = []
    for binary in [app / "Contents/MacOS/PetalChecklist", widget / "Contents/MacOS/PetalWidgets"]:
        output = subprocess.check_output(["otool", "-L", str(binary)], text=True)
        libraries.append(output)
        for line in output.splitlines():
            if not line.startswith("\t"): continue
            library = line.strip().split(" ", 1)[0]
            if not library.startswith(("/System/Library/", "/usr/lib/", "@rpath/Petal")):
                errors.append("Unreviewed linked library: " + library)
        symbols = subprocess.check_output(["nm", "-u", str(binary)], text=True)
        if re.search(r"Firebase|Amplitude|Mixpanel|Sentry|NSURLSession|NSURLConnection", symbols, re.I):
            errors.append("Forbidden networking/analytics symbols: " + str(binary))
    manifests = [str(p.relative_to(app)) for p in app.rglob("PrivacyInfo.xcprivacy")]
    print(json.dumps({"archive": "FAIL" if errors else "PASS", "errors": errors, "products": products,
        "privacyManifestInventory": manifests, "linkedLibraries": libraries,
        "distribution": "BLOCKED: local unsigned/ad-hoc structural archive; no signing, provisioning, notarization or CloudKit entitlement validation"}, indent=2))
    return bool(errors)

if __name__ == "__main__": raise SystemExit(main())
