import Foundation
import PetalCore
import PetalPersistence

struct AppEnvironment {
    let repository: any PetalRepository

    static func make() async throws -> AppEnvironment {
        let arguments = ProcessInfo.processInfo.arguments
        let testing = arguments.contains("-ui-testing")
        let store: PetalStore
        if testing {
            store = try ModelContainerFactory.makeInMemory()
        } else {
            let groupID = Bundle.main.object(forInfoDictionaryKey: "PetalAppGroupIdentifier") as? String
            store = try ModelContainerFactory.makeShared(appGroupID: groupID ?? "")
        }
        let setup = SwiftDataPetalRepository(container: store)
        try await setup.bootstrap(now: .now)
        if testing && arguments.contains("-ui-sample-cards") {
            let active = try await setup.createCard(title: "Active sample", now: .now)
            _ = try await setup.addLine(NewLineDraft(cardID: active.id, kind: .todo, text: "shared todo"), now: .now)
            if arguments.contains("-ui-extra-active-candidate") {
                _ = try await setup.createCard(title: "Other active sample", now: .now)
            }
            let archived = try await setup.createCard(title: "Archived sample", now: .now)
            _ = try await setup.addLine(NewLineDraft(cardID: archived.id, kind: .text, text: "shared note"), now: .now)
            try await setup.moveCard(archived.id, to: .archived, replacementInbox: nil, now: .now)
        }
        if testing && arguments.contains("-ui-fail-next-save") {
            return AppEnvironment(repository: SwiftDataPetalRepository(container: store, faultInjector: .failOnceBeforeSave))
        }
        return AppEnvironment(repository: setup)
    }
}
