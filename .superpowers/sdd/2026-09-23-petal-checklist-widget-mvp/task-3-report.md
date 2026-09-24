# Task 3 — Transactional App Group Repository

## Result

Implementation commit: `194c2f9ee81407169aa747f26bc238e475add7d3` (`feat: add transactional shared Petal store`).

Implemented the Task 3 repository protocol, opaque store factory, private versioned SwiftData schema, transactional mutation/outbox journal, Inbox transfer, search, exact retention cleanup, local reset generation, and real in-memory test fixtures. No PetalCore, package manifest, Xcode project, or prior-task implementation was modified.

## Files changed

All source/test paths below are relative to `apple/Packages/PetalKit/`:

- Added `Sources/PetalPersistence/PetalSchemaV1.swift`.
- Added `Sources/PetalPersistence/PetalMigrationPlan.swift`.
- Added `Sources/PetalPersistence/ModelContainerFactory.swift`.
- Added `Sources/PetalPersistence/PetalRepository.swift`.
- Added `Sources/PetalPersistence/SwiftDataPetalRepository.swift`.
- Added `Sources/PetalPersistence/OutboxChange.swift`.
- Added `Sources/PetalTestSupport/InMemoryPetalRepository.swift`.
- Added `Tests/PetalPersistenceTests/RepositoryTests.swift`.
- Removed the empty `Sources/PetalPersistence/PetalPersistence.swift` scaffold.
- Removed the empty `Sources/PetalTestSupport/PetalTestSupport.swift` scaffold.
- Added this report at `.superpowers/sdd/2026-09-23-petal-checklist-widget-mvp/task-3-report.md` (repository-relative).

## Test-first evidence

Every increment below added one focused test before its implementation. Each RED and GREEN invocation ran the same complete focused command from the worktree root:

```sh
swift test --package-path apple/Packages/PetalKit --filter PetalPersistenceTests
```

Some invocations filtered terminal output through `rg`; all but the second RED invocation used `set -o pipefail` when piping. That second RED shell pipeline returned 0 because of `tail`, but its compiler output explicitly contained `error: Build failed` and missing API diagnostics; it was not treated as GREEN.

| Increment / test | RED evidence | GREEN evidence |
| --- | --- | --- |
| 1. `bootstrapCreatesExactlyOneInbox` | Missing `SwiftDataPetalRepository` / `ModelContainerFactory` | 1 test passed |
| 2. `entityAndOutboxRollbackTogether` | Missing fault injection, create-card, and outbox APIs | 2 tests passed; same and independent readers observed no cards/outbox after failure |
| 3. `createCardCommitsDomainValueAndOutbox` | Missing `card` and `pendingOutbox` | 3 tests passed; decoded journal payload equals committed card |
| 4. `addLinesPreservesOrderAndCommitsLinePayloads` | Missing `addLine` / `lines` | 4 tests passed; orphan insert rejected without journal growth |
| 5. `convertingTodoToTextClearsTodoStateAtomically` | Missing `updateLine` | 5 tests passed; failed conversion preserved line and outbox |
| 6. `completionPreservesManualOrderAndIsIdempotent` | Missing `setCompleted` | 6 tests passed; repeated completion does not advance revision or append a change |
| 7. `reorderRequiresExactPermutationAndRollsBackAllRows` | Missing `reorder` / invalid-order error | 7 tests passed; failed reorder restored both rows |
| 8. `movingInboxRequiresActiveReplacementInSameTransaction` | Missing `moveCard` / replacement error | 8 tests passed; failed transfer kept the original Inbox |
| 9. `searchMatchesTitlesAndMixedLinesAcrossAllScopes` | Missing `search` | 9 tests passed; trashed card title and text matched, blank query did not |
| 10. `appAndWidgetShareOneStoreAndObserveEachOthersCommits` | Missing `makeShared` | 10 tests passed; two independent disk containers concurrently bootstrapped one Inbox and observed subsequent status changes |
| 11. `futureSchemaRefusesOpenAndExistingWriterBeforeAnyWrite` | Missing unsupported-schema error | 11 tests passed; future marker refused open and mutation, every file byte remained unchanged |
| 12. `trashPurgesAtExactlyThirtyDaysWithItsLinesAndDeletionOutbox` | Missing `purgeExpiredTrash` | 12 tests passed; retained at 2,591,999 seconds, purged at 2,592,000 seconds; failure preserved card/line/outbox |
| 13. `conflictRetentionIsExactlyThirtyDaysAndTransactional` | Missing conflict capture/query/purge APIs | 13 tests passed; same exact boundary and rollback proved |
| 14. `deleteAllDataReplacesContentsWithEmptyInboxAndResetGenerationAtomically` | Missing reset mutation/query APIs | 14 tests passed; failure preserved old data, success kept one empty Inbox and reset journal |
| 15. `deviceIdentityIsStableWithinStoreAndDifferentAcrossStores` | Runtime expectation failed: `a.deviceID != c.deviceID` (both used the provisional local identifier) | 15 tests passed; persistent per-store identity replaced the provisional value |
| 16. `expiryDoesNotRetainExpiredContentInPendingOutbox` | Runtime failures: wrong pending count and old payloads still retained | 16 tests passed; expired entity snapshots were replaced with content-free deletion entries |
| 17. `fixtureBuilderUsesRealRepositoryAndDeterministicClock` | Missing fixture builder and clock | 17 tests passed; deterministic real repository fixture supported completion |
| Supplemental verification | Added disk-reopen rollback and unavailable-App-Group checks against existing implementation; no behavior change | 19 tests passed |
| 18. `outboxKeepsCommitOrderWhenWallClockMovesBackwards` | Runtime order assertion failed: journal sorted archived state before initial active state | 20 tests passed; persisted monotonic journal sequence fixes clock reversal and timestamp ties |

