import Foundation
import Testing
import PetalCore
import PetalPersistence

struct OnboardingTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    @Test func freshBootstrapIsAtomicAndResumable() async throws {
        let store = try ModelContainerFactory.makeInMemory()
        let repository = SwiftDataPetalRepository(container: store)
        let seed = OnboardingSeed(inbox: "收集箱", title: "开始使用", todos: ["添加小组件", "完成待办", "创建卡片"])
        #expect(try await repository.bootstrapOnboarding(seed: seed, now: now))
        let cards = try await repository.cards(scope: .active)
        #expect(cards.count == 2)
        #expect(cards.filter(\.isInbox).count == 1)
        #expect(cards.first(where: \.isInbox)?.title == "收集箱")
        let sample = try #require(cards.first { !$0.isInbox })
        #expect(try await repository.lines(cardID: sample.id).map(\.text) == seed.todos)
        let reopened = SwiftDataPetalRepository(container: store)
        #expect(try await reopened.bootstrapOnboarding(seed: seed, now: now))
        #expect(try await reopened.cards(scope: .active).count == 2)
        try await reopened.completeOnboarding()
        #expect(try await !reopened.bootstrapOnboarding(seed: seed, now: now))
        try await reopened.deleteAllData(resetGeneration: UUID(), now: now)
        #expect(try await !reopened.bootstrapOnboarding(seed: seed, now: now))
        #expect(try await reopened.cards(scope: .active).count == 1)
        #expect(try await reopened.transferSnapshot().lines.isEmpty)
    }
    @Test func existingStoreDoesNotReceiveSample() async throws {
        let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
        try await repository.bootstrap(now: now)
        #expect(try await !repository.bootstrapOnboarding(seed: .init(inbox: "Inbox", title: "Sample", todos: ["a", "b", "c"]), now: now))
        #expect(try await repository.cards(scope: .active).count == 1)
    }
    @Test func resetDuringUnfinishedOnboardingDoesNotResumeTutorial() async throws {
        let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
        let seed = OnboardingSeed(inbox: "Inbox", title: "Sample", todos: ["a", "b", "c"])
        _ = try await repository.bootstrapOnboarding(seed: seed, now: now)
        try await repository.deleteAllData(resetGeneration: UUID(), now: now)
        #expect(try await !repository.bootstrapOnboarding(seed: seed, now: now))
        #expect(try await repository.cards(scope: .active).count == 1)
    }
    @Test func failedBootstrapRollsBackSampleAndCanRetry() async throws {
        let store = try ModelContainerFactory.makeInMemory()
        let failing = SwiftDataPetalRepository(container: store, faultInjector: .failOnceBeforeSave)
        let seed = OnboardingSeed(inbox: "Inbox", title: "Sample", todos: ["a", "b", "c"])
        await #expect(throws: (any Error).self) { try await failing.bootstrapOnboarding(seed: seed, now: now) }
        let reopened = SwiftDataPetalRepository(container: store)
        #expect(try await reopened.cards(scope: .all).isEmpty)
        #expect(try await reopened.bootstrapOnboarding(seed: seed, now: now))
        #expect(try await reopened.cards(scope: .all).count == 2)
        #expect(try await reopened.transferSnapshot().lines.count == 3)
    }
}
