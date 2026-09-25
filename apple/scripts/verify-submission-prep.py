#!/usr/bin/env python3
"""Fail-closed local App Store draft audit. PASS never means ready to distribute."""
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys

TARGETS = ("PetalChecklist", "PetalWidgets")
IDENTIFIERS = ("APP_BUNDLE_IDENTIFIER", "WIDGET_BUNDLE_IDENTIFIER", "APP_GROUP_IDENTIFIER", "ICLOUD_CONTAINER_IDENTIFIER")
EXTERNAL_GATES = (
    "Developer Program membership", "Accepted/frozen app Bundle ID", "Accepted/frozen Widget Bundle ID",
    "Accepted/frozen App Group ID", "Accepted/frozen iCloud container ID", "DEVELOPMENT_TEAM",
    "Approved support mailbox", "Pages publication and URL verification", "Production CloudKit schema",
    "Signed archive and provisioning", "Organizer Privacy Report", "Genuine screenshots",
    "Signed UI, VoiceOver, desktop Widget, notification tests", "macOS 14 and Intel runtime",
    "Two-Mac iCloud and restart tests", "App Store Connect record", "TestFlight upload",
    "Four-week beta and market gate", "App Review submission",
)


def settings_errors(release, debug):
    errors = []
    for configuration, rows, aps in (("Release", release, "production"), ("Debug", debug, "development")):
        if set(rows) != set(TARGETS):
            errors.append(configuration + ": missing or unexpected product target")
            continue
        for target in TARGETS:
            row = rows[target]
            if row.get("PETAL_APS_ENVIRONMENT") != aps:
                errors.append(configuration + " " + target + ": wrong APNs environment")
            expected_bundle = row.get("APP_BUNDLE_IDENTIFIER") if target == "PetalChecklist" else row.get("WIDGET_BUNDLE_IDENTIFIER")
            if not expected_bundle or row.get("PRODUCT_BUNDLE_IDENTIFIER") != expected_bundle:
                errors.append(configuration + " " + target + ": effective bundle ID differs from candidate")
            if row.get("CODE_SIGN_ENTITLEMENTS") != target + "/" + target + ".entitlements":
                errors.append(configuration + " " + target + ": unexpected selected entitlements")
            for key in IDENTIFIERS:
                value = row.get(key, "")
                if not value or "$" in value or "PLACEHOLDER" in value.upper():
                    errors.append(configuration + " " + target + ": unset " + key)
                elif value != rows[TARGETS[0]].get(key):
                    errors.append(configuration + " " + target + ": inconsistent " + key)
        app = rows[TARGETS[0]]
        if app.get("WIDGET_BUNDLE_IDENTIFIER") != app.get("APP_BUNDLE_IDENTIFIER", "") + ".widgets":
            errors.append(configuration + ": Widget bundle not beneath app bundle")
        for key in IDENTIFIERS:
            if app.get(key) != release.get(TARGETS[0], {}).get(key):
                errors.append(configuration + ": identifier differs from Release " + key)
    return errors


def entitlement_errors(root, release, debug):
    errors = []
    for configuration, rows in (("Release", release), ("Debug", debug)):
        for target in TARGETS:
            selected = rows.get(target, {}).get("CODE_SIGN_ENTITLEMENTS")
            expected_path = target + "/" + target + ".entitlements"
            if selected != expected_path:
                errors.append(configuration + " " + target + ": unreviewed selected entitlements")
                continue
            path = root / "apple" / selected
            try:
                with path.open("rb") as stream:
                    data = plistlib.load(stream)
            except (OSError, ValueError) as error:
                errors.append(configuration + " " + target + ": unreadable selected entitlements: " + str(error))
                continue
            expected = {"com.apple.developer.aps-environment": "$(PETAL_APS_ENVIRONMENT)",
                "com.apple.security.app-sandbox": True,
                "com.apple.security.application-groups": ["$(APP_GROUP_IDENTIFIER)"],
                "com.apple.developer.icloud-container-identifiers": ["$(ICLOUD_CONTAINER_IDENTIFIER)"],
                "com.apple.developer.icloud-services": ["CloudKit"]}
            if target == "PetalChecklist": expected["com.apple.security.files.user-selected.read-write"] = True
            if data != expected: errors.append(configuration + " " + target + ": unexpected selected entitlement values")
    return errors


def field(source, name):
    match = re.search(r"^" + re.escape(name) + r":[ \t]*([^\r\n]*)$", source, re.M)
    return match.group(1).strip() if match else ""


def description(source):
    match = re.search(r"^## Description\s*\n(.*?)(?=^## |\Z)", source, re.M | re.S)
    return match.group(1).strip() if match else ""


