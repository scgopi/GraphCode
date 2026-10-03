import SwiftUI

/// The chat pane's palette, read off the design (`nod_designs/GraphCode Nod.dc.html`):
/// plain GraphCode chrome, action blue for actions, orange for "needs you", and muted text
/// no dimmer than 55% white (review round 2).
enum NodStyle {
  /// The graph canvas's own tone, so moving between the canvas and a Nod chat keeps one ground.
  static let paneBackground = Theme.canvasBackground
  static let cardBackground = Color(red: 0.098, green: 0.098, blue: 0.110)  // #19191c
  static let composerBackground = Color(red: 0.149, green: 0.149, blue: 0.165)  // #26262a
  static let bubble = Color.white.opacity(0.07)
  static let hairline = Color.white.opacity(0.10)

  static let ink = Color.white.opacity(0.92)
  static let body = Color.white.opacity(0.86)
  static let secondary = Color.white.opacity(0.75)
  static let muted = Color.white.opacity(0.55)

  static let action = Color(red: 0.039, green: 0.518, blue: 1.0)  // #0a84ff
  static let actionInk = Color(red: 0.475, green: 0.737, blue: 1.0)  // #79bcff
  static let attention = Color(red: 1.0, green: 0.624, blue: 0.039)  // #ff9f0a
  static let attentionInk = Color(red: 1.0, green: 0.745, blue: 0.361)  // #ffbe5c
  static let met = Color(red: 0.188, green: 0.820, blue: 0.345)  // #30d158
  static let failed = Color(red: 1.0, green: 0.412, blue: 0.380)  // #ff6961
  static let added = Color(red: 0.651, green: 0.941, blue: 0.722)  // #a6f0b8
  static let removed = Color(red: 1.0, green: 0.702, blue: 0.682)  // #ffb3ae

  static let columnWidth: CGFloat = 680
  static let mono = Font.system(size: 11.5, design: .monospaced)
}

/// The design's three button weights: filled blue for the one thing to do, a quiet
/// outlined one beside it, and bare text for the way out.
struct NodButtonStyle: ButtonStyle {
  enum Weight { case primary, secondary, plain }
  var weight: Weight = .secondary

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 11.5, weight: weight == .primary ? .semibold : .regular))
      .foregroundStyle(foreground)
      .padding(.horizontal, 10)
      .frame(height: 24)
      .background(
        RoundedRectangle(cornerRadius: 6)
          .fill(background.opacity(configuration.isPressed ? 0.7 : 1))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 6)
          .stroke(weight == .secondary ? Color.white.opacity(0.12) : .clear, lineWidth: 1)
      )
      .contentShape(Rectangle())
  }

  private var foreground: Color {
    switch weight {
    case .primary: return .white
    case .secondary: return Color.white.opacity(0.85)
    case .plain: return Color.white.opacity(0.6)
    }
  }

  private var background: Color {
    switch weight {
    case .primary: return NodStyle.action
    case .secondary: return Color.white.opacity(0.06)
    case .plain: return .clear
    }
  }
}

/// A link-weight action in blue ink, as the goal check's "Mark done anyway".
struct NodLinkButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 11.5))
      .foregroundStyle(NodStyle.actionInk.opacity(configuration.isPressed ? 0.6 : 1))
      .contentShape(Rectangle())
  }
}

/// The small rounded chips under the composer and on attachments.
struct NodChip<Label: View>: View {
  @ViewBuilder var label: Label

  var body: some View {
    label
      .font(.system(size: 11))
      .foregroundStyle(NodStyle.muted)
      .padding(.horizontal, 7)
      .padding(.vertical, 2)
      .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.06)))
  }
}
