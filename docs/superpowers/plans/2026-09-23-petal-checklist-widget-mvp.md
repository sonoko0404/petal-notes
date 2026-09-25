# Petal Checklist Widget MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a bilingual, offline-first macOS 14+ checklist product whose medium and large desktop widgets display one card and complete todos directly, backed by a lightweight editor, private iCloud sync, reminders, import/export, and App Store-ready quality.

**Architecture:** A native SwiftUI macOS app and WidgetKit extension share an App Group SwiftData store through focused `PetalKit` library targets. Local commits are authoritative; App Intents update local state synchronously, while `CKSyncEngine` replicates line-level records to the user’s private CloudKit database and preserves conflict artifacts.

**Tech Stack:** Swift 6.4, SwiftUI, WidgetKit, App Intents, SwiftData, CloudKit/CKSyncEngine, UserNotifications, Swift Testing, XCTest, Xcode 27.

**Spec:** [`docs/product/petal-checklist-widget-prd.md`](../../product/petal-checklist-widget-prd.md)

## Global Constraints

- Deployment target is macOS 14.0; build and test both `arm64` and `x86_64` release slices.
- Desktop presentation is Widget-only; do not add floating sticky-note windows or a menu-bar resident mode.
- Widget supports medium and large families only; it must not contain text entry or scrolling content.
- Use only Apple SDKs at runtime; do not add third-party analytics, UI, storage, networking, shortcut, or crash-reporting dependencies.
- All user edits commit locally before cloud work begins; network failure must never discard local input.
- User content must never be sent to a developer-operated service or written to diagnostic logs.
- UI ships in Simplified Chinese and English; missing release localization keys fail verification.
- Default notification sound is off; default configurable global shortcut is `⌥⌘N`.
- Initial App Store price is free, with no ads, subscriptions, purchase SDK, or paywall.
- Development identifiers live in `.xcconfig` and must be frozen before the first distributed build.

## Review Focus

1. **Interrupted local write:** killing the process between entity mutation and outbox creation must leave both committed or neither committed; Task 3 adds a rollback test.
2. **Midnight and time-zone boundary:** a completed daily item resets exactly once for the new local day while one-time reminders keep their absolute instant; Tasks 2 and 8 add deterministic calendar tests.
3. **Concurrent edit versus delete:** an old offline edit must not resurrect a card protected by an unexpired tombstone; Task 9 adds the merge test.
4. **Widget interaction on stale data:** toggling a line deleted on another device must safely no-op and reload the widget; Task 7 adds the intent test.
5. **Duplicate Windows import:** importing the same source twice, including after relaunch, must create no duplicate cards; Task 10 adds a persistent fingerprint test.

---

## Phase 1 — Local Product Foundation

### Task 1: Native Workspace and Build Skeleton

**Files:**
- Create: `apple/PetalChecklist.xcodeproj/project.pbxproj`
- Create: `apple/Config/Shared.xcconfig`
- Create: `apple/Config/Debug.xcconfig`
- Create: `apple/Config/Release.xcconfig`
- Create: `apple/PetalChecklist/App/PetalChecklistApp.swift`
- Create: `apple/PetalChecklist/App/RootView.swift`
- Create: `apple/PetalChecklist/PetalChecklist.entitlements`
- Create: `apple/PetalWidgets/PetalWidgetBundle.swift`
- Create: `apple/PetalWidgets/PetalWidgets.entitlements`
- Create: `apple/Packages/PetalKit/Package.swift`
- Create: `apple/scripts/test.sh`

**Interfaces:**
- Consumes: no Apple implementation; the legacy WPF project is migration input only and is removed after the native product passes acceptance. Its SchemaVersion 1 import contract remains covered by fixtures.
- Produces: Xcode targets `PetalChecklist`, `PetalWidgets`, `PetalChecklistTests`, `PetalChecklistUITests`; package products `PetalCore`, `PetalPersistence`, `PetalSync`, `PetalNotifications`, `PetalImportExport`, `PetalDesignSystem`, and test-only `PetalTestSupport`. Link `PetalTestSupport` only to test bundles.

- [ ] **Step 1: Create the Xcode targets**

In Xcode, create a macOS App named `PetalChecklist` under `apple/`, add a Widget Extension named `PetalWidgets`, then add macOS unit and UI testing bundles. Set all deployment targets to macOS 14.0, Swift 6 language mode, App Sandbox on, and repository signing to automatic with an empty team.

- [ ] **Step 2: Add centralized build configuration**

```xcconfig
// apple/Config/Shared.xcconfig
MACOSX_DEPLOYMENT_TARGET = 14.0
SWIFT_VERSION = 6.0
APP_GROUP_IDENTIFIER = group.com.petalchecklist.shared
ICLOUD_CONTAINER_IDENTIFIER = iCloud.com.petalchecklist
APP_BUNDLE_IDENTIFIER = com.petalchecklist.mac
WIDGET_BUNDLE_IDENTIFIER = com.petalchecklist.mac.widgets
CODE_SIGN_STYLE = Automatic
ENABLE_USER_SCRIPT_SANDBOXING = YES
SWIFT_STRICT_CONCURRENCY = complete
```

