import GraphcodeKit
import SwiftUI

/// A loop card at the size onboarding can afford: the canvas card's own anatomy — type
/// stripe, title, state pill, mono sub-line — at 196pt instead of 250.
///
/// It replaced a grey pill with a green dot. Nothing about that pill transferred to the
/// canvas: a person who learned it and then opened the app had to learn the card again
/// from scratch, which is the whole failure of teaching with an illustration that isn't
/// the thing.
struct OnboardingMiniCard: View {
  let title: String
  let type: LoopType
  let state: LoopState
  let subline: String
  /// The amber treatment, for the one card that is asking a question.
  var isAsking = false

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 6) {
        Text(title)
          .font(.system(size: 12.5, weight: .semibold))
          .foregroundStyle(.white.opacity(0.95))
          .lineLimit(1)
        Spacer(minLength: 4)
        LoopStatePill(state: state, loopType: type)
      }
      Text(subline)
        .font(.system(size: 10.5, design: isAsking ? .default : .monospaced))
        .foregroundStyle(.white.opacity(isAsking ? 0.72 : 0.55))
        .lineLimit(1)
    }
    .padding(.vertical, 9)
    .padding(.horizontal, 11)
    .frame(width: 196, alignment: .leading)
    .background(isAsking ? Theme.loopCardAttention : Theme.loopCard)
    .overlay(alignment: .leading) {
      UnevenRoundedRectangle(topLeadingRadius: 9, bottomLeadingRadius: 9)
        .fill(type.accent)
        .frame(width: 3)
    }
    .clipShape(RoundedRectangle(cornerRadius: 9))
    .overlay {
      RoundedRectangle(cornerRadius: 9)
        .stroke(
          isAsking ? Theme.loopCardAttentionBorder : Theme.loopCardBorder, lineWidth: 1)
    }
    .cardGlow(isAsking ? .orange : type.accent, emphasized: isAsking)
  }
}

/// Page 1 — three real cards, wired with directed edges, in mixed states.
///
/// The old page drew three greens, and a graph where everything is fine is a graph with
/// nothing happening. The point of the app is the third card.
struct OnboardingWelcomePage: View {
  @State private var edgeProgress: CGFloat = 0

  private let positions: [CGPoint] = [
    CGPoint(x: 118, y: 46), CGPoint(x: 350, y: 128), CGPoint(x: 140, y: 208),
  ]

  var body: some View {
    VStack(spacing: 18) {
      illustration
      Text("Agents you can watch")
        .font(.system(size: 25, weight: .bold))
        .tracking(-0.25)
      Text(
        "Every card is a real terminal session you can open and steer. They hand work "
          + "to each other along the edges — and tell you when they need you."
      )
      .font(.system(size: 14))
      .lineSpacing(4)
      .foregroundStyle(.white.opacity(0.65))
      .multilineTextAlignment(.center)
      .frame(maxWidth: 470)
    }
  }

  private var illustration: some View {
    ZStack {
      edge(from: positions[0], to: positions[1])
      edge(from: positions[1], to: positions[2])
      OnboardingMiniCard(
        title: "Watch crash reports", type: .timeBased, state: .running,
        subline: "/loop 1h · last run 14:02"
      )
      .position(positions[0])
      OnboardingMiniCard(
        title: "Fix the top crash", type: .goalBased, state: .running,
        subline: "pass 3 · 1.42 → 1.10"
      )
      .position(positions[1])
      OnboardingMiniCard(
        title: "Review the fix", type: .turnBased, state: .awaitingInput,
        subline: "“Ship this, or split it in two?”", isAsking: true
      )
      .position(positions[2])
    }
    .frame(width: 470, height: 260)
    .onAppear { withAnimation(.easeOut(duration: 0.9)) { edgeProgress = 1 } }
  }

