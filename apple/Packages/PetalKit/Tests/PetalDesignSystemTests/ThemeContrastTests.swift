import Testing
import PetalCore
import PetalDesignSystem

struct ThemeContrastTests {
    @Test(arguments: ThemeID.allCases)
    func readableInEveryRenderingMode(_ id: ThemeID) {
        for mode in PetalRenderingMode.allCases {
            let tokens = PetalTheme.tokens(id: id, mode: mode)
            #expect(tokens.primary.contrast(on: tokens.surface) >= 4.5)
            #expect(tokens.secondary.contrast(on: tokens.surface) >= 4.5)
            #expect(tokens.control.contrast(on: tokens.surface) >= 3)
            #expect(tokens.focus.contrast(on: tokens.surface) >= 3)
        }
    }
    @Test func accessibilityForcesOpaqueSurface() {
        #expect(!PetalTheme.usesTransparency(requested: true, reduceTransparency: true, increaseContrast: false))
        #expect(!PetalTheme.usesTransparency(requested: true, reduceTransparency: false, increaseContrast: true))
        #expect(PetalTheme.usesTransparency(requested: true, reduceTransparency: false, increaseContrast: false))
    }
}