- [ ] **Step 3: Create the local multi-target package**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PetalKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PetalCore", targets: ["PetalCore"]),
        .library(name: "PetalPersistence", targets: ["PetalPersistence"]),
        .library(name: "PetalSync", targets: ["PetalSync"]),
        .library(name: "PetalNotifications", targets: ["PetalNotifications"]),
        .library(name: "PetalImportExport", targets: ["PetalImportExport"]),
        .library(name: "PetalDesignSystem", targets: ["PetalDesignSystem"]),
        .library(name: "PetalTestSupport", targets: ["PetalTestSupport"]),
    ],
    targets: [
        .target(name: "PetalCore"),
        .target(name: "PetalPersistence", dependencies: ["PetalCore"]),
        .target(name: "PetalSync", dependencies: ["PetalCore", "PetalPersistence"]),
        .target(name: "PetalNotifications", dependencies: ["PetalCore"]),
        .target(name: "PetalImportExport", dependencies: ["PetalCore", "PetalPersistence"]),
        .target(name: "PetalDesignSystem", dependencies: ["PetalCore"]),
        .target(name: "PetalTestSupport", dependencies: ["PetalCore", "PetalPersistence"]),
        .testTarget(name: "PetalCoreTests", dependencies: ["PetalCore"]),
        .testTarget(name: "PetalPersistenceTests", dependencies: ["PetalPersistence", "PetalTestSupport"]),
        .testTarget(name: "PetalSyncTests", dependencies: ["PetalSync", "PetalTestSupport"]),
        .testTarget(name: "PetalNotificationsTests", dependencies: ["PetalNotifications"]),
        .testTarget(name: "PetalImportExportTests", dependencies: ["PetalImportExport", "PetalTestSupport"]),
        .testTarget(name: "PetalDesignSystemTests", dependencies: ["PetalDesignSystem"]),
    ]
)
```

- [ ] **Step 4: Add minimal entry points and test script**

```swift
@main
struct PetalChecklistApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
            .defaultSize(width: 960, height: 640)
    }
}
```

```bash
#!/bin/zsh
set -euo pipefail
root_dir="$(cd "$(dirname "$0")/.." && pwd)"
swift test --package-path "$root_dir/Packages/PetalKit"
xcodebuild test -project "$root_dir/PetalChecklist.xcodeproj" -scheme PetalChecklist -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 5: Verify and commit**

Run: `zsh apple/scripts/test.sh`  
Expected: every package and Xcode target builds; all empty test bundles pass.

```bash
git add apple
git commit -m "build: scaffold native Petal macOS workspace"
```

### Task 2: Domain Models and Time Rules

**Files:**
- Create: `apple/Packages/PetalKit/Sources/PetalCore/Identifiers.swift`
- Create: `apple/Packages/PetalKit/Sources/PetalCore/Card.swift`
- Create: `apple/Packages/PetalKit/Sources/PetalCore/CardLine.swift`
- Create: `apple/Packages/PetalKit/Sources/PetalCore/Reminder.swift`
- Create: `apple/Packages/PetalKit/Sources/PetalCore/CompletionPolicy.swift`
- Create: `apple/Packages/PetalKit/Sources/PetalCore/ReminderPolicy.swift`
- Test: `apple/Packages/PetalKit/Tests/PetalCoreTests/CompletionPolicyTests.swift`
- Test: `apple/Packages/PetalKit/Tests/PetalCoreTests/ReminderPolicyTests.swift`

**Interfaces:**
- Consumes: injected `Date`, `Calendar`, and `TimeZone` values.
- Produces: domain types from the architecture, `CompletionPolicy.isVisibleInWidget`, `CompletionPolicy.localDayKey`, and `ReminderPolicy.nextFireDate`.

- [ ] **Step 1: Write failing local-day tests**

```swift
import Foundation
import Testing
@testable import PetalCore

@Test func completedTodoIsVisibleTodayAndHiddenTomorrow() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let completed = Date(timeIntervalSince1970: 1_799_323_200)
    #expect(CompletionPolicy.isVisibleInWidget(completedAt: completed, now: completed, calendar: calendar))
    #expect(!CompletionPolicy.isVisibleInWidget(
        completedAt: completed,
        now: calendar.date(byAdding: .day, value: 1, to: completed)!,
        calendar: calendar
    ))
}
```

- [ ] **Step 2: Verify the test fails**

Run: `swift test --package-path apple/Packages/PetalKit --filter PetalCoreTests`  
Expected: FAIL because the domain types and policies do not exist.

- [ ] **Step 3: Implement exact domain values**

```swift
public enum CompletionPolicy {
    public static func localDayKey(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    public static func isVisibleInWidget(completedAt: Date?, now: Date, calendar: Calendar) -> Bool {
        guard let completedAt else { return true }
        return localDayKey(for: completedAt, calendar: calendar) == localDayKey(for: now, calendar: calendar)
    }
}
```

Implement every field and enum from the architecture, including `ThemeID`, `WidgetDisplaySize`, `CardScope`, `NewLineDraft`, `LineMutation`, `SearchResult`, and `MoveDirection`. All cross-actor values must be `Sendable`, `Codable`, and `Equatable` where possible.

- [ ] **Step 4: Add reminder tests and implementation**

```swift
@Test func oneTimeReminderKeepsItsAbsoluteInstant() {
    let instant = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(ReminderPolicy.nextFireDate(
        rule: .oneTime(instant), after: instant.addingTimeInterval(-1), calendar: .current
    ) == instant)
}
```

Implement daily reminders with `Calendar.nextDate`; use the injected calendar’s current time zone and return `nil` for expired one-time reminders.

- [ ] **Step 5: Run and commit**

Run: `swift test --package-path apple/Packages/PetalKit --filter PetalCoreTests`  
Expected: PASS.

```bash
git add apple/Packages/PetalKit/Sources/PetalCore apple/Packages/PetalKit/Tests/PetalCoreTests
git commit -m "feat: define cards todos and reminder rules"
```

### Task 3: Transactional App Group Repository

**Files:**
- Create: `apple/Packages/PetalKit/Sources/PetalPersistence/PetalSchemaV1.swift`
- Create: `apple/Packages/PetalKit/Sources/PetalPersistence/PetalMigrationPlan.swift`
- Create: `apple/Packages/PetalKit/Sources/PetalPersistence/ModelContainerFactory.swift`
- Create: `apple/Packages/PetalKit/Sources/PetalPersistence/PetalRepository.swift`
- Create: `apple/Packages/PetalKit/Sources/PetalPersistence/SwiftDataPetalRepository.swift`
- Create: `apple/Packages/PetalKit/Sources/PetalPersistence/OutboxChange.swift`
- Create: `apple/Packages/PetalKit/Sources/PetalTestSupport/InMemoryPetalRepository.swift`
- Test: `apple/Packages/PetalKit/Tests/PetalPersistenceTests/RepositoryTests.swift`

