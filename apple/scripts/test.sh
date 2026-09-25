#!/bin/zsh
set -euo pipefail
root_dir="$(cd "$(dirname "$0")/.." && pwd)"
swift test --package-path "$root_dir/Packages/PetalKit"
# Unsigned builds can execute the hosted unit bundle. The UI runner requires
# valid local/ad-hoc signing, so this scaffold verifies its compilation only.
xcodebuild test -project "$root_dir/PetalChecklist.xcodeproj" -scheme PetalChecklist -destination 'platform=macOS' -only-testing:PetalChecklistTests CODE_SIGNING_ALLOWED=NO
xcodebuild build-for-testing -project "$root_dir/PetalChecklist.xcodeproj" -scheme PetalChecklist -destination 'platform=macOS' -only-testing:PetalChecklistUITests CODE_SIGNING_ALLOWED=NO
