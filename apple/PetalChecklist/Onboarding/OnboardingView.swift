import SwiftUI

struct OnboardingView: View {
    let complete: () async throws -> Void
    @State private var failed = false
    @State private var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("ui.welcome_to_petal.830c7d").font(.largeTitle)
            Text("ui.1_add_a_widget.579b63").font(.headline)
            Text("ui.control_click_the_desktop_choose_edit_widgets_then_find.e7f671")
            Text("ui.2_complete_a_todo.1e6b1d").font(.headline)
            Text("ui.edit_the_widget_to_choose_your_sample_card_click_a_circ.995e4c")
            Text("ui.3_create_a_card.1f2848").font(.headline)
            Text("ui.create_a_card_in_petal_or_press_option_command_n_to_add.40a490")
            if failed { Text("ui.unable_to_save_your_input_is_kept_retry_when_local_stor.5e7faf").foregroundStyle(.red) }
            Button("ui.get_started.983f31") {
                Task {
                    saving = true
                    defer { saving = false }
                    do { try await complete() } catch { failed = true }
                }
            }.keyboardShortcut(.defaultAction).disabled(saving).accessibilityIdentifier("onboarding.finish")
        }.padding(32).frame(width: 480).interactiveDismissDisabled()
    }
}