**Interfaces:**
- Consumes: PetalCore values.
- Produces: repository API from the architecture plus `ModelContainerFactory.makeInMemory()` and `.makeShared(appGroupID:)`.
- Produces for tests only: `InMemoryPetalRepository` fixture builder and deterministic clocks; production targets must not link `PetalTestSupport`.

- [ ] **Step 1: Write failing inbox and rollback tests**

```swift
@Test func bootstrapCreatesExactlyOneInbox() async throws {
    let repository = try SwiftDataPetalRepository(container: ModelContainerFactory.makeInMemory())
    try await repository.bootstrap(now: .now)
    #expect(try await repository.cards(scope: .active).filter(\.isInbox).count == 1)
}

@Test func entityAndOutboxRollbackTogether() async throws {
    let repository = try SwiftDataPetalRepository(
        container: ModelContainerFactory.makeInMemory(), faultInjector: .failBeforeSave
    )
    await #expect(throws: Error.self) { try await repository.createCard(title: "Atomic", now: .now) }
    #expect(try await repository.cards(scope: .all).isEmpty)
    #expect(try await repository.pendingOutboxCount() == 0)
}
```

- [ ] **Step 2: Implement private SwiftData models**

Create `StoredCard`, `StoredLine`, `StoredOutboxChange`, `StoredConflictArtifact`, `StoredImportFingerprint`, and `StoredUserState`. Map them to domain values at the repository boundary; UI and sync code must not receive `ModelContext`.

- [ ] **Step 3: Implement the repository protocol**

```swift
public protocol PetalRepository: Sendable {
    func bootstrap(now: Date) async throws
    func cards(scope: CardScope) async throws -> [Card]
    func card(id: CardID) async throws -> Card?
    func lines(cardID: CardID) async throws -> [CardLine]
    func createCard(title: String, now: Date) async throws -> Card
    func addLine(_ draft: NewLineDraft, now: Date) async throws -> CardLine
    func updateLine(_ mutation: LineMutation, now: Date) async throws -> CardLine
    func setCompleted(lineID: LineID, completed: Bool, now: Date) async throws
    func reorder(cardID: CardID, orderedLineIDs: [LineID], now: Date) async throws
    func moveCard(_ id: CardID, to status: CardStatus, replacementInbox: CardID?, now: Date) async throws
    func search(_ query: String) async throws -> [SearchResult]
}
```

- [ ] **Step 4: Make mutations and outbox atomic**

Each mutation updates its entity, appends an `OutboxChange`, then performs one `ModelContext.save()`. Add exact 30-day trash/conflict expiry tests and reject unknown future schema versions before any write.

- [ ] **Step 5: Run and commit**

Run: `swift test --package-path apple/Packages/PetalKit --filter PetalPersistenceTests`  
Expected: PASS, including rollback and schema refusal.

```bash
git add apple/Packages/PetalKit/Sources/PetalPersistence apple/Packages/PetalKit/Tests/PetalPersistenceTests
git commit -m "feat: add transactional shared Petal store"
```

### Task 4: Library Shell and Mixed-Line Editor

**Files:**
- Create: `apple/PetalChecklist/App/AppEnvironment.swift`
- Create: `apple/PetalChecklist/Navigation/AppRouter.swift`
- Create: `apple/PetalChecklist/CardLibrary/CardLibraryModel.swift`
- Create: `apple/PetalChecklist/CardLibrary/CardLibraryView.swift`
- Create: `apple/PetalChecklist/CardEditor/CardEditorModel.swift`
- Create: `apple/PetalChecklist/CardEditor/CardEditorView.swift`
- Create: `apple/PetalChecklist/CardEditor/CardLineRow.swift`
- Test: `apple/PetalChecklistTests/CardLibraryModelTests.swift`
- Test: `apple/PetalChecklistTests/CardEditorModelTests.swift`
- Test: `apple/PetalChecklistUITests/LibraryAndEditorUITests.swift`

**Interfaces:**
- Consumes: repository queries and mutations.
- Produces: one three-column window with Inbox, All Cards, Archive, Trash, Settings, search, and mixed text/todo editing.

- [ ] **Step 1: Write failing model tests**

```swift
@MainActor
func testNewLineDefaultsToTodoAndConvertsToText() async throws {
    let repository = InMemoryPetalRepository.bootstrapped()
    let card = try await repository.createCard(title: "Today", now: .now)
    let model = CardEditorModel(cardID: card.id, repository: repository)
    try await model.addLine(text: "Send report")
    XCTAssertEqual(model.lines.single.kind, .todo)
    try await model.convert(lineID: model.lines.single.id, to: .text)
    XCTAssertEqual(model.lines.single.kind, .text)
}
```

- [ ] **Step 2: Implement observable models**

```swift
@MainActor @Observable
final class AppRouter {
    var scope: LibraryScope = .inbox
    var selectedCardID: CardID?
    var presentedSettings = false
}

@MainActor @Observable
final class CardEditorModel {
    var title = ""
    var lines: [CardLine] = []
    var unsavedText: [LineID: String] = [:]
    var saveState: SaveState = .saved
}
```

Add a 400ms cancellable text debounce. On failure retain draft text and show Retry. Flush pending edits before selection changes or window close.

- [ ] **Step 3: Implement UI and keyboard parity**

Use `NavigationSplitView`. Search title, text, and todos across all scopes. Support drag reorder plus localized Move Up/Move Down commands calling the same repository reorder method.

- [ ] **Step 4: Add UI tests**

Test navigation, search results with scope labels, title edit, default todo, type conversion, completion, keyboard reorder, archive, trash, restore, save failure, and retry. Assert there is one App window.

- [ ] **Step 5: Run and commit**

Run: `zsh apple/scripts/test.sh`  
Expected: PASS.

```bash
git add apple/PetalChecklist apple/PetalChecklistTests apple/PetalChecklistUITests
git commit -m "feat: add card library and mixed-line editor"
```

### Task 5: Global Quick Capture

