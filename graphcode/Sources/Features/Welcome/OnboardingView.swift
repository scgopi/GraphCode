import GraphcodeKit
import SwiftUI

/// The first-launch tour — four pages, each one idea with a drawn illustration, ending
/// on a choice that actually configures the app (the default CLI backend). Skippable at
/// every step, and reopenable from the sidebar's ? button.
///
/// The shell here is unchanged and was already right: 560×620, Skip, the dots, and the
/// backend applying live through `SettingsModel.shared`. What changed is the pages —
/// see `OnboardingPages.swift`. The old ones taught the taxonomy first and drew grey
/// pills with green dots, so nothing a reader learned transferred to the canvas, and an
/// all-green graph is a graph with nothing happening.
///
/// Every illustration is drawn in SwiftUI from the app's own card, pill and edge views —
/// no image assets to maintain, and the pictures can't drift from what the canvas
/// actually looks like, because they *are* it.
struct OnboardingView: View {
  let onDismiss: () -> Void

  @State private var page = 0
  @State private var selectedBackend = SettingsModel.shared.settings.defaultBackend
  /// Four, and the count is checked: the edge lesson folded into the types page to make
  /// room for "How to read a loop", and a page silently lost in that merge would be a
  /// tour that stops teaching something without anyone noticing.
  static let pageCount = 4

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Spacer()
        Button("Skip") { onDismiss() }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
      }
      .padding([.top, .horizontal], 16)

      Group {
        switch page {
        // State before taxonomy: reading a card is what someone does forty times a
        // day, and the tour used to teach the four types first and the pill never.
        case 0: OnboardingWelcomePage()
        case 1: OnboardingReadingPage()
        case 2: OnboardingLoopTypesPage()
        default: OnboardingBackendPage(selection: $selectedBackend)
        }
      }
      // Applied the moment a card is tapped, through the live model — the same
      // no-Save-button rule the Settings window follows. Writing the store directly on
      // "Get Started" bypassed `SettingsModel.shared`, which the Settings pane binds
      // to and which already existed at launch: "New loops use" kept showing the old
      // backend, and the pane's next save quietly reverted the onboarding choice.
      .onChange(of: selectedBackend) { _, backend in
        SettingsModel.shared.settings.defaultBackend = backend
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(.horizontal, 32)

      HStack(spacing: 12) {
        if page > 0 {
          Button("Back") { withAnimation(.easeInOut(duration: 0.2)) { page -= 1 } }
        }
        Spacer()
        HStack(spacing: 6) {
          ForEach(0..<Self.pageCount, id: \.self) { index in
            Circle()
              .fill(index == page ? Color.accentColor : Color.secondary.opacity(0.3))
              .frame(width: 7, height: 7)
          }
        }
        Spacer()
        if page < Self.pageCount - 1 {
          Button("Continue") { withAnimation(.easeInOut(duration: 0.2)) { page += 1 } }
            .keyboardShortcut(.defaultAction)
        } else {
          Button("Get Started") {
            // Nothing to save here — the backend choice was applied when it was made.
            onDismiss()
          }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
        }
      }
      .padding(20)
    }
    .frame(width: 560, height: 620)
  }
}

#Preview {
  OnboardingView(onDismiss: {})
}
