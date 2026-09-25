import Foundation
import SwiftUI
import PetalCore

public enum PetalRenderingMode: CaseIterable, Sendable { case light, dark, vibrant }

public struct PetalColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public init(_ rgb: UInt32) {
        red = Double((rgb >> 16) & 255) / 255
        green = Double((rgb >> 8) & 255) / 255
        blue = Double(rgb & 255) / 255
    }
    public var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }
    public var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
    public func contrast(on other: PetalColor) -> Double {
        (max(luminance, other.luminance) + 0.05) / (min(luminance, other.luminance) + 0.05)
    }
}

public struct PetalThemeTokens: Sendable {
    public let surface: PetalColor
    public let primary: PetalColor
    public let secondary: PetalColor
    public let control: PetalColor
    public let focus: PetalColor
}

public enum PetalTheme {
    public static func tokens(id: ThemeID, mode: PetalRenderingMode) -> PetalThemeTokens {
        let surface: UInt32
        switch (id, mode) {
        case (_, .vibrant): surface = 0xffffff
        case (.cream, .light): surface = 0xfaf2db
        case (.mint, .light): surface = 0xdbf2e3
        case (.sakura, .light): surface = 0xfce3e8
        case (.sky, .light): surface = 0xdeeffc
        case (.paper, .light): surface = 0xf5f5f5
        case (.cream, .dark): surface = 0x332e24
        case (.mint, .dark): surface = 0x1f332b
        case (.sakura, .dark): surface = 0x3b262e
        case (.sky, .dark): surface = 0x212e3d
        case (.paper, .dark): surface = 0x292929
        }
        let dark = mode == .dark
        return PetalThemeTokens(surface: PetalColor(surface), primary: PetalColor(dark ? 0xf5f5f5 : 0x202020),
            secondary: PetalColor(dark ? 0xd0d0d0 : 0x505050), control: PetalColor(dark ? 0xd0d0d0 : 0x505050),
            focus: PetalColor(dark ? 0x9ccaff : 0x225c91))
    }
    public static func usesTransparency(requested: Bool, reduceTransparency: Bool, increaseContrast: Bool) -> Bool {
        requested && !reduceTransparency && !increaseContrast
    }
}