**Files:**
- Create: `apple/PetalChecklist/QuickCapture/GlobalHotKeyClient.swift`
- Create: `apple/PetalChecklist/QuickCapture/QuickCaptureCoordinator.swift`
- Create: `apple/PetalChecklist/QuickCapture/QuickCaptureModel.swift`
- Create: `apple/PetalChecklist/QuickCapture/QuickCaptureView.swift`
- Test: `apple/PetalChecklistTests/QuickCaptureModelTests.swift`
- Test: `apple/PetalChecklistUITests/QuickCaptureUITests.swift`

**Interfaces:**
- Consumes: Inbox or card-target deep link.
- Produces: `QuickCaptureCoordinator.present(targetCardID:)` and configurable `GlobalHotKeyClient.register(_:)`.

- [ ] **Step 1: Write failing draft-preservation test**

```swift
@MainActor
func testFailurePreservesDraftAndSuccessCloses() async {
    let client = StubQuickCaptureClient(results: [.failure(.diskFull), .success(())])
    let model = QuickCaptureModel(target: .inbox, client: client)
    model.text = "Buy tea"
    await model.submit()
    XCTAssertEqual(model.text, "Buy tea")
    XCTAssertFalse(model.shouldClose)
    await model.submit()
    XCTAssertTrue(model.shouldClose)
}
```

- [ ] **Step 2: Implement panel, shortcut, and keys**

Use reusable `NSPanel`, restore the previous foreground App after success/cancel, and wrap Carbon `RegisterEventHotKey` for `⌥⌘N`. Plain Enter submits, Shift+Enter inserts newline, Escape cancels. Registration conflict must surface in Settings.

- [ ] **Step 3: Add UI and timing tests**

Launch with `-open-quick-capture`, enter multiline content, submit, verify Inbox, then measure hot invocation to first responder. Record a failing performance result over 300ms.

- [ ] **Step 4: Run and commit**

Run: `zsh apple/scripts/test.sh`  
Expected: PASS.

```bash
git add apple/PetalChecklist/QuickCapture apple/PetalChecklistTests apple/PetalChecklistUITests
git commit -m "feat: add global quick capture panel"
```

## Phase 2 — Widget-First Experience

### Task 6: Widget Configuration, Snapshots, and Rendering

**Files:**
- Create: `apple/Packages/PetalKit/Sources/PetalCore/WidgetSnapshot.swift`
- Create: `apple/Packages/PetalKit/Sources/PetalPersistence/WidgetSnapshotBuilder.swift`
- Create: `apple/PetalWidgets/ChecklistWidget.swift`
- Create: `apple/PetalWidgets/ChecklistWidgetConfiguration.swift`
- Create: `apple/PetalWidgets/ChecklistTimelineProvider.swift`
- Create: `apple/PetalWidgets/ChecklistWidgetView.swift`
- Test: `apple/Packages/PetalKit/Tests/PetalPersistenceTests/WidgetSnapshotBuilderTests.swift`

**Interfaces:**
- Consumes: active cards and ordered lines from the shared repository.
- Produces: `WidgetSnapshotBuilder.snapshot(cardID:size:now:calendar:)` and configurable medium/large views.

- [ ] **Step 1: Write failing capacity and midnight tests**

```swift
@Test func mediumSnapshotShowsFiveRowsAndCountsOverflow() async throws {
    let repository = InMemoryPetalRepository.cardWithTodos(count: 8)
    let snapshot = try await WidgetSnapshotBuilder(repository: repository).snapshot(
        cardID: repository.fixtureCardID,
        size: .medium,
        now: .now,
        calendar: .current
    )
    #expect(snapshot.visibleLines.count == 5)
    #expect(snapshot.hiddenCount == 3)
}
```

Add a fixed-calendar test asserting `nextRefresh` is the next local midnight.

- [ ] **Step 2: Implement snapshot rules**

Medium capacity is five rows; large capacity is ten. Map WidgetKit families to `WidgetDisplaySize` at the extension boundary. Preserve manual order among incomplete items, append items completed on the current local day, exclude older completed items, and count every excluded displayable row.

```swift
public struct WidgetSnapshot: Sendable, Equatable {
    public let cardID: CardID
    public let title: String
    public let visibleLines: [WidgetLine]
    public let hiddenCount: Int
    public let cardState: WidgetCardState
    public let syncBadge: WidgetSyncBadge?
    public let nextRefresh: Date
}
```

- [ ] **Step 3: Implement App Intent configuration entities**

Create `CardEntity`, `CardEntityQuery`, `ThemeOption`, `TypefaceOption`, `MaterialOption`, and `ChecklistWidgetConfigurationIntent`. Query active cards; retain a previously configured archived/deleted ID so the Widget can show an explicit unavailable state.

- [ ] **Step 4: Implement timeline and view states**

Support only `.systemMedium` and `.systemLarge`. Provide privacy-safe gallery placeholders plus normal, overflow, empty, archived, trashed, persistence-error, light, dark, and vibrant previews.

- [ ] **Step 5: Run and commit**

Run snapshot tests and build the Widget scheme; expected PASS.

```bash
git add apple/PetalWidgets apple/Packages/PetalKit/Sources/PetalCore apple/Packages/PetalKit/Sources/PetalPersistence apple/Packages/PetalKit/Tests
git commit -m "feat: render configurable checklist widgets"
```

### Task 7: Widget App Intents and Deep Links

**Files:**
- Create: `apple/PetalWidgets/Intents/ToggleTodoIntent.swift`
- Create: `apple/PetalWidgets/Intents/OpenCardIntent.swift`
- Create: `apple/PetalWidgets/Intents/QuickAddIntent.swift`
- Create: `apple/PetalChecklist/Navigation/DeepLinkHandler.swift`
- Test: `apple/PetalChecklistTests/WidgetIntentTests.swift`

**Interfaces:**
- Consumes: shared repository, `petal://card/<uuid>`, `petal://quick-add/<uuid>`, QuickCaptureCoordinator.
- Produces: direct Toggle, card opening, and card-targeted quick add.

