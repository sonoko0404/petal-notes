import Foundation
import Observation
import PetalCore
import PetalPersistence

enum QuickCaptureTarget: Equatable {
    case inbox
    case card(CardID)
}

@MainActor @Observable
final class QuickCaptureModel {
    private let repository: any PetalRepository
    let target: QuickCaptureTarget
    private(set) var text = ""
    private(set) var isSubmitting = false
    private(set) var shouldClose = false
    private(set) var errorMessage: String?
    private(set) var targetNotice: String?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var pending: Pending?

    private struct Pending {
        let revision: Int
        let lines: [String]
        var nextIndex: Int
        var cardID: CardID?
    }

    init(repository: any PetalRepository, target: QuickCaptureTarget) {
        self.repository = repository
        self.target = target
    }

    func edit(_ value: String) {
        guard value != text else { return }
        text = value
        revision += 1
        shouldClose = false
        errorMessage = nil
    }

    func submit() async {
        guard !isSubmitting, !shouldClose else { return }
        if pending == nil {
            let lines = text.components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !lines.isEmpty else { return }
            pending = Pending(revision: revision, lines: lines, nextIndex: 0, cardID: nil)
        }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let cardID: CardID
            if let committedTarget = pending?.cardID {
                cardID = committedTarget
            } else {
                cardID = try await resolveTarget()
                pending?.cardID = cardID
            }
            while let next = pending, next.nextIndex < next.lines.count {
                guard try await repository.card(id: cardID)?.status == .active else {
                    throw QuickCaptureError.targetUnavailableAfterPartialSave
                }
                _ = try await repository.addLine(
                    NewLineDraft(cardID: cardID, kind: .todo, text: next.lines[next.nextIndex]), now: .now
                )
                pending?.nextIndex += 1
            }
            let completed = pending
            pending = nil
            errorMessage = nil
            if completed?.revision == revision {
                text = ""
                shouldClose = true
            }
        } catch QuickCaptureError.confirmFallback {
            // Keep the exact draft visible until the user confirms Inbox with another submit.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func resolveTarget() async throws -> CardID {
        if case let .card(id) = target {
            if let card = try await repository.card(id: id), card.status == .active {
                return id
            }
            if targetNotice == nil {
                targetNotice = String(localized: "The selected card is unavailable. Press Add again to save to Inbox.")
                throw QuickCaptureError.confirmFallback
            }
        }
        if let inbox = try await repository.cards(scope: .active).first(where: \.isInbox) {
            return inbox.id
        }
        throw QuickCaptureError.inboxUnavailable
    }
}

private enum QuickCaptureError: LocalizedError {
    case inboxUnavailable, confirmFallback, targetUnavailableAfterPartialSave
    var errorDescription: String? {
        switch self {
        case .inboxUnavailable: String(localized: "Inbox is unavailable. Your draft has been kept.")
        case .confirmFallback: nil
        case .targetUnavailableAfterPartialSave:
            String(localized: "The card changed before all lines were saved. Your draft has been kept.")
        }
    }
}
