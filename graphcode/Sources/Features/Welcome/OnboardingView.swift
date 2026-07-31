import GraphcodeKit
import SwiftUI

/// The first-launch tour — four pages, each one idea with a drawn illustration, ending
/// on a choice that actually configures the app (the default CLI backend). Paged with
/// dots and a Continue button rather than the scrolled glossary this used to be:
/// showing a tiny animated graph teaches "loops, connected" faster than six rows of
/// text defined it. Skippable at every step, and reopenable from the sidebar's ? button.
///
/// Every illustration is drawn in SwiftUI with the app's real theme and loop-type
/// accent colours — no image assets to maintain, and the pictures can't drift from
/// what the canvas actually looks like.
struct OnboardingView: View {
  let onDismiss: () -> Void

  @State private var page = 0
  @State private var selectedBackend = GraphcodeSettingsStore.load().defaultBackend
  private static let pageCount = 4

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
        case 0: OnboardingWelcomePage()
        case 1: OnboardingLoopTypesPage()
        case 2: OnboardingConnectPage()
        default: OnboardingBackendPage(selection: $selectedBackend)
        }
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
            // The backend choice lands in the same settings file the node form and
            // the daemon read — see `GraphcodeSettingsStore`.
            var settings = GraphcodeSettingsStore.load()
            settings.defaultBackend = selectedBackend
            GraphcodeSettingsStore.save(settings)
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

// MARK: - Page 1: the idea

private struct OnboardingWelcomePage: View {
  var body: some View {
    VStack(spacing: 20) {
      OnboardingMiniGraph()
        .frame(height: 240)
      Text("Welcome to GraphCode").font(.title).bold()
      Text(
        "Graphs of live AI coding sessions. Each card is a loop — an agent working in a "
          + "real terminal you can open, watch, and steer. Edges hand work from one loop "
          + "to the next."
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .frame(maxWidth: 400)
    }
  }
}

/// Three mini loop cards wired start → work → review, the edges drawing themselves in
/// and a pulse riding the first hand-off forever after. The shapes and stripe colours
/// are the canvas's own.
private struct OnboardingMiniGraph: View {
  @State private var edgeProgress: CGFloat = 0
  @State private var pulseProgress: CGFloat = 0

  private let positions: [CGPoint] = [
    CGPoint(x: 90, y: 60), CGPoint(x: 280, y: 120), CGPoint(x: 420, y: 190),
  ]

  var body: some View {
    ZStack {
      edge(from: positions[0], to: positions[1])
      edge(from: positions[1], to: positions[2])
      pulse(from: positions[0], to: positions[1])
      OnboardingMiniCard(title: "Watch issues", type: .timeBased)
        .position(positions[0])
      OnboardingMiniCard(title: "Fix the build", type: .goalBased)
        .position(positions[1])
      OnboardingMiniCard(title: "Review each turn", type: .turnBased)
        .position(positions[2])
    }
    .frame(width: 500)
    .onAppear {
      withAnimation(.easeOut(duration: 1.0)) { edgeProgress = 1 }
      withAnimation(.linear(duration: 2.2).repeatForever(autoreverses: false).delay(1.0)) {
        pulseProgress = 1
      }
    }
  }

  private func edge(from: CGPoint, to: CGPoint) -> some View {
    Path { path in
      path.move(to: from)
      path.addLine(to: to)
    }
    .trim(from: 0, to: edgeProgress)
    .stroke(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1.5))
  }

  private func pulse(from: CGPoint, to: CGPoint) -> some View {
    Circle()
      .fill(Color.accentColor)
      .frame(width: 7, height: 7)
      .position(
        x: from.x + (to.x - from.x) * pulseProgress,
        y: from.y + (to.y - from.y) * pulseProgress
      )
      .opacity(pulseProgress == 0 ? 0 : 1.2 - pulseProgress)
  }
}

/// A node card at postage-stamp size: material fill, the type's accent stripe on the
/// leading edge, and its glyph — the canvas card's silhouette, small enough to teach with.
private struct OnboardingMiniCard: View {
  let title: String
  let type: LoopType

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: type.glyph)
        .font(.caption)
        .foregroundStyle(type.accent)
      Text(title).font(.caption).lineLimit(1)
      Circle().fill(Color.green).frame(width: 5, height: 5)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    .overlay(alignment: .leading) {
      UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8)
        .fill(type.accent)
        .frame(width: 3)
    }
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3), lineWidth: 1)
    )
  }
}