- [ ] **Step 1: Write failing stale-line test**

```swift
func testToggleDeletedLineIsSafeAndRequestsReload() async {
    let repository = StubRepository(line: nil)
    let reloader = SpyWidgetReloader()
    let result = await ToggleTodoIntent(lineID: deletedID, completed: true)
        .perform(repository: repository, reloader: reloader)
    XCTAssertEqual(result, .contentUnavailable)
    XCTAssertEqual(reloader.reloadedKinds, [ChecklistWidget.kind])
}
```

- [ ] **Step 2: Implement direct completion**

Look up the line, safely report unavailable if missing or not a todo, otherwise persist with the injected clock. Always reload the Widget kind after the attempt; never recreate missing data.

- [ ] **Step 3: Implement card and quick-add deep links**

Validate UUID and current card state in `DeepLinkHandler`. `OpenCardIntent` selects the editor. `QuickAddIntent` presents the panel with that card; no intent attempts inline text entry.

- [ ] **Step 4: Wire controls and accessibility**

Use `Toggle(isOn:intent:label:)` for todos, `Link` for text and overflow, and an App Intent button for plus. Give every target a localized label, state, and adequate hit area.

- [ ] **Step 5: Run and commit**

Run WidgetIntentTests and `zsh apple/scripts/test.sh`; expected PASS.

```bash
git add apple/PetalWidgets apple/PetalChecklist/Navigation apple/PetalChecklistTests
git commit -m "feat: complete todos from desktop widgets"
```

## Phase 3 — Reminders, Sync, and Data Portability

### Task 8: Notification Permission and Reminder Reconciliation

**Files:**
- Create: `apple/Packages/PetalKit/Sources/PetalNotifications/ReminderScheduling.swift`
- Create: `apple/Packages/PetalKit/Sources/PetalNotifications/UserNotificationScheduler.swift`
- Create: `apple/Packages/PetalKit/Sources/PetalNotifications/NotificationActionHandler.swift`
- Create: `apple/PetalChecklist/CardEditor/ReminderEditorView.swift`
- Test: `apple/Packages/PetalKit/Tests/PetalNotificationsTests/ReminderSchedulerTests.swift`

**Interfaces:**
- Consumes: todo reminders, injected clock/calendar, notification center adapter.
- Produces: permission request, full reconciliation, cancel, complete, snooze-five-minutes, and open-card actions.

- [ ] **Step 1: Write failing authorization tests**

```swift
@Test func permissionIsRequestedOnlyWhenFirstReminderIsSaved() async throws {
    let center = FakeNotificationCenter(state: .notDetermined)
    let scheduler = UserNotificationScheduler(center: center)
    try await scheduler.saveReminder(fixtureReminder)
    #expect(center.authorizationRequestCount == 1)
}

@Test func deniedPermissionKeepsModelButSchedulesNothing() async throws {
    let center = FakeNotificationCenter(state: .denied)
    let scheduler = UserNotificationScheduler(center: center)
    let result = try await scheduler.reconcile(lines: [fixtureLine], now: fixedNow, calendar: fixedCalendar)
    #expect(result == .permissionDenied)
    #expect(center.pendingRequests.isEmpty)
}
```

- [ ] **Step 2: Implement protocol and stable identifiers**

```swift
public protocol ReminderScheduling: Sendable {
    func requestAuthorization() async throws -> AuthorizationState
    func reconcile(lines: [CardLine], now: Date, calendar: Calendar) async throws -> ReconcileResult
    func cancel(lineID: LineID) async
    func cancelAll() async
}
```

Use `line.<uuid>` and `line.<uuid>.snooze`. Register `complete`, `snooze-5m`, and `open-card`; use no sound unless enabled.

- [ ] **Step 3: Reconcile deterministically**

Diff all desired requests against pending Petal requests, replace changed schedules, and cancel stale ones. Reconcile after launch, foreground, local mutation, inbound sync, date change, and time-zone change.

- [ ] **Step 4: Test date edge cases**

Verify spring-forward nonexistent times move to the next valid occurrence, fall-back repeated times fire once, one-time reminders preserve absolute instants, snooze replaces prior snooze, and completion cancels both identifiers.

- [ ] **Step 5: Run and commit**

Run: `swift test --package-path apple/Packages/PetalKit --filter PetalNotificationsTests`  
Expected: PASS.

```bash
git add apple/Packages/PetalKit/Sources/PetalNotifications apple/Packages/PetalKit/Tests/PetalNotificationsTests apple/PetalChecklist/CardEditor
git commit -m "feat: add local todo reminders"
```

### Task 9: CloudKit Outbox, Conflicts, and Reset

**Files:**
- Create: `apple/Packages/PetalKit/Sources/PetalSync/CloudRecordMapper.swift`
- Create: `apple/Packages/PetalKit/Sources/PetalSync/CloudTransport.swift`
- Create: `apple/Packages/PetalKit/Sources/PetalSync/CKSyncTransport.swift`
- Create: `apple/Packages/PetalKit/Sources/PetalSync/CloudSyncCoordinator.swift`
- Create: `apple/Packages/PetalKit/Sources/PetalSync/ConflictResolver.swift`
- Create: `apple/Packages/PetalKit/Sources/PetalSync/ResetGenerationCoordinator.swift`
- Create: `apple/PetalChecklist/App/AppLifecycleCoordinator.swift`
- Create: `apple/PetalChecklist/Settings/SyncSettingsView.swift`
- Test: `apple/Packages/PetalKit/Tests/PetalSyncTests/CloudSyncTests.swift`

**Interfaces:**
- Consumes: persistence outbox/inbound API, CloudKit private database, sync preference, notification reconciliation, Widget reload.
- Produces: `CloudSyncCoordinator.sync(reason:)`, deterministic line-level merge, 30-day conflict artifacts, sync disable/re-enable, and global reset generation.

- [ ] **Step 1: Write failing offline and tombstone tests**