During increment 2, SwiftData's `@ModelActor` generated initializer exposed an uninitialized stored-property compiler error. Providing a default for the actor's fault-injector property resolved that compiler issue before the GREEN run; no unsafe concurrency annotation was introduced.

## Design and assumptions

- `PetalStore` is an opaque `Sendable` handle. Its SwiftData container and all six stored model types are module-internal. The public repository contains only the private `@ModelActor` reference and forwards value-only async operations; neither `ModelContext` nor stored models cross the public boundary.
- Each business mutation uses a fresh actor-confined context with autosave disabled. It stages entity changes and journal entries, injects the requested failure after staging, and performs exactly one `save()`. Errors call `rollback()`. Reset and expiry use the same mechanism, including journal removal and append.
- A shared coordinator serializes in-memory handles with `NSLock`. For a disk store it additionally holds an advisory `flock` across read/modify/save. Every cooperating process uses the same lock file. This protects the Inbox invariant across App/Widget writers, not only within one actor. Read contexts are fresh so registered objects do not hide another client's commits. No project-defined `@unchecked Sendable` or `nonisolated(unsafe)` was used.
- The App Group factory resolves `<group>/Library/Application Support/Petal/Petal.sqlite`, explicitly disables automatic CloudKit mirroring, and permits injection of the container-directory resolver for unsigned integration tests. It never falls back to an unrelated local store when App Group resolution fails.
- Version 1 has an explicit `VersionedSchema` and an empty explicit migration-stage list. A `Petal.schema-version` marker is checked before creating/opening the store and before every transaction, both before and after acquiring the file lock. Missing/malformed markers on existing databases fail closed. Future migrations must update the marker while holding this same lock before opening for writes. The future-version test checks file bytes, not merely thrown errors.
- IDs/foreign keys and expiry timestamps are stored fields; full domain values are losslessly Codable payloads. Search currently decodes relevant records and performs case-insensitive matching across all scopes.
- Retention means an absolute 30 × 24-hour duration (2,592,000 seconds), independent of DST. Purging also removes earlier queued content snapshots and appends content-free deletion entries. Rollback restores both records and previous journal entries.
- The first card created in an empty store becomes Inbox; bootstrap is idempotent and only creates an Inbox when missing. Moving Inbox to archive/trash requires another active card. The invariant holds after initialization and all supported mutations.
- Completion keeps manual `sortIndex`; display ordering is left to the snapshot/UI layer. A repeated completion is idempotent; missing/text lines throw typed unavailable errors for the later intent adapter to handle without creating data.
- Device identity and monotonic outbox sequence are local metadata in `StoredUserState`; they are saved atomically with their business change, but do not produce separate cloud changes. Reset generation produces a `UserStateChange` journal payload and one new Inbox. The sequence is independent of user/system wall-clock changes.
- The additional conflict and reset queries/mutations make the architecture's retention and reset guarantees testable through values. No title-edit, import, or inbound-sync product APIs were invented in this task.
- `InMemoryPetalRepository` is a test-only builder returning the real repository, not a competing persistence implementation. Its async `bootstrapped` method returns a repository; `cardWithTodos` returns a fixture containing `repository` and `fixtureCardID`. Call sites in later tasks should use `try await`.
- Package and Xcode dependency inspection confirmed `PetalTestSupport` remains linked only by test targets; no production link changes were made.

## Final verification

- `swift test --package-path apple/Packages/PetalKit --filter PetalPersistenceTests`: exit 0, 20/20 tests passed, zero failures.
- `swift test --package-path apple/Packages/PetalKit`: exit 0, 33/33 tests passed (20 persistence + 13 core). Other package test bundles remain empty scaffolds. No warnings or failures in the final run.
- `git diff --check` and `git diff --cached --check`: exit 0.
- Environment: Apple Swift 6.4, Swift language mode 6, arm64 host; package deployment target remains macOS 14.

## Deferred integration and limitations

- Task 9 owns CloudKit transport/mapping, journal acknowledgement, inbound merge/tombstone application, and conflict-presented state. Conflict journal entries are local conflict-history events; the sync layer must not invent a CloudKit conflict record type when consuming them. It must handle them locally while mapping the architecture's card/line/user-state/tombstone record types.
- Task 10 owns transactional import and persistent duplicate detection; `StoredImportFingerprint` is present in the schema and cleared by reset, but import APIs are not added here.
- Daily completion projection/reset and reminder scheduling remain with the later time-aware snapshot/reminder integration. Raw repository queries return committed domain values and do not implicitly advance calendar state.
- Actual signed App Group entitlement access, separate running App/Widget processes, Intel release slices, and macOS 14 runtime execution were not exercised here. The shared-store integration uses independent disk-backed containers on the current arm64 Mac.
- Process-kill fault injection is not included; failure is injected after entity/outbox staging and before the single save. The disk-reopen test confirms the rejected mutation was not persisted.
- No prior-task Core correction was necessary.
