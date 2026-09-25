import SwiftUI

struct PrivacyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("ui.privacy.54a57c").font(.title)
                Text("privacy.body").textSelection(.enabled)
            }.padding()
        }.frame(minWidth: 420, minHeight: 360)
    }
}
