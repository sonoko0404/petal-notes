# Release readiness — local preparation versus external gates

Status: LOCAL DRAFT. A local verifier passing means only that drafts and configuration are structurally consistent. It does not authorize distribution, prove provisioning, or turn any external gate green. Candidate identifiers in `apple/Config/Shared.xcconfig` remain proposals until Apple accepts and the owner freezes them together.

## Local evidence

| Evidence | Status | Scope |
| --- | --- | --- |
| Task 12 structural release matrix | RECORDED | `docs/validation/apple-release-checklist.md`; its BLOCKED rows remain blocked |
| Release APNs configuration | LOCAL CHECK | Release resolves production; Debug resolves development in both target entitlements; no provisioning claim |
| Bilingual metadata and reviewer notes | DRAFT | Field limits and wording checked locally; no App Store Connect entry |
| Four-week beta template | DRAFT | No users invited and no market result |

## Owner, account, and hardware gates

Every row is BLOCKED until the owner records dated evidence from the real external action. The local verifier rejects a PASS claim while this preparation is unsubmitted.

| Gate | Status | Evidence required |
| --- | --- | --- |
| Developer Program membership | BLOCKED | Paid membership active for authorized owner |
| Accepted/frozen app Bundle ID | BLOCKED | Apple-accepted identifier matching final build |
| Accepted/frozen Widget Bundle ID | BLOCKED | Apple-accepted extension identifier matching app namespace |
| Accepted/frozen App Group ID | BLOCKED | Apple-accepted group shared by both targets |
| Accepted/frozen iCloud container ID | BLOCKED | Apple-accepted private CloudKit container shared by both targets |
| DEVELOPMENT_TEAM | BLOCKED | Owner-supplied Apple Team ID in signed release configuration |
| Approved support mailbox | BLOCKED | Owner-approved and tested address configured as PETAL_FEEDBACK_EMAIL |
| Pages publication and URL verification | BLOCKED | Owner enables Pages; privacy and support URLs reachable and contact details approved |
| Production CloudKit schema | BLOCKED | Record types and indexes deployed to production and clean account tested |
| Signed archive and provisioning | BLOCKED | Final distribution archive with matching profiles and production capabilities |
| Organizer Privacy Report | BLOCKED | Final signed archive report reviewed against source inventory |
| Genuine screenshots | BLOCKED | English and Chinese Mac captures from final signed build and desktop Widgets |
| Signed UI, VoiceOver, desktop Widget, notification tests | BLOCKED | Dated real-host results including keyboard, AX speech, insertion, reminders and actions |
| macOS 14 and Intel runtime | BLOCKED | Dated macOS 14 host and Intel Mac results, not just universal slices |
| Two-Mac iCloud and restart tests | BLOCKED | Provisioned two-Mac production sync/conflict/restart results |
| App Store Connect record | BLOCKED | Owner-created record, accepted name/identifiers, rating and privacy answers |
| TestFlight upload | BLOCKED | Signed external build processed and available to testers |
| Four-week beta and market gate | BLOCKED | First-20 aggregate thresholds met after four full weeks |
| App Review submission | BLOCKED | Owner-submitted final metadata, screenshots, review notes and build |

Distribution status: BLOCKED. No enrollment, identifier registration, CloudKit deployment, Pages publication, push, upload, invitation, or submission is part of this local task.