  /// The same middle-to-middle curve and arrowhead the canvas draws, so the picture is
  /// of the app rather than of an idea about it.
  private func edge(from: CGPoint, to: CGPoint) -> some View {
    let card = CGSize(width: 196, height: 58)
    let start = CanvasEdgeGeometry.exit(from: from, toward: to, cardSize: card)
    let end = CanvasEdgeGeometry.entry(at: to, from: from, cardSize: card)
    let controls = CanvasEdgeGeometry.controls(from: start, to: end)
    return ZStack {
      Path { path in
        path.move(to: start)
        path.addCurve(to: end, control1: controls.0, control2: controls.1)
      }
      .trim(from: 0, to: edgeProgress)
      .stroke(.white.opacity(0.45), style: StrokeStyle(lineWidth: 1.5))
      Path { path in
        let corners = CanvasEdgeGeometry.arrowhead(
          at: end,
          from: CanvasEdgeGeometry.arrivalTangent(control: controls.1, end: end))
        guard let first = corners.first else { return }
        path.move(to: first)
        for corner in corners.dropFirst() { path.addLine(to: corner) }
        path.closeSubpath()
      }
      .fill(.white.opacity(0.45 * edgeProgress))
    }
  }
}

/// Page 2 — how to read a card.
///
/// New, and the page that earns its place: reading state is what someone does forty
/// times a day, and the old tour taught the taxonomy first and the state never.
struct OnboardingReadingPage: View {
  var body: some View {
    VStack(spacing: 16) {
      OnboardingMiniCard(
        title: "Fix the top crash", type: .goalBased, state: .running,
        subline: "pass 3 · 1.42 → 1.10"
      )
      .scaleEffect(300.0 / 196.0, anchor: .center)
      .frame(width: 300, height: 92)

      Text("How to read a loop")
        .font(.system(size: 25, weight: .bold))
        .tracking(-0.25)

      VStack(alignment: .leading, spacing: 7) {
        row("The pill", "What it's doing right now — running, done, blocked, or needs you")
        row("The line under it", "Where it's got to, in its own words")
        row("The bar", "Progress toward whatever you told it to aim for")
        row("The stripe", "Which kind of loop it is — next slide")
      }
      .frame(maxWidth: 460)

      Text("Amber always means one thing: it's waiting on you.")
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(Color(red: 1.0, green: 0.804, blue: 0.478))
        .padding(.vertical, 5)
        .padding(.horizontal, 10)
        .background(
          Color(red: 1.0, green: 0.624, blue: 0.039).opacity(0.12),
          in: Capsule()
        )
    }
  }

  private func row(_ label: String, _ description: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Text(label)
        .font(.system(size: 12.5, weight: .semibold))
        .foregroundStyle(.white.opacity(0.9))
        .frame(width: 128, alignment: .trailing)
      Text(description)
        .font(.system(size: 12.5))
        .foregroundStyle(.white.opacity(0.6))
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
  }
}

/// Page 3 — the four kinds, subtitled by what makes each one *stop*, with the edge
/// lesson folded in underneath. Sketch shows above them as what it is: not a fifth
/// kind, the place you start before the work has a shape.
///
/// Two pages became one, which is what freed the room for page 2. The tiles are the
/// dialog's own `LoopTypeChooser`, so what is taught here is literally what is chosen
/// there.
struct OnboardingLoopTypesPage: View {
  /// Nothing is being chosen on this page — the tiles are showing four things, not
  /// asking for one. The selection is fixed on the type most people meet first.
  @State private var shown: LoopType = .goalBased

  var body: some View {
    VStack(spacing: 16) {
      Text("Four kinds of loop")
        .font(.system(size: 25, weight: .bold))
        .tracking(-0.25)
      Text(
        "They differ in what makes them stop — and a sketch is where you start "
          + "before choosing one."
      )
      .font(.system(size: 14))
      .foregroundStyle(.white.opacity(0.65))

      LoopTypeChooser(selection: $shown, explanation: LoopTypeChooser.whatStopsIt)
        .frame(maxWidth: 440)

      Divider().overlay(Color.white.opacity(0.08)).frame(maxWidth: 440)

      HStack(spacing: 14) {
        OnboardingMiniCard(
          title: "Find bugs", type: .timeBased, state: .running, subline: "/loop 1h"
        )
        .scaleEffect(0.72, anchor: .trailing)
        Image(systemName: "arrow.right")
          .font(.system(size: 12))
          .foregroundStyle(.white.opacity(0.45))
        OnboardingMiniCard(
          title: "Fix them", type: .goalBased, state: .idle, subline: "waiting on the hand-off"
        )
        .scaleEffect(0.72, anchor: .leading)
      }
      .frame(height: 58)

      Text(
        "Wire them together by dragging from a card's + handle. Click + without dragging "
          + "to grow a new loop already connected to it."
      )
      .font(.system(size: 12.5))
      .foregroundStyle(.white.opacity(0.6))
      .multilineTextAlignment(.center)
      .frame(maxWidth: 440)
    }
  }
}

