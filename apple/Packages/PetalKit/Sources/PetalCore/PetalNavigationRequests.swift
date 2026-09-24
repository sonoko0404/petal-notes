import Foundation

/// Foreground intents and external URLs share the App's draft-preserving router.
/// A cold launch queues requests until its store and window are ready.
@MainActor
public final class PetalNavigationRequests {
    public static let shared = PetalNavigationRequests()
    private var pending: [URL] = []
    private var handler: (@MainActor (URL) async -> Void)?
    public init() {}
    public func open(_ url: URL) async {
        if let handler { await handler(url) } else { pending.append(url) }
    }
    public func install(_ handler: @escaping @MainActor (URL) async -> Void) async {
        self.handler = handler
        let requests = pending
        pending.removeAll()
        for url in requests { await handler(url) }
    }
}
