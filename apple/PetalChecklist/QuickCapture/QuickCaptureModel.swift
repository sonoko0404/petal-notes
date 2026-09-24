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
    private var allowsInboxFallback: Bool
    private(set) var text = ""
    private(set) var isSubmitting = false
    private(set) var shouldClose = false
    private(set) var errorMessage: String?
    private(set) var targetNotice: String?
    private(set) var lastCommittedCardID: CardID?
    private(set) var focusLatencyMilliseconds: Double?
    @ObservationIgnored private var revision = 0

    init(repository: any PetalRepository, target: QuickCaptureTarget, allowsInboxFallback: Bool = true) {
        self.repository = repository
        self.target = target
        self.allowsInboxFallback = allowsInboxFallback
    }

    func edit(_ value: String) {
        guard value != text else { return }
        text = value
        revision += 1
        shouldClose = false
        errorMessage = nil
    }

    func recordFocusLatency(_ seconds: TimeInterval) {
        focusLatencyMilliseconds = seconds * 1_000
    }

    func requireExactTarget() {
        allowsInboxFallback = false
        targetNotice = nil
    }

    func submit() async {
        guard !isSubmitting, !shouldClose else { return }
        let submittedRevision = revision
        let lines = text.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !lines.isEmpty else { return }
        lastCommittedCardID = nil
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let cardID = try await resolveTarget()
            _ = try await repository.captureTodoLines(cardID: cardID, texts: lines, now: .now)
            lastCommittedCardID = cardID
            errorMessage = nil
            if submittedRevision == revision {
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
            guard allowsInboxFallback else { throw DeepLinkError.unavailable }
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
    case inboxUnavailable, confirmFallback
    var errorDescription: String? {
        switch self {
        case .inboxUnavailable: String(localized: "Inbox is unavailable. Your draft has been kept.")
        case .confirmFallback: nil
        }
    }
}
