import SwiftUI

/// Stand-in for the real `GhosttyKit`-rendered terminal (see
/// docs/04-cli-backends.md) until `GhosttyKit.xcframework` is buildable in this
/// environment (see docs/07-roadmap.md). Renders accumulated output as plain
/// scrollback text and forwards submitted input. `LoopNodeDetailFeature` is written
/// against this view's shape so swapping in a real GhosttyKit surface later shouldn't
/// require reducer changes — only this file.
struct PlaceholderTerminalView: View {
  let scrollback: String
  var onSubmitInput: (String) -> Void

  @State private var inputText = ""

  var body: some View {
    VStack(spacing: 0) {
      ScrollViewReader { proxy in
        ScrollView {
          Text(scrollback.isEmpty ? " " : scrollback)
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(.white)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .id("bottom")
        }
        .background(Color.black)
        .onChange(of: scrollback) {
          proxy.scrollTo("bottom", anchor: .bottom)
        }
      }
      Divider()
      HStack {
        TextField("Send input…", text: $inputText)
          .textFieldStyle(.plain)
          .font(.system(.body, design: .monospaced))
          .onSubmit {
            guard !inputText.isEmpty else { return }
            onSubmitInput(inputText + "\n")
            inputText = ""
          }
      }
      .padding(8)
    }
  }
}