def document_errors(metadata, readiness, beta):
    errors = []
    expected_names = {"en": "Petal Checklist Widget", "zh-Hans": "花瓣清单：桌面小组件"}
    for locale, name in expected_names.items():
        source = metadata.get(locale, "")
        if not source: errors.append(locale + ": missing metadata"); continue
        for key in ("Name", "Subtitle", "Category", "Price", "Age rating target", "Minimum system",
                    "Keywords", "Privacy URL", "Support URL", "URL status", "Copyright", "Version notes"):
            if not field(source, key): errors.append(locale + ": missing " + key)
        if field(source, "Name") != name or len(field(source, "Name")) > 30:
            errors.append(locale + ": wrong/oversize name")
        if len(field(source, "Subtitle")) > 30: errors.append(locale + ": oversize subtitle")
        keywords = field(source, "Keywords")
        if len(keywords.encode("utf-8")) > 100 or any(len(word.strip()) < 3 for word in keywords.split(",")):
            errors.append(locale + ": invalid/oversize keywords")
        if any(word.strip().casefold() in name.casefold() for word in keywords.split(",") if word.strip()):
            errors.append(locale + ": keywords duplicate app name")
        if "Productivity" not in field(source, "Category") or "Free" not in field(source, "Price"):
            errors.append(locale + ": wrong category or price")
        if "4+" not in field(source, "Age rating target") or field(source, "Minimum system") != "macOS 14.0":
            errors.append(locale + ": wrong age/OS baseline")
        body = description(source)
        if not body or len(body) > 4000: errors.append(locale + ": missing/oversize description")
        for kind in ("Privacy", "Support"):
            url = field(source, kind + " URL")
            if url != "https://sonoko0404.github.io/petal-notes/" + kind.lower() + "/" + locale + ".html":
                errors.append(locale + ": unreviewed " + kind + " URL")
        if "PROPOSED / UNPUBLISHED / UNVERIFIED" not in field(source, "URL status"):
            errors.append(locale + ": URL publication falsely claimed")
        if "[YEAR] [LEGAL OWNER]" not in field(source, "Copyright"):
            errors.append(locale + ": legal owner/year missing or falsely supplied")
        if "DRAFT / LOCAL ONLY" not in field(source, "Status"):
            errors.append(locale + ": metadata falsely ready")
        shots = re.search(r"^## Genuine screenshot capture list\s*\n(.*?)(?=^## |\Z)", source, re.M | re.S)
        if not shots or len(re.findall(r"^\d+\. ", shots.group(1), re.M)) != 7:
            errors.append(locale + ": screenshot capture list incomplete")
    if "Status: LOCAL DRAFT" not in readiness or "Distribution status: BLOCKED" not in readiness:
        errors.append("Readiness falsely marked complete")
    for gate in EXTERNAL_GATES:
        row = re.search(r"^\| " + re.escape(gate) + r" \| ([^|]+) \|", readiness, re.M)
        if not row or row.group(1).strip() != "BLOCKED":
            errors.append("External gate not blocked: " + gate)
    if "Status: BLOCKED" not in beta or "Market gate: NOT RUN" not in beta:
        errors.append("Beta status falsely marked complete")
    decisions = re.findall(r"Current decision:[ \t]*([^\r\n]*)$", beta, re.M)
    if len(decisions) != 1 or decisions[0].strip().rstrip(".") != "NOT RUN":
        errors.append("Beta decision falsely marked complete")
    for threshold in ("20–30", "14/20", "8/20", "5/20"):
        if threshold not in beta: errors.append("Beta gate missing " + threshold)
    for label in ("TestFlight build/version", "Invited target users", "Enrolled target users",
                  "Frozen first-20 cohort size", "First 20 who added a desktop Widget",
                  "First 20 still using Petal at end of week 4",
                  "First 20 saying loss of Petal would be meaningfully inconvenient"):
        row = re.search(r"^\| " + re.escape(label) + r" \| ([^|]+) \| ([^|]+) \|", beta, re.M)
        if not row or row.group(1).strip() != "NOT RUN" or "BLOCKED" not in row.group(2):
            errors.append("Beta aggregate falsely populated: " + label)
    for week in range(1, 5):
        row = re.search(r"^\| " + str(week) + r" \|([^\n]+)$", beta, re.M)
        if not row or row.group(1).count("NOT RUN") != 6 or not row.group(1).rstrip().endswith("BLOCKED |"):
            errors.append("Week " + str(week) + " not blocked/unrun")
    return errors


def build_rows(root, configuration):
    result = subprocess.run(["xcodebuild", "-showBuildSettings", "-json", "-project",
        str(root / "apple/PetalChecklist.xcodeproj"), "-alltargets", "-configuration", configuration,
        "CODE_SIGNING_ALLOWED=NO"], check=True, capture_output=True, text=True)
    return {row["target"]: row["buildSettings"] for row in json.loads(result.stdout) if row["target"] in TARGETS}


def main():
    root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[2]
    try:
        release = build_rows(root, "Release")
        debug = build_rows(root, "Debug")
        metadata = {locale: (root / f"docs/release/app-store-metadata-{locale}.md").read_text()
            for locale in ("en", "zh-Hans")}
        readiness = (root / "docs/release/release-readiness.md").read_text()
        beta = (root / "docs/validation/testflight-four-week-report.md").read_text()
        notes = (root / "docs/release/review-notes.md").read_text()
        errors = settings_errors(release, debug) + entitlement_errors(root, release, debug) + document_errors(metadata, readiness, beta)
        if "# App Review notes" not in notes or "not submitted" not in notes or len(notes) < 500:
            errors.append("Reviewer notes missing or falsely final")
        if any(release[target].get("DEVELOPMENT_TEAM") or release[target].get("PETAL_FEEDBACK_EMAIL") for target in TARGETS):
            errors.append("Owner inputs unexpectedly populated; re-review readiness evidence before use")
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        errors = ["Required local artifact/settings unavailable: " + str(error)]
    print(json.dumps({"local_preparation": "FAIL" if errors else "PASS", "distribution": "BLOCKED",
        "errors": errors, "scope": "unsigned local draft; no owner/account/hardware gate passed"}, indent=2))
    return bool(errors)


if __name__ == "__main__": raise SystemExit(main())
