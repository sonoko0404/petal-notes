import SwiftUI

public enum PetalTypeface: String, CaseIterable, Sendable {
    case standard, rounded, serif
    public var design: Font.Design {
        switch self { case .standard: .default; case .rounded: .rounded; case .serif: .serif }
    }
}