/// Page 4 — which agent runs them.
///
/// The capability badge is the addition: `canHost` already knows that Copilot and Codex
/// can't host a timed loop, and someone choosing a default should be told before their
/// first watcher refuses to be created rather than after.
struct OnboardingBackendPage: View {
  @Binding var selection: CLISessionBackendKind

  var body: some View {
    VStack(spacing: 14) {
      Text("Which agent runs them")
        .font(.system(size: 25, weight: .bold))
        .tracking(-0.25)
      Text("The default for new loops. Change it any time in Settings, or per loop.")
        .font(.system(size: 14))
        .foregroundStyle(.white.opacity(0.65))
        .multilineTextAlignment(.center)
        .frame(maxWidth: 470)

      VStack(spacing: 8) {
        ForEach(CLISessionBackendKind.allCases, id: \.self) { backend in
          row(backend)
        }
      }
      .frame(maxWidth: 440)

      // No PATH probing and no version strings: nothing in `BackendCapabilities` looks,
      // so claiming to have found something would be the tour making it up.
      Text(
        "The CLI must be installed and on your PATH — GraphCode launches it, it doesn't "
          + "bundle it."
      )
      .font(.system(size: 11))
      .foregroundStyle(.white.opacity(0.45))
      .multilineTextAlignment(.center)
      .frame(maxWidth: 440)
    }
  }

  private func row(_ backend: CLISessionBackendKind) -> some View {
    let isSelected = selection == backend
    return Button {
      selection = backend
    } label: {
      HStack(spacing: 13) {
        Text(">_")
          .font(.system(size: 13, weight: .medium, design: .monospaced))
          .foregroundStyle(.white.opacity(0.6))
          .frame(width: 30, height: 30)
          .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 7) {
            Text(backend.displayName).font(.system(size: 13, weight: .semibold))
            Self.capabilityBadge(backend)
          }
          Text(OnboardingBackendPage.blurb(backend))
            .font(.system(size: 11.5))
            .foregroundStyle(.white.opacity(0.55))
        }
        Spacer(minLength: 0)
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(isSelected ? Theme.paneFocusTint : .white.opacity(0.25))
      }
      .padding(.vertical, 13)
      .padding(.horizontal, 15)
      .background(
        isSelected ? Theme.paneFocusTint.opacity(0.1) : Color.white.opacity(0.03),
        in: RoundedRectangle(cornerRadius: 11)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 11)
          .stroke(
            isSelected ? Theme.paneFocusTint : .white.opacity(0.08),
            lineWidth: isSelected ? 1.5 : 1)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  /// Straight off `canHost` — the same rule that refuses the pairing in the new-loop
  /// dialog, said here before anyone runs into it. Derived rather than written out, so
  /// it can't come to claim something the capability table disagrees with.
  @ViewBuilder
  static func capabilityBadge(_ backend: CLISessionBackendKind) -> some View {
    let missing = LoopType.allCases.filter { !backend.canHost($0) }
    let hostsEverything = missing.isEmpty
    Text(
      hostsEverything
        ? "HOSTS EVERY LOOP KIND"
        : "NOT FOR \(missing.map { $0.displayName.uppercased() }.joined(separator: " / ")) LOOPS"
    )
    .font(.system(size: 9, weight: .bold))
    .tracking(0.4)
    .foregroundStyle(hostsEverything ? Self.hostsInk : Self.limitedInk)
    .padding(.vertical, 1)
    .padding(.horizontal, 5)
    .background(
      (hostsEverything ? Self.hostsInk : Self.limitedInk).opacity(0.14),
      in: RoundedRectangle(cornerRadius: 4)
    )
  }

  static func blurb(_ backend: CLISessionBackendKind) -> String {
    switch backend {
    case .claudeCode: return "Anthropic's agent — the reference backend, fully wired."
    case .copilotCLI: return "GitHub's agent CLI."
    case .codex: return "OpenAI's agent CLI."
    case .openCode: return "The open-source agent CLI — any model provider."
    }
  }

  private static let hostsInk = Color(red: 0.494, green: 0.894, blue: 0.608)
  private static let limitedInk = Color(red: 1.0, green: 0.804, blue: 0.478)
}

