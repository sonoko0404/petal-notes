import Foundation

/// Foreground intents and external URLs share the App's draft-preserving router.
/// A cold launch queues requests until its store and window are ready.
@MainActor
public final class PetalNavigationRequests {
    public static let shared = PetalNavigationRequests()
    private var pending: [URL] = []
    private var handler: (@MainActor (URL) async -> Void)?
    private var isDraining = false
    public init() {}
    public func open(_ url: URL) async {
        pending.append(url)
        await drain()
    }
    public func install(_ handler: @escaping @MainActor (URL) async -> Void) async {
        self.handler = handler
        await drain()
    }

    private func drain() async {
        guard !isDraining, handler != nil else { return }
        isDraining = true
        defer { isDraining = false }
        while !pending.isEmpty, let handler {
            let url = pending.removeFirst()
            await handler(url)
        }
    }
}
