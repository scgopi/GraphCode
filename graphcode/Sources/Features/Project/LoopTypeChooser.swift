import GraphcodeKit
import SwiftUI

/// The five kinds of loop, as tiles that explain themselves.
///
/// It was a four-segment picker, and the problem with that wasn't the shape — it was
/// that four segments can only *name* the types. A control that names four things reads
/// as a filter over a list; this one is the dialog's mode switch, and the rest of the
/// form changes completely with it. Naming them "Goal-based / Time-based / Turn-based /
/// Proactive" also asks the reader to already know the taxonomy the dialog exists to
/// teach.
///
/// The axis the chooser is ordered on is how much you have to decide before the loop
/// can start. Sketch demands nothing, so it sits above the grid as a full-width band —
/// deliberately not a fifth tile: an orphan tile in a 2×2 rhythm reads as an
/// afterthought, and a five-wide row shrinks every explanation to one truncated line.
/// The labelled rule between them ("or commit to something") is the taxonomy lesson.
///
/// Shared with onboarding page 3, which teaches the same five things and would otherwise
/// draw its own version of them.
struct LoopTypeChooser: View {
  @Binding var selection: LoopType
  /// Onboarding subtitles them by what makes each type *stop*; the dialog by what each
  /// one does. Same tiles, different lesson.
  var explanation: (LoopType) -> String = LoopTypeChooser.whatItDoes

  private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

  /// ⌘1 Sketch · ⌘2 Goal · ⌘3 Timed · ⌘4 Turn · ⌘5 Composite — `allCases` order, which
  /// the enum keeps in chooser order on purpose.
  private static let shortcuts = Dictionary(
    uniqueKeysWithValues: LoopType.allCases.enumerated().map { ($1, "\($0 + 1)") })

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      sketchBand
      committedRule
      LazyVGrid(columns: columns, spacing: 8) {
        ForEach(LoopType.allCases.filter { $0 != .sketch }, id: \.self) { type in
          tile(type)
        }
      }
    }
  }

  private var sketchBand: some View {
    let isSelected = selection == .sketch
    return Button {
      selection = .sketch
    } label: {
      HStack(spacing: 10) {
        RoundedRectangle(cornerRadius: 3)
          .fill(LoopType.sketch.accent)
          .frame(width: 10, height: 10)
        Text(LoopType.sketch.displayName)
          .font(.system(size: 12.5, weight: .semibold))
          .foregroundStyle(.white.opacity(isSelected ? 0.95 : 0.8))
        Text(explanation(.sketch))
          .font(.system(size: 11))
          .foregroundStyle(.white.opacity(0.6))
          .lineLimit(1)
        Spacer(minLength: 8)
        Text("⌘1")
          .font(.system(size: 10.5, design: .monospaced))
          .foregroundStyle(.white.opacity(0.4))
      }
      .padding(.vertical, 11)
      .padding(.horizontal, 12)
      .background(
        isSelected ? LoopType.sketch.accent.opacity(0.16) : Color.white.opacity(0.035),
        in: RoundedRectangle(cornerRadius: 9)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 9)
          .stroke(
            isSelected ? LoopType.sketch.accent.opacity(0.72) : Color.white.opacity(0.08),
            lineWidth: 1)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .keyboardShortcut("1", modifiers: .command)
  }

  private var committedRule: some View {
    HStack(spacing: 8) {
      Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
      Text("OR COMMIT TO SOMETHING")
        .font(.system(size: 10.5, weight: .bold))
        .kerning(0.7)
        .foregroundStyle(.white.opacity(0.4))
        .fixedSize()
      Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
    }
  }

  private func tile(_ type: LoopType) -> some View {
    let isSelected = type == selection
    return Button {
      selection = type
    } label: {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 7) {
          RoundedRectangle(cornerRadius: 2.5)
            .fill(type.accent)
            .frame(width: 8, height: 8)
          Text(type.displayName)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.white.opacity(isSelected ? 0.95 : 0.8))
        }
        Text(explanation(type))
          .font(.system(size: 11))
          .foregroundStyle(.white.opacity(isSelected ? 0.55 : 0.58))
          .fixedSize(horizontal: false, vertical: true)
          .multilineTextAlignment(.leading)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 9)
      .padding(.horizontal, 10)
      .background(
        isSelected ? type.accent.opacity(0.12) : Color.white.opacity(0.035),
        in: RoundedRectangle(cornerRadius: 9)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 9)
          .stroke(
            isSelected ? type.accent.opacity(0.6) : Color.white.opacity(0.08), lineWidth: 1)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .modifier(TypeShortcut(key: Self.shortcuts[type]))
  }

  /// What the type *does* — the dialog's reading.
  static func whatItDoes(_ type: LoopType) -> String {
    switch type {
    case .sketch: "Just start. No goal, no schedule, nothing to fill in."
    case .goalBased: "Works until a condition is met"
    case .timeBased: "Runs again on a schedule"
    case .turnBased: "Pauses for you each turn"
    case .composite: "A group of loops, armed later"
    }
  }

  /// What makes it *stop* — onboarding's reading, because "when does this end" is the
  /// question a person actually has about an agent that runs on its own.
  static func whatStopsIt(_ type: LoopType) -> String {
    switch type {
    case .sketch: "Never on its own — you close it when you're done"
    case .goalBased: "Stops when your check passes"
    case .timeBased: "Never — it runs again each interval"
    case .turnBased: "Stops after every turn, for you"
    case .composite: "Doesn't run until you arm it"
    }
  }
}

/// A ⌘-digit shortcut when the type has one; `keyboardShortcut` has no conditional
/// form, so absence needs a modifier rather than an optional argument.
private struct TypeShortcut: ViewModifier {
  let key: String?

  func body(content: Content) -> some View {
    if let key, let character = key.first {
      content.keyboardShortcut(KeyEquivalent(character), modifiers: .command)
    } else {
      content
    }
  }
}