/// Page 4 — one window per line of work.
///
/// Placed before the agent page rather than after it, so the tour still ends on the one
/// choice that configures something.
///
/// The closing line is the page's real content. On day one a fresh install has no
/// crowding problem, and a tour that pushes a second workspace at someone with zero loops
/// has taught them to make a mess — so this page says when a workspace is worth having
/// and explicitly says "not yet".
struct OnboardingWorkspacesPage: View {
  var body: some View {
    VStack(spacing: 14) {
      Text("One window per line of work")
        .font(.system(size: 25, weight: .bold))
        .tracking(-0.25)
      Text(
        "A workspace has its own projects, loops and daemon. Start one when a second "
          + "kind of work would otherwise crowd the first."
      )
      .font(.system(size: 14))
      .foregroundStyle(.white.opacity(0.65))
      .multilineTextAlignment(.center)
      .frame(maxWidth: 470)

      HStack(spacing: 14) {
        miniWindow(name: "Default", tint: Theme.paneFocusTint, widths: [1, 0.76, 0.88, 0.6])
        divider
        miniWindow(
          name: "Client Work", tint: Color(red: 0.847, green: 0.651, blue: 0.341),
          widths: [0.82, 1, 0.54])
      }
      .padding(.top, 8)

      VStack(alignment: .leading, spacing: 7) {
        fact("Separate", "projects, loops, terminal layouts, agent default")
        fact("Shared", "the app itself, and nothing else")
        fact("Make one", "File ▸ Workspace ▸ New Workspace…   ⌥⌘N")
      }
      .frame(width: 440, alignment: .leading)
      .padding(.top, 12)

      Text("You do not need one yet — one workspace is the right number until it isn't.")
        .font(.system(size: 11))
        .foregroundStyle(.white.opacity(0.4))
        .multilineTextAlignment(.center)
        .frame(maxWidth: 440)
    }
  }

  private var divider: some View {
    VStack(spacing: 4) {
      ZStack {
        Rectangle()
          .fill(.white.opacity(0.18))
          .frame(width: 52, height: 1)
        Image(systemName: "xmark")
          .font(.system(size: 9, weight: .medium))
          .foregroundStyle(.white.opacity(0.28))
          .padding(3)
          .background(Theme.windowTone, in: Circle())
      }
      Text("nothing\ncrosses")
        .font(.system(size: 9.5))
        .foregroundStyle(.white.opacity(0.38))
        .multilineTextAlignment(.center)
    }
    .frame(width: 74)
  }

  /// Not a screenshot and not to scale — two windows, each with its own loops, and the
  /// gap between them is the whole point.
  private func miniWindow(name: String, tint: Color, widths: [CGFloat]) -> some View {
    VStack(spacing: 0) {
      HStack(spacing: 6) {
        Circle().fill(tint).frame(width: 6, height: 6)
        Text(name).font(.system(size: 9)).foregroundStyle(.white.opacity(0.7))
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 7)
      .frame(height: 18)
      .background(.white.opacity(0.05))

      Divider().overlay(.white.opacity(0.08))

      VStack(alignment: .leading, spacing: 5) {
        ForEach(Array(widths.enumerated()), id: \.offset) { index, width in
          RoundedRectangle(cornerRadius: 2)
            .fill(OnboardingWorkspacesPage.loopTint(index))
            .frame(width: 154 * width, height: 4)
        }
      }
      .padding(9)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(width: 172)
    .background(Color(white: 0.137), in: RoundedRectangle(cornerRadius: 7))
    .overlay {
      RoundedRectangle(cornerRadius: 7).stroke(.white.opacity(0.12), lineWidth: 1)
    }
  }

  private func fact(_ label: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 9) {
      Text(label)
        .font(.system(size: 11))
        .foregroundStyle(.white.opacity(0.45))
        .frame(width: 96, alignment: .trailing)
      Text(value)
        .font(.system(size: 11.5))
        .foregroundStyle(.white.opacity(0.7))
    }
  }

  /// A couple of the bars carry a loop-state colour so the windows read as holding work
  /// rather than as empty frames.
  static func loopTint(_ index: Int) -> Color {
    switch index {
    case 0: return Color(red: 0.494, green: 0.894, blue: 0.608).opacity(0.55)
    case 2: return Color(red: 1.0, green: 0.804, blue: 0.478).opacity(0.5)
    default: return .white.opacity(0.16)
    }
  }
}
