import Testing
import PetalCore

struct LocalizationTests {
    @Test func localizedContentKeepsSemanticIdentityStable() {
        #expect(PetalStrings.text("ui.inbox.94835e", languageCode: "en") == "Inbox")
        #expect(PetalStrings.text("ui.inbox.94835e", languageCode: "zh-Hans") == "收集箱")
        #expect(ThemeID.cream.rawValue == "cream")
    }
}
