import SwiftUI

/// One sidebar row's leading symbol, at the one size and weight every row uses.
///
/// Modelled on Photos', Finder's and Mail's sidebars, which all do the same three things
/// and are legible because of it:
///
/// - **Outline symbols, not filled.** A filled glyph at sidebar size is a solid blob whose
///   silhouette carries all the meaning; the outline keeps its interior detail, which is
///   what you actually recognise a folder or a clock by.
/// - **A point size of its own, larger than the label's.** Left to inherit, a symbol comes
///   out at the text's cap height and reads as punctuation next to the words. Apple's
///   sidebars run the symbol a couple of points above the label.
/// - **A fixed-width column.** Symbols have wildly different natural widths — `clock` is
///   square, `point.3.connected.trianglepath.dotted` is wide — so laying rows out on the
///   symbols' own widths leaves the *labels* ragged, which is the thing that actually
///   makes a sidebar look untidy.
///
/// Tint is per-row rather than fixed: most rows want ordinary label ink, but a loop's kind
/// and the Graph both carry colour that is real information (see `LoopType.accent`).
struct SidebarIcon: View {
  let systemName: String
  var tint: Color = .primary

  /// A little above the 13pt sidebar label, matching Apple's own sidebars.
  static let pointSize: CGFloat = 15

  /// Wide enough for the broadest symbol used here, so every label starts at the same x.
  static let columnWidth: CGFloat = 20

  var body: some View {
    Image(systemName: systemName)
      .font(.system(size: Self.pointSize, weight: .regular))
      // Multicolour would let a symbol bring its own palette into a sidebar whose colours
      // all mean something — the tint is the only colour a row is allowed.
      .symbolRenderingMode(.monochrome)
      .foregroundStyle(tint)
      .frame(width: Self.columnWidth)
  }
}

#Preview {
  VStack(alignment: .leading, spacing: 8) {
    HStack(spacing: 6) {
      SidebarIcon(systemName: "folder")
      Text("graphcode")
    }
    HStack(spacing: 6) {
      SidebarIcon(systemName: "point.3.connected.trianglepath.dotted", tint: .accentColor)
      Text("Graph")
    }
    HStack(spacing: 6) {
      SidebarIcon(systemName: "clock", tint: .orange)
      Text("Nightly sweep")
    }
  }
  .padding()
  .frame(width: 220)
}