```swift
@Test func offlineFailureKeepsOutboxAndLocalEdit() async throws {
    let repository = try fixtureRepositoryWithOnePendingEdit()
    let coordinator = CloudSyncCoordinator(
        repository: repository,
        transport: FakeCloudTransport(result: .failure(.networkUnavailable))
    )
    await coordinator.sync(reason: .foreground)
    #expect(try await repository.pendingOutboxCount() == 1)
    #expect(try await repository.lines(cardID: fixtureCardID).single.text == "Local edit")
}

@Test func recentTombstonePreventsOfflineResurrection() {
    #expect(ConflictResolver.resolve(entity: staleEdit, tombstone: recentTombstone, now: fixedNow) == .keepDeleted)
}
```

- [ ] **Step 2: Implement Cloud record mapping and transport**

Map `PTCard`, `PTLine`, `PTUserState`, and `PTTombstone`, using UUID record names, UTC dates, revision, device ID, and versioned reminder data.

```swift
public protocol CloudTransport: Sendable {
    func send(_ changes: [OutboundCloudChange]) async throws -> CloudSendResult
    func fetchChanges(after token: Data?) async throws -> CloudFetchResult
}
```

- [ ] **Step 3: Implement fetch-merge-send ordering**

Fetch inbound changes first, apply them transactionally, then send the merged outbox. Persist server token and outbox, coalesce concurrent sync requests, respect retry-after, and expose synced/syncing/offline/failed state.

- [ ] **Step 4: Implement conflicts and tombstones**

Different line records merge. Same-record conflicts compare `modifiedAt`, then `deviceID`; preserve losing user-visible payload for 30 days and present once. An unexpired tombstone wins over stale offline edits.

- [ ] **Step 5: Implement toggle and delete-all generation**

Disabling sync stops transport but retains local data/outbox. Re-enabling fetches before sending. Delete All changes generation, clears local and cloud records, cancels notifications, reloads Widgets, and creates one empty Inbox; other devices purge stale generations.

- [ ] **Step 6: Add lifecycle ordering test**

```swift
func testInboundCompletionOrdersSideEffects() async {
    let events = EventRecorder()
    await fixtureLifecycle(events: events).handle(.inboundSyncCompleted)
    XCTAssertEqual(events.values, ["refresh-store", "reconcile-notifications", "reload-widgets"])
}
```

- [ ] **Step 7: Run and commit**

Run: `swift test --package-path apple/Packages/PetalKit --filter PetalSyncTests` and `zsh apple/scripts/test.sh`.  
Expected: PASS.

```bash
git add apple/Packages/PetalKit/Sources/PetalSync apple/Packages/PetalKit/Tests/PetalSyncTests apple/PetalChecklist/App apple/PetalChecklist/Settings
git commit -m "feat: sync Petal data through private iCloud"
```

### Task 10: Windows Import, JSON Restore, and Markdown Export

**Files:**
- Create: `apple/Packages/PetalKit/Sources/PetalImportExport/WindowsSchemaV1.swift`
- Create: `apple/Packages/PetalKit/Sources/PetalImportExport/WindowsNotesImporter.swift`
- Create: `apple/Packages/PetalKit/Sources/PetalImportExport/PetalBackupCodec.swift`
- Create: `apple/Packages/PetalKit/Sources/PetalImportExport/MarkdownExporter.swift`
- Create: `apple/PetalChecklist/Settings/DataTransferView.swift`
- Test: `apple/Packages/PetalKit/Tests/PetalImportExportTests/WindowsImporterTests.swift`
- Test: `apple/Packages/PetalKit/Tests/PetalImportExportTests/BackupRoundTripTests.swift`

**Interfaces:**
- Consumes: user-selected files, batch repository transactions, current schema version.
- Produces: idempotent Windows import, Petal JSON backup/restore, Markdown folder export, and pre-import backup.

- [ ] **Step 1: Add sanitized Windows fixture and failing mapping tests**

Build a SchemaVersion 1 fixture containing title, multiline body, todos, completion, reminder, theme, window geometry, hidden state, and Pomodoro. Assert paragraphs become text rows, todos become todo rows, and unsupported window/Pomodoro data is absent.

- [ ] **Step 2: Write persistent duplicate-import test**

```swift
@Test func sameImportAfterRelaunchCreatesNoDuplicates() async throws {
    let storeURL = temporaryStoreURL()
    try await importFixture(into: storeURL)
    try await importFixture(into: storeURL)
    let reopened = try repository(at: storeURL)
    #expect(try await reopened.cards(scope: .all).count == expectedCardCount)
}
```

- [ ] **Step 3: Implement transactional mapping and fingerprinting**

Compute SHA-256 over source bytes plus source Note ID. Validate the entire document before one batch transaction and create a Petal JSON backup first. Bind a legacy note reminder to its first incomplete todo; if no todo exists, create one from the title.

- [ ] **Step 4: Implement Petal JSON and Markdown**

JSON includes schema version, cards, lines, reminders, themes, and sync-independent settings; excludes Widget configuration, device ID, outbox, CloudKit tokens, and notification IDs. Markdown uses `# Title`, paragraphs, `- [ ]`/`- [x]`, and a localized indented reminder note.

- [ ] **Step 5: Test rollback and future schema rejection**

Corrupt and unsupported files must leave the store byte-for-byte logically unchanged. Duplicate Markdown filenames append a stable short Card ID.

- [ ] **Step 6: Run and commit**

Run: `swift test --package-path apple/Packages/PetalKit --filter PetalImportExportTests`  
Expected: PASS.

```bash
git add apple/Packages/PetalKit/Sources/PetalImportExport apple/Packages/PetalKit/Tests/PetalImportExportTests apple/PetalChecklist/Settings
git commit -m "feat: import Windows notes and export Petal data"
```

## Phase 4 — Product Polish and Distribution

### Task 11: Themes, Localization, Onboarding, and Support

