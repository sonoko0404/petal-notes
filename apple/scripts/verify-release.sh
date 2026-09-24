#!/bin/zsh
set -euo pipefail
root_dir="$(cd "$(dirname "$0")/.." && pwd)"
evidence_dir="$(mktemp -d /tmp/petal-release.XXXXXX)"
print "Release evidence: $evidence_dir"
run_gate() {
    local gate_name="$1"
    shift
    if "$@" > "$evidence_dir/$gate_name.log" 2>&1; then
        print "$gate_name: PASS"
    else
        print "$gate_name: FAIL — $evidence_dir/$gate_name.log"
        tail -30 "$evidence_dir/$gate_name.log"
        exit 1
    fi
}
{
    date -u
    sw_vers
    uname -m
    sysctl -n hw.model hw.memsize machdep.cpu.brand_string
    xcodebuild -version
    swift --version
    git -C "$root_dir" rev-parse HEAD
    print 'Performance configuration: Release -O wholemodule, ENABLE_TESTABILITY=YES; archive: clean Release with default testability'
} > "$evidence_dir/reference-mac.txt" 2>&1
run_gate tests zsh "$root_dir/scripts/test.sh"
run_gate localization-tests python3 "$root_dir/scripts/test-localization.py"
run_gate localization zsh "$root_dir/scripts/verify-localization.sh"
run_gate pages-tests python3 "$root_dir/scripts/test-pages-workflow.py"
run_gate site python3 "$root_dir/scripts/verify-site.py"
run_gate release-gate-tests python3 "$root_dir/scripts/test-release-gates.py"
run_gate diagnostics-gate-tests python3 "$root_dir/scripts/test-diagnostics-gate.py"
run_gate diagnostics python3 "$root_dir/scripts/verify-diagnostics.py"
run_gate accessibility-tests python3 "$root_dir/scripts/test-accessibility.py"
run_gate accessibility python3 "$root_dir/scripts/verify-accessibility.py"
run_gate source-audit python3 "$root_dir/scripts/release-gates.py" source "$root_dir"
run_gate privacy python3 "$root_dir/scripts/release-gates.py" privacy "$root_dir/PetalChecklist/Resources/PrivacyInfo.xcprivacy" "$root_dir/PetalWidgets/Resources/PrivacyInfo.xcprivacy" "$root_dir/Packages/PetalKit/Sources/PetalPersistence/PrivacyInfo.xcprivacy" "$root_dir/Packages/PetalKit/Sources/PetalActions/PrivacyInfo.xcprivacy"
for run in 1 2 3; do
    run_gate "performance-$run" xcodebuild test -project "$root_dir/PetalChecklist.xcodeproj" -scheme PetalChecklist \
        -configuration Release -destination 'platform=macOS' -only-testing:PetalChecklistTests/PerformanceTests \
        CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES
done
run_gate performance python3 "$root_dir/scripts/release-gates.py" performance "$evidence_dir/performance-1.log" "$evidence_dir/performance-2.log" "$evidence_dir/performance-3.log"
cat "$evidence_dir/performance.log"
run_gate debug xcodebuild build -project "$root_dir/PetalChecklist.xcodeproj" -scheme PetalChecklist -configuration Debug \
    -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO
run_gate archive xcodebuild clean archive -project "$root_dir/PetalChecklist.xcodeproj" -scheme PetalChecklist \
    -configuration Release -destination 'generic/platform=macOS' -archivePath "$evidence_dir/PetalChecklist.xcarchive" \
    -derivedDataPath "$evidence_dir/DerivedData" ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO
run_gate archive-audit python3 "$root_dir/scripts/release-gates.py" archive "$evidence_dir/PetalChecklist.xcarchive"
run_gate settings python3 "$root_dir/scripts/release-gates.py" settings "$root_dir"
print 'Automated structural gates: PASS'
print 'BLOCKED: cold launch editable / hot capture live focus until signed UI automation succeeds; VoiceOver, desktop Widgets, Intel runtime, two-device iCloud, notifications and distribution require recorded manual evidence.'
print "Evidence retained: $evidence_dir"
