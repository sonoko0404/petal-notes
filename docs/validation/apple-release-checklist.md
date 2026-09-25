# Apple release validation — 2026-09-24

This is a local structural validation record, not approval to distribute. No Apple account enrollment, signing for distribution, notarization, live CloudKit operation, Pages publication or Windows change was performed.

## Reproduce

Run `zsh apple/scripts/verify-release.sh`. It retains a new `/tmp/petal-release.*` evidence directory, runs package and hosted tests, compiles UI tests, checks localization/site/accessibility/privacy/diagnostics, measures three consecutive Release runs, and produces a clean universal unsigned archive. A failed automated gate exits nonzero. Missing live UI observations remain explicitly BLOCKED and do not count as performance passes. The local reference is Mac14,2 / Apple M2 / 8 GiB, macOS 27.0 (26A428), Xcode 27.0 (27A266a), Swift 6.4 compiler in Swift 6 language mode, macOS 14 deployment target.

Release measurements use a fresh on-disk store populated through the production replacement transaction with 500 cards and 5,000 rows. Fixture construction and search/Widget warmup are outside `ContinuousClock` intervals. Search requires all 500 known matches. Widget timing invokes the real `ToggleTodoIntent` → `SyncingWidgetTodoAction` → shared reminder/repository path, including store reopen, local save, reconciliation and native reload. Sync is disabled in the isolated fixture. An independent reopened repository verifies the saved state. That duration is a conservative upper bound on local save, not live desktop WidgetKit delivery latency.

Budgets are search <300 ms, launch to editable <2,000 ms, hot capture first responder <300 ms and Widget local save <1,000 ms. The gate fails a metric only when all three consecutive Release samples meet or exceed its budget. Missing/non-numeric/non-finite/negative samples cannot pass. UI performance tests use the same disk fixture and native hotkey/first-responder timing; the host must first permit XCTest automation. No stubbed UI latency is reported.

## Dated validation matrix

| Check | Status on 2026-09-24 | Evidence and limit |
|---|---|---|
| Apple Silicon package/hosted execution | PASS | Full `test.sh` logs in release evidence; exact totals recorded in Task 12 report |
| macOS 14 deployment / Swift 6 complete concurrency | PASS | Build settings, per-architecture Mach-O inspection; runtime on macOS 14 hardware remains BLOCKED |
| Intel executable architecture | PASS | App and extension contain x86_64 and arm64; Intel runtime is BLOCKED (no Intel host) |
| 500-card/5,000-row search and Widget local transaction | PASS | Three Release raw runs and tracked performance record; live Widget invocation remains separate |
| Cold launch to editable / hot capture first responder | BLOCKED | Ad-hoc UI runner timed out enabling automation before any test method; no latency result was invented |
| Keyboard create/add/convert/complete/reorder/search/archive/trash/restore/reminder/settings/import/export/delete-all | BLOCKED | New keyboard-only suite compiles; it sends only key events and reads AX focus. Live runner could not initialize |
| Localized icon labels/state/target geometry and Widget rows | PASS (static) | `verify-accessibility.py`, mutation tests; five icon controls, todo/text rows, source order and separate controls; does not prove spoken output |
| VoiceOver speech / visible focus / full runtime AX audit | BLOCKED | Compiled bilingual AX tests with real assertions and public AX focus reads; no live VoiceOver session claimed |
| English / Simplified Chinese catalogs and rendered copy | PASS (automated) | Localization mutation/runtime tests, site parity, hosted synthetic Widget renders; interactive locale walkthrough BLOCKED |
| Light/dark/vibrant Widget layout | PASS (hosted synthetic) | Existing 14 ImageRenderer scenarios; real desktop material compositing BLOCKED |
| Reduce Transparency / Increase Contrast | PASS (policy/static) | Theme contrast tests and Widget material branch audit; live OS setting walkthrough BLOCKED |
| Reduce Motion | PASS (static) | No custom animation/transition currently ships; gate rejects new motion without a Reduce Motion branch; live OS walkthrough BLOCKED |
| Medium/large Widget desktop insertion, restart and midnight refresh | BLOCKED | No signed desktop Widget host session or Mac restart performed |
| Offline edits / reconnect / conflict/reset ordering | PASS (deterministic) | Real repository + controlled transport tests; real account/two-device service behavior BLOCKED |
| App/store restart durability | PASS (repository) | Independent disk handle reopen tests, including UI-performance fixture regression; normal app lifecycle restart BLOCKED |
| Two-device conflicts / cross-device notification cancellation | BLOCKED | Requires two provisioned devices/accounts; no live CloudKit writes performed |
| Reminder permission, delivery and signed notification actions | BLOCKED | Scheduler/adapter/local action tests pass; real signed delivery is unexecuted |
| Import / backup replacement / JSON+Markdown export / delete-all | PASS (automated) | Existing transaction, rollback, round-trip, tombstone and settings tests; keyboard walkthrough BLOCKED |
| Diagnostics closed API, schema, corruption, concurrent ring, retention | PASS | Four hosted tests, compiler-negative API attacks and mutation gate; no content or arbitrary metadata accepted |
| Source/dependency/privacy resources | PASS (structural) | Source inventory, four manifest schemas, six archived copies; Xcode built-in `-scanforprivacyfile` processed both products and package resource bundles |
| Xcode Organizer consolidated Privacy Report | BLOCKED | No `privacy-report` command is installed; Organizer UI report was not generated. Built-in archive scan and explicit manifest audit are retained, not mislabeled as that report |
| Clean universal Release archive | PASS (structural) | Archive, `lipo`, `vtool`, `plutil`, `otool`, `nm`, resources and configured entitlement audit |
| Provisioned entitlements / production signing / notarization | BLOCKED | Local archive is unsigned/ad-hoc only; no development team configured; development APNs entitlement remains a release-configuration gate |
| Pages publication / feedback mailbox configuration | BLOCKED | Static site checks pass; no publication performed and approved mailbox remains unset |

