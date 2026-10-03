import AppKit
import ComposableArchitecture
import SwiftUI
import Testing

@testable import graphcode

@MainActor
@Suite
struct NodComposerHeightTests {
  private let line = NodComposerTextView.lineHeight

  @Test
  func theBoxGrowsLineByLineUpToFiveThenStops() {
    #expect(NodComposerTextView.height(forUsedHeight: 0, lineHeight: line) == line)
    #expect(NodComposerTextView.height(forUsedHeight: line * 3, lineHeight: line) == line * 3)
    #expect(NodComposerTextView.height(forUsedHeight: line * 12, lineHeight: line) == line * 5)
  }

  /// The draft lives in SwiftUI state, as it does in the pane, so typing goes the live
  /// path: text view → binding → re-measure.
  private struct Harness: View {
    @State var draft = ""
    var body: some View {
      NodComposerTextView(
        text: $draft, placeholder: "", onReturn: {}, onSteer: {}, onEscape: {},
        onTab: { false }
      )
      .frame(width: 320)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func type(_ text: String) throws -> (box: NSScrollView, text: NSTextView) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 400), styleMask: [.titled],
      backing: .buffered, defer: false)
    let host = NSHostingView(rootView: Harness())
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    let box = try #require(Self.scrollView(in: host))
    let textView = try #require(box.documentView as? NSTextView)
    window.makeFirstResponder(textView)
    for character in text {
      textView.insertText(String(character), replacementRange: textView.selectedRange())
      RunLoop.main.run(until: Date().addingTimeInterval(0.005))
      host.layoutSubtreeIfNeeded()
    }
    return (box, textView)
  }

  /// The pane's own composer, its draft in the chat store, typed into a key at a time —
  /// with ⇧⏎ for a new line, the way a person writes a second line.
  private func typeIntoComposer(_ lines: [String]) throws -> (box: NSScrollView, text: NSTextView) {
    let store = Store(
      initialState: NodChatFeature.State(
        nodeID: UUID(), stateDirectory: URL(fileURLWithPath: "/tmp/nod-composer"),
        loopTitle: "Composer", loopType: .sketch, goal: nil)
    ) { NodChatFeature() }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 520, height: 500), styleMask: [.titled],
      backing: .buffered, defer: false)
    let host = NSHostingView(rootView: NodComposerView(store: store).frame(width: 480))
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    let box = try #require(Self.scrollView(in: host))
    let textView = try #require(box.documentView as? NSTextView)
    window.makeFirstResponder(textView)
    for (index, line) in lines.enumerated() {
      if index > 0 {
        textView.insertText("\n", replacementRange: textView.selectedRange())
        settle(host)
      }
      for character in line {
        textView.insertText(String(character), replacementRange: textView.selectedRange())
        settle(host)
      }
    }
    return (box, textView)
  }

  private func settle(_ host: NSView) {
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    host.layoutSubtreeIfNeeded()
  }

  /// The live failure: the box had been scrolled while the text outgrew it, and the offset
  /// survived the resize. A box whose text fits shows it from the top.
  @Test
  func aBoxWhoseTextFitsIsNeverLeftScrolled() throws {
    let (box, _) = try type("first\nsecond")
    box.contentView.scroll(to: NSPoint(x: 0, y: line))
    box.needsLayout = true
    box.layoutSubtreeIfNeeded()

    #expect(visible(box).minY <= 0.5)
  }

  @Test
  func theSecondLineTypedIntoThePanesComposerIsOnScreen() throws {
    let (box, text) = try typeIntoComposer(["what does", "this do"])

    #expect(text.string == "what does\nthis do")
    #expect(abs(box.frame.height - line * 2) < 2)
    #expect(visible(box).height >= line * 2 - 1)
    #expect(visible(box).minY <= 0.5)
  }

  /// The visible part of the text view, in its own coordinates.
  private func visible(_ box: NSScrollView) -> NSRect { box.contentView.documentVisibleRect }

  private static func scrollView(in view: NSView) -> NSScrollView? {
    if let scroll = view as? NSScrollView { return scroll }
    return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
  }

  /// The bug: the box grew, but the text view inside stayed one line tall, so the second
  /// line of a draft was never on screen.
  @Test
  func everyLineOfAShortDraftIsVisible() throws {
    let (box, text) = try type("first\nsecond\nthird")

    #expect(abs(box.frame.height - line * 3) < 2)
    #expect(text.frame.height >= line * 3 - 1)
    #expect(visible(box).height >= line * 3 - 1)
  }

  /// Narrowing the pane after typing left the box one line tall while the draft wrapped
  /// to four: only its last line showed, cut off from the rest.
  @Test(arguments: [(520, 360), (760, 360)])
  func aDraftStillFitsAfterThePaneNarrows(from: CGFloat, to: CGFloat) throws {
    let store = Store(
      initialState: NodChatFeature.State(
        nodeID: UUID(), stateDirectory: URL(fileURLWithPath: "/tmp/nod-composer"),
        loopTitle: "Composer", loopType: .sketch, goal: nil)
    ) { NodChatFeature() }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: from, height: 300), styleMask: [.titled],
      backing: .buffered, defer: false)
    let host = NSHostingView(rootView: AnyView(NodComposerView(store: store).frame(width: from)))
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    let box = try #require(Self.scrollView(in: host))
    let textView = try #require(box.documentView as? NSTextView)
    window.makeFirstResponder(textView)
    let draft =
      "Explain why the goal loop keeps restarting after the predicate passes, and check "
      + "whether the presence hook ever reports idle before the daemon samples it"
    for character in draft {
      textView.insertText(String(character), replacementRange: textView.selectedRange())
      settle(host)
    }

    host.rootView = AnyView(NodComposerView(store: store).frame(width: to))
    window.setContentSize(NSSize(width: to, height: 300))
    for _ in 0..<5 { settle(host) }

    #expect(textView.frame.height > line * 2)
    #expect(abs(box.frame.height - textView.frame.height) < 2)
    #expect(visible(box).height >= textView.frame.height - 1)
  }

  @Test
  func aLongDraftShowsFiveLinesAndScrolls() throws {
    let (box, text) = try type((1...10).map { "line \($0)" }.joined(separator: "\n"))

    #expect(abs(box.frame.height - line * 5) < 2)
    #expect(text.frame.height >= line * 10 - 1)
    #expect(box.hasVerticalScroller)
    // The caret is on the last line, so that is the one in view.
    #expect(visible(box).maxY >= text.frame.height - 1)
  }
}
