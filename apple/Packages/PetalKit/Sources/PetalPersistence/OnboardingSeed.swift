import Foundation

public struct OnboardingSeed: Sendable {
    public let inbox: String
    public let title: String
    public let todos: [String]
    public init(inbox: String, title: String, todos: [String]) {
        self.inbox = inbox; self.title = title; self.todos = todos
    }
}