**Files:**
- Create: `apple/Packages/PetalKit/Sources/PetalDesignSystem/PetalTheme.swift`
- Create: `apple/Packages/PetalKit/Sources/PetalDesignSystem/PetalTypography.swift`
- Create: `apple/PetalChecklist/Resources/Localizable.xcstrings`
- Create: `apple/PetalWidgets/Resources/Widgets.xcstrings`
- Create: `apple/PetalChecklist/Resources/InfoPlist.xcstrings`
- Create: `apple/PetalChecklist/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json`
- Create: `design/app-icon/petal-app-icon.svg`
- Create: `apple/PetalChecklist/Onboarding/OnboardingView.swift`
- Create: `apple/PetalChecklist/Settings/HelpView.swift`
- Create: `apple/PetalChecklist/Settings/PrivacyView.swift`
- Create: `docs/legal/privacy-policy-zh-Hans.md`
- Create: `docs/legal/privacy-policy-en.md`
- Create: `docs/support/faq-zh-Hans.md`
- Create: `docs/support/faq-en.md`
- Create: `site/index.html`
- Create: `site/privacy/zh-Hans.html`
- Create: `site/privacy/en.html`
- Create: `site/support/zh-Hans.html`
- Create: `site/support/en.html`
- Create: `.github/workflows/petal-pages.yml`
- Create: `apple/scripts/verify-localization.sh`
- Test: `apple/Packages/PetalKit/Tests/PetalDesignSystemTests/ThemeContrastTests.swift`
- Test: `apple/PetalChecklistUITests/OnboardingAndSettingsUITests.swift`

**Interfaces:**
- Consumes: fixed theme IDs, system rendering mode, repository bootstrap/reset, app/system version provider.
- Produces: five accessible themes, complete bilingual copy, three-step onboarding, feedback/privacy/help, and confirmed delete-all UI.

- [ ] **Step 1: Write failing theme completeness tests**

```swift
@Test(arguments: ThemeID.allCases)
func everyThemeHasAllRenderingModes(_ id: ThemeID) {
    #expect(PetalTheme.tokens(id: id, mode: .light) != nil)
    #expect(PetalTheme.tokens(id: id, mode: .dark) != nil)
    #expect(PetalTheme.tokens(id: id, mode: .vibrant) != nil)
}
```

Add a 4.5:1 minimum primary-text contrast check in each declared mode.

- [ ] **Step 2: Implement five fixed theme families**

Implement cream, mint, sakura, sky, and paper using semantic colors and only `Font.system` default, rounded, and serif designs. Do not load bundled or arbitrary installed fonts.

Create a complete macOS AppIcon set using the existing owned five-petal mark on a cream paper surface, with no text and sufficient edge contrast at 16px. Export every size required by the Xcode asset catalog from one version-controlled vector master.

- [ ] **Step 3: Move every user-facing string into catalogs**

Cover navigation, editing, Widget configuration, notification actions, errors, onboarding, data transfer, accessibility labels, App name, and permission text in `zh-Hans` and `en`.

- [ ] **Step 4: Add strict localization verification**

```bash
#!/bin/zsh
set -euo pipefail
for catalog in apple/PetalChecklist/Resources/*.xcstrings apple/PetalWidgets/Resources/*.xcstrings; do
  jq -e '[.strings[] | select(.localizations.en == null or .localizations."zh-Hans" == null)] | length == 0' "$catalog" >/dev/null
done
```

- [ ] **Step 5: Implement onboarding and support**

On a fresh store create Inbox plus one sample card containing three localized todos: add Widget, complete a todo, create a card. Persist onboarding completion locally only. Feedback email contains App version, build, macOS version, and architecture but no content or logs.

- [ ] **Step 6: Implement delete-all confirmation and legal copy**

Require typing the localized product name, explain all synced devices are affected, invoke reset generation, cancel notifications, reload Widgets, and show an empty Inbox. Privacy copy must accurately state local/private-iCloud storage and no developer collection.

Render the same approved privacy and support text as static bilingual HTML in `site/`. Configure the Pages workflow to deploy only `site/` from `main`; use relative language links, no cookies, remote fonts, analytics, or third-party scripts.

- [ ] **Step 7: Run and commit**

Run design tests, localization verification, focused UI tests, and `zsh apple/scripts/test.sh`; expected PASS.

```bash
git add apple docs/legal docs/support
git commit -m "feat: add themes onboarding and bilingual support"
```

### Task 12: Accessibility, Diagnostics, and Performance Gates

**Files:**
- Create: `apple/PetalChecklist/App/Diagnostics.swift`
- Create: `apple/PetalChecklist/Resources/PrivacyInfo.xcprivacy`
- Create: `apple/PetalWidgets/Resources/PrivacyInfo.xcprivacy`
- Create: `apple/PetalChecklistUITests/KeyboardOnlyUITests.swift`
- Create: `apple/PetalChecklistUITests/AccessibilityUITests.swift`
- Create: `apple/PetalChecklistTests/PerformanceTests.swift`
- Create: `apple/scripts/verify-release.sh`
- Create: `docs/validation/apple-release-checklist.md`

**Interfaces:**
- Consumes: all shipped flows and typed diagnostic events.
- Produces: privacy-safe seven-day ring log, keyboard/VoiceOver proof, performance baselines, universal release archive, and manual Widget/iCloud matrix.

- [ ] **Step 1: Test keyboard and accessibility paths**

Cover create card, add/convert/reorder todo, search, archive, restore, set reminder, Settings, and delete-all without pointer actions. Assert every icon-only control and Widget row has a localized label, value/state, and visible focus.

- [ ] **Step 2: Test 500 cards and 5,000 rows**

```swift
func testSearchAcrossFiveThousandLines() async throws {
    let repository = try await PerformanceFixture.make(cards: 500, linesPerCard: 10)
    let clock = ContinuousClock()
    let start = clock.now
    let results = try await repository.search("needle")
    XCTAssertFalse(results.isEmpty)
    XCTAssertLessThan(start.duration(to: clock.now), .milliseconds(300))
}
```

Measure cold launch to editable state, hot quick-capture to first responder, and Widget intent to local save. Fail tracked baselines over 2 seconds, 300ms, and 1 second respectively on the reference Mac in three consecutive release runs.

- [ ] **Step 3: Implement typed privacy-safe diagnostics**