## Privacy audit rationale

No tracking or developer-hosted collection is implemented. Optional CloudKit writes go to the person's private database; notification content stays with the OS; feedback opens the person's chosen mail app and explicit exports go to a chosen file. Empty collected-data arrays describe that architecture, not a claim that Apple infrastructure never processes data.

| Required-reason category | Evidence | Reason |
|---|---|---|
| User defaults (App) | Appearance, shortcut and reset preferences in App; shared reminder sound in PetalActions | CA92.1 (app-only), 1C8F.1 (same App Group) |
| User defaults (Widget / PetalActions) | `ReminderSoundPreference` accesses only the configured App Group suite | 1C8F.1 |
| File timestamps (both products / PetalPersistence) | `WidgetSnapshotCache` orders owned cache files by modification date | C617.1 |
| System boot time (App) | `QuickCaptureAppController` measures elapsed hotkey-to-first-responder time with system uptime | 35F9.1 |

Reasons were checked against [Apple's required-reason API documentation](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitypereasons?language=objc). No disk-space, active-keyboard, tracking or collection reason was invented. PetalKit has no external package dependency. Normal test builds can wrap first-party package products in frameworks; a clean archive links them statically and includes their explicit privacy resource bundles in each consuming product.

Diagnostics accept only a timestamp, subsystem enum, error-code enum, sync-state enum (including unknown), and numeric app/OS versions. They contain no user IDs, paths, text, raw errors or free-form metadata. The actor uses a cooperating-process file lock and atomic replacement, at most 1,024 entries and 256 KiB, removes entries at the exact seven-day boundary on append/export/startup pruning, and rejects future, corrupt, oversized or unknown-field records. The private Caches directory is excluded from backup and outside App Group/CloudKit/backup codecs. Only explicit Settings export chooses an external file. A stopped app cannot execute retention cleanup until next use; the UI states this limit.

## Before distribution

Run the BLOCKED rows on an authorized UI host, macOS 14 and Intel hardware as applicable, two provisioned devices, and real desktop Widgets. Generate the Xcode Organizer Privacy Report from the final signed archive and reconcile it with this source inventory. Record actual dated results before changing any BLOCKED status. Do not infer a signed release, published site or successful cloud operation from the structural gate's exit status.
