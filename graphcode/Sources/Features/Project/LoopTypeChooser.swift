import GraphcodeKit
import SwiftUI

/// The four kinds of loop, as tiles that explain themselves.
///
/// It was a four-segment picker, and the problem with that wasn't the shape — it was
/// that four segments can only *name* the types. A control that names four things reads
/// as a filter over a list; this one is the dialog's mode switch, and the rest of the
/// form changes completely with it. Naming them "Goal-based / Time-based / Turn-based /
/// Proactive" also asks the reader to already know the taxonomy the dialog exists to
/// teach.
///
/// Shared with onboarding page 3, which teaches the same four things and would otherwise
/// draw its own version of them.
struct LoopTypeChooser: View {
  @Binding var selection: LoopType
  /// Onboarding subtitles them by what makes each type *stop*; the dialog by what each
  /// one does. Same tiles, different lesson.
  var explanation: (LoopType) -> String = LoopTypeChooser.whatItDoes

  private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

  var body: some View {
    LazyVGrid(columns: columns, spacing: 8) {
      ForEach(LoopType.allCases, id: \.self) { type in
        tile(type)
      }
    }
  }

  private func tile(_ type: LoopType) -> some View {
    let isSelected = type == selection
    return VStack(alignment: .leading, spacing: 4) {
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
    .onTapGesture { selection = type }
  }

  /// What the type *does* — the dialog's reading.
  static func whatItDoes(_ type: LoopType) -> String {
    switch type {
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
    case .goalBased: "Stops when your check passes"
    case .timeBased: "Never — it runs again each interval"
    case .turnBased: "Stops after every turn, for you"
    case .composite: "Doesn't run until you arm it"
    }
  }
}