The logger accepts only timestamp, subsystem enum, error-code enum, sync-state enum, App version, and OS version. It has no API accepting card titles or line text. Keep a size-capped seven-day local ring; export only on explicit user action.

Add privacy manifests to both shipped targets. Declare only APIs actually used after running Xcode’s privacy report; fail review if the report shows an undeclared required-reason API or a data category inconsistent with the “no developer collection” policy.

- [ ] **Step 4: Add release verification**

```bash
#!/bin/zsh
set -euo pipefail
root_dir="$(cd "$(dirname "$0")/.." && pwd)"
"$root_dir/scripts/test.sh"
"$root_dir/scripts/verify-localization.sh"
xcodebuild archive -project "$root_dir/PetalChecklist.xcodeproj" -scheme PetalChecklist -configuration Release -destination 'generic/platform=macOS' -archivePath "$root_dir/build/PetalChecklist.xcarchive"
lipo -archs "$root_dir/build/PetalChecklist.xcarchive/Products/Applications/PetalChecklist.app/Contents/MacOS/PetalChecklist" | grep -Eq 'x86_64 arm64|arm64 x86_64'
```

- [ ] **Step 5: Execute the manual matrix**

Record dated results for medium/large Widget setup, light/dark/vibrant rendering, Apple Silicon, Intel, both languages, VoiceOver, Reduce Motion, offline/reconnect, app and Mac restart, two-device conflicts, cross-device notification cancellation, import, restore, export, and delete-all.

- [ ] **Step 6: Run and commit**

Run: `zsh apple/scripts/verify-release.sh`  
Expected: all tests pass and release binary lists both architectures.

```bash
git add apple docs/validation
git commit -m "test: enforce Petal release quality gates"
```

### Task 13: Developer Program, TestFlight, and App Store Submission

**Files:**
- Modify: `apple/Config/Release.xcconfig`
- Modify: `apple/PetalChecklist/PetalChecklist.entitlements`
- Modify: `apple/PetalWidgets/PetalWidgets.entitlements`
- Create: `docs/release/app-store-metadata-zh-Hans.md`
- Create: `docs/release/app-store-metadata-en.md`
- Create: `docs/release/review-notes.md`
- Create: `docs/validation/testflight-four-week-report.md`

**Interfaces:**
- Consumes: Apple Developer Program membership, registered identifiers, production CloudKit schema, release archive, privacy/support URLs, genuine screenshots.
- Produces: external TestFlight build, four-week validation report, App Review submission.

- [ ] **Step 1: Register and freeze production identifiers**

After Task 7 passes on the development Mac, enroll as an individual unless an organization account has been approved. Attempt the architecture’s identifier set; if Apple reports a collision, select one replacement namespace and update all `.xcconfig` and entitlement values before uploading any build.

- [ ] **Step 2: Create App Store Connect record**

Use localized names “花瓣清单：桌面小组件” and “Petal Checklist Widget”, category Productivity, price Free, and target age rating 4+. Record final names and identifiers in both metadata documents.

- [ ] **Step 3: Promote CloudKit schema**

Exercise every record type in development, inspect fields and indexes, deploy to production, and run a clean-account two-Mac test against production before external beta.

- [ ] **Step 4: Prepare bilingual store material**

Write subtitle, description, keywords, privacy URL, support URL, copyright, and review notes. Capture genuine macOS screenshots showing onboarding, medium/large Widgets, completion, editor, themes, reminder, and sync; never reuse Windows previews.

- [ ] **Step 5: Run four-week external beta**

Invite 20–30 target users. Record weekly aggregate counts without note content: successful Widget setup, continued use at week four, and interview respondents who would be meaningfully inconvenienced without Petal.

- [ ] **Step 6: Apply market gate and submit**

Submit publicly only if at least 14 of the first 20 add a Widget, at least 8 still use it at week four, at least 5 report meaningful loss, and Task 12 remains green. Otherwise document the failed journey step, revise its requirement, and test another build.

- [ ] **Step 7: Commit distribution evidence**

```bash
git add apple/Config apple/PetalChecklist/*.entitlements apple/PetalWidgets/*.entitlements docs/release docs/validation/testflight-four-week-report.md
git commit -m "docs: prepare Petal App Store submission"
```

## Spec Coverage Matrix

| Requirement group | Owning tasks |
| --- | --- |
| FR-001–FR-011 Card/content | 2, 3, 4 |
| FR-020–FR-032 Widget | 6, 7, 9 |
| FR-040–FR-047 App shell/quick capture/sync state | 4, 5, 9 |
| FR-050–FR-054 Completion semantics | 2, 3, 6 |
| FR-060–FR-068 Reminders | 2, 8, 9 |
| FR-070–FR-078 Local data/iCloud | 3, 9 |
| FR-080–FR-087 Import/export/delete | 9, 10, 11 |
| FR-090–FR-094 Themes/localization | 11 |
| FR-100–FR-103 Onboarding/help/feedback | 11 |
| NFR-001–NFR-004 Performance | 5, 7, 12 |
| NFR-010–NFR-013 Reliability/migration | 3, 9, 10, 12 |
| NFR-020–NFR-024 Privacy/security | 1, 9, 11, 12, 13 |
| NFR-030–NFR-033 Accessibility | 7, 11, 12 |
| NFR-040–NFR-042 Compatibility | 1, 6, 9, 12 |

## Execution Order and Review Gates

1. **Local App gate:** Tasks 1–5 pass before Widget work.
2. **Core product gate:** Tasks 6–7 demonstrate add Widget → view card → toggle → open editor → quick add. This is the Apple Developer Program enrollment point.
3. **Connected product gate:** Tasks 8–10 pass on two real Macs before polish.
4. **Release gate:** Tasks 11–12 pass before external TestFlight.
5. **Market gate:** Task 13 beta criteria pass before public App Store submission.

This remains one plan because each later gate relies on exact model, repository, and App Intent interfaces established by earlier gates. Do not start a later phase while an earlier review gate has unresolved findings.
