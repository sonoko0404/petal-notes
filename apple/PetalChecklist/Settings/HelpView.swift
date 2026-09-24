import SwiftUI

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("ui.help.b79cac").font(.title)
                Text("help.body").textSelection(.enabled)
            }.padding()
        }.frame(minWidth: 420, minHeight: 360)
    }
}

struct SupportSettingsView: View {
    @State private var showHelp = false
    @State private var showPrivacy = false
    private var feedbackURL: URL? {
        FeedbackInfo.current.mailURL(email: Bundle.main.object(forInfoDictionaryKey: "PetalFeedbackEmail") as? String ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("ui.help.b79cac") { showHelp = true }.accessibilityIdentifier("settings.help")
                Button("ui.privacy.54a57c") { showPrivacy = true }.accessibilityIdentifier("settings.privacy")
                if let feedbackURL { Link("ui.feedback.aac77d", destination: feedbackURL) }
                else { Button("ui.feedback.aac77d") {}.disabled(true) }
            }
            if feedbackURL == nil { Text("ui.a_support_email_will_be_configured_before_release.9de5d3").font(.caption) }
            Text("ui.feedback_includes_only_app_version_build_macos_version_.4bc103").font(.caption)
        }
        .sheet(isPresented: $showHelp) { VStack { HelpView(); Button("ui.close.7d9eb7") { showHelp = false }.padding() } }
        .sheet(isPresented: $showPrivacy) { VStack { PrivacyView(); Button("ui.close.7d9eb7") { showPrivacy = false }.padding() } }
    }
}
