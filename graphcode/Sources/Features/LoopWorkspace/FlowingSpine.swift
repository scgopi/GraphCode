import SwiftUI

/// The 1pt spine behind the receding beats, with a gradient segment travelling *up* it.
///
/// **Why an animation exists here at all.** `StateIndicator` documents why the running
/// dot's pulse was removed: a `repeatForever` animation never settles, and that one was
/// attached to every card and every sidebar row, so the app could not reach an idle frame
/// while any loop ran. This is the opposite case on every count that mattered there. There
/// is exactly **one** of these in a window — the workspace shows one loop — it is drawn
/// only when the rail is open and unfolded, and `isFlowing` stops it the moment the
/// session is not busy or there is nothing behind the current beat. A canvas of forty
/// cards animates nothing.
///
/// It earns its place by saying the one thing no static rail can: that beats are still
/// arriving. A spinner says "something is happening"; this says "the thing you are reading
/// is moving", which is what a rail of receding text is for.
struct FlowingSpine: View {
  let isFlowing: Bool

  @State private var phase: CGFloat = 0

  var body: some View {
    GeometryReader { proxy in
      let height = proxy.size.height
      Rectangle()
        .fill(.white.opacity(0.1))
        .overlay(alignment: .top) {
          if isFlowing {
            RoundedRectangle(cornerRadius: 1)
              .fill(
                LinearGradient(
                  colors: [
                    Theme.paneFocusTint.opacity(0), Theme.paneFocusTint,
                    Theme.paneFocusTint.opacity(0),
                  ],
                  startPoint: .top, endPoint: .bottom)
              )
              .frame(width: 2, height: 26)
              .offset(x: -0.5, y: (height + 26) * (1 - phase) - 26)
              .onAppear {
                phase = 0
                withAnimation(.linear(duration: 2.6).repeatForever(autoreverses: false)) {
                  phase = 1
                }
              }
          }
        }
        .clipped()
    }
  }
}