// MARK: - Page 2: loop types

private struct OnboardingLoopTypesPage: View {
  @State private var appeared = false

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Four kinds of loop").font(.title2).bold()
        .frame(maxWidth: .infinity, alignment: .center)
      Text("They differ in what you hand off.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .center)

      typeRow(
        .goalBased, "Goal-based",
        "You hand off the stop condition — runs until the goal is met.", 0)
      typeRow(
        .timeBased, "Time-based",
        "You hand off the trigger — repeats on a cadence in its own prompt. Watchers live here.",
        1)
      typeRow(
        .turnBased, "Turn-based",
        "You hand off the check — pauses after each turn for your review.", 2)
      typeRow(
        .proactive, "Proactive",
        "You hand off the prompt — a group of loops run as one.", 3)
    }
  }

  private func typeRow(
    _ type: LoopType, _ name: String, _ explanation: String, _ index: Int
  ) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: type.glyph)
        .font(.body)
        .foregroundStyle(type.accent)
        .frame(width: 26, height: 26)
        .background(type.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
      VStack(alignment: .leading, spacing: 2) {
        Text(name).font(.headline)
        Text(explanation).font(.callout).foregroundStyle(.secondary)
      }
    }
    .opacity(appeared ? 1 : 0)
    .offset(y: appeared ? 0 : 8)
    .animation(.easeOut(duration: 0.35).delay(Double(index) * 0.08), value: appeared)
    .onAppear { appeared = true }
  }
}

// MARK: - Page 3: edges

private struct OnboardingConnectPage: View {
  @State private var drawn: CGFloat = 0

  var body: some View {
    VStack(spacing: 24) {
      ZStack {
        Path { path in
          path.move(to: CGPoint(x: 120, y: 70))
          path.addLine(to: CGPoint(x: 340, y: 70))
        }
        .trim(from: 0, to: drawn)
        .stroke(
          Color.accentColor,
          style: StrokeStyle(lineWidth: 2, dash: [5]))
        OnboardingMiniCard(title: "Find bugs", type: .timeBased)
          .position(x: 90, y: 70)
        OnboardingMiniCard(title: "Fix them", type: .goalBased)
          .position(x: 390, y: 70)
      }
      .frame(width: 480, height: 140)

      Text("Connect loops by dragging").font(.title2).bold()
      Text(
        "Drag from a card's + handle to another loop. An edge is a hand-off by default — "
          + "it fires when the source finishes — or a message, or a spawn. Click + "
          + "without dragging to grow a new, already-connected loop."
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .frame(maxWidth: 420)
    }
    .onAppear {
      withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { drawn = 1 }
    }
  }
}

// MARK: - Page 4: pick a backend

private struct OnboardingBackendPage: View {
  @Binding var selection: CLISessionBackendKind

  var body: some View {
    VStack(spacing: 16) {
      Text("Choose your CLI").font(.title2).bold()
      Text("The agent new loops run by default. Change it anytime in Settings, or per loop.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)

      ForEach(CLISessionBackendKind.allCases, id: \.self) { backend in
        backendCard(backend)
      }

      Text("The CLI must be installed and on your PATH — GraphCode launches it, it doesn't bundle it.")
        .font(.caption)
        .foregroundStyle(.tertiary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: 400)
  }

  private func backendCard(_ backend: CLISessionBackendKind) -> some View {
    Button {
      selection = backend
    } label: {
      HStack(spacing: 12) {
        Image(systemName: "terminal")
          .font(.body)
          .foregroundStyle(selection == backend ? Color.accentColor : Color.secondary)
        VStack(alignment: .leading, spacing: 1) {
          Text(backend.displayName).font(.headline)
          Text(blurb(backend)).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Image(systemName: selection == backend ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(selection == backend ? Color.accentColor : Color.secondary.opacity(0.5))
      }
      .padding(12)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
      .overlay(
        RoundedRectangle(cornerRadius: 10)
          .stroke(
            selection == backend ? Color.accentColor : Color.secondary.opacity(0.25),
            lineWidth: selection == backend ? 2 : 1)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func blurb(_ backend: CLISessionBackendKind) -> String {
    switch backend {
    case .claudeCode: return "Anthropic's agent — the reference backend, fully wired."
    case .copilotCLI: return "GitHub's agent CLI."
    case .codex: return "OpenAI's agent CLI."
    }
  }
}

#Preview {
  OnboardingView(onDismiss: {})
}
