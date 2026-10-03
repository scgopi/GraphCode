import AppKit
import ComposableArchitecture
import Foundation
import GraphcodeKit
import SwiftUI
import Testing

@testable import graphcode

/// Draws the chat pane headless, the way a reviewer sees it. Every run lays each state out
/// and checks something was drawn; PNGs are written only when `/tmp/nod-chat-renders`
/// exists (`mkdir` it, run the suite, look) — environment variables do not reach the test
/// runner through `xcodebuild test`.
@MainActor
@Suite
struct NodChatRenderTests {
  private static let outputDirectory = URL(fileURLWithPath: "/tmp/nod-chat-renders")

  private func render<V: View>(_ name: String, width: CGFloat, height: CGFloat, _ view: V)
    throws
  {
    let host = NSHostingView(
      rootView: view.frame(width: width, height: height).environment(\.colorScheme, .dark))
    host.frame = CGRect(x: 0, y: 0, width: width, height: height)
    host.layoutSubtreeIfNeeded()
    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    #expect(rep.pixelsWide >= Int(width))
    guard FileManager.default.fileExists(atPath: Self.outputDirectory.path) else { return }
    let png = try #require(rep.representation(using: .png, properties: [:]))
    try png.write(to: Self.outputDirectory.appendingPathComponent("\(name).png"))
  }

  private func store(_ log: NodLog, configure: (inout NodChatFeature.State) -> Void = { _ in })
    -> StoreOf<NodChatFeature>
  {
    var state = NodChatFeature.State(
      nodeID: UUID(), loopTitle: "Monetization", loopType: .goalBased,
      branch: "loop/monetization",
      goal: "Done when every paid route enforces the cap and swift test passes")
    state.transcript = log.transcript
    configure(&state)
    return Store(initialState: state) {
      NodChatFeature()
    } withDependencies: {
      $0.nodClient = .replaying(log.records)
    }
  }

  @Test
  func theReadingColumn() throws {
    try render(
      "1-pane-running", width: 900, height: 1100,
      NodChatPaneView(store: store(.monetization), projectName: "graphcode"))
  }

  @Test
  func theGoalHeaderOpenWithAToolCardOpen() throws {
    let pane = NodChatPaneView(
      store: store(.monetization) {
        $0.isGoalExpanded = true
        $0.expandedTools = ["c3"]
      }, projectName: "graphcode")
    try render("2-goal-open-tool-open", width: 900, height: 1300, pane)
  }

  @Test
  func aLongTurnFoldsIntoAWorkBlock() throws {
    var log = NodLog()
    log.session()
    log.user("Fix /export and add a test that hits the limit.", id: "u1")
    log.turn(4)
    log.say(
      "`ExportRoute` is registered before `UsageGate`. Moving it into the paid group and adding `testExportBlocksPastCap`.",
      turn: 4, id: "m1")
    for (index, file) in ["UsageGate.swift", "Routes.swift", "ExportRoute.swift"].enumerated() {
      log.tool(
        "r\(index)", turn: 4, tool: "Read", title: "Read \(file)", summary: "84 lines", ms: 300)
    }
    log.tool("s1", turn: 4, tool: "Grep", title: "Search \"paid\"", summary: "9 hits", ms: 400)
    log.tool("e1", turn: 4, tool: "Edit", title: "Edit Routes.swift", summary: "+3 −1", ms: 50)
    log.tool(
      "e2", turn: 4, tool: "Edit", title: "Edit UsageCapTests.swift", summary: "+22", ms: 50)
    log.hunk(
      "h2", turn: 4, file: "Tests/UsageCapTests.swift",
      header: "@@ 18,4 @@ testExportBlocksPastCap",
      diff: """
        + for _ in 0..<50 { try await app.export(user) }
        + let res = try await app.export(user)
        + XCTAssertEqual(res.status, .paymentRequired)
        """, added: 3, removed: 0)
    log.tool("b1", turn: 4, tool: "Bash", title: "swift test --filter UsageCap", status: nil)
    log.user("use the fixture clock, not Date()", id: "u2", delivery: "steer")
    log.user("also log when a request is blocked", id: "u3")
    log.usage(cost: 1.18, context: 0.44)

    try render(
      "3-work-folded", width: 900, height: 900,
      NodChatPaneView(store: store(log), projectName: "graphcode"))
    try render(
      "4-work-open-commenting", width: 900, height: 1100,
      NodChatPaneView(
        store: store(log) {
          $0.expandedWork = [4]
          $0.commentingHunkID = "h2"
          $0.hunkComment = "use 51 so it's past the cap"
        }, projectName: "graphcode"))
  }

  @Test
  func cardsMetResolvedAndForking() throws {
    var log = NodLog.monetization
    log.add("permissionResolved", ["askID": "a1", "decision": "allowOnce"])
    log.add("hunkResolved", ["hunkID": "h1", "decision": "accept"])
    log.add(
      "toolResult", ["callID": "c4", "status": "ok", "summary": "exit 0", "durationMs": 9000])
    log.say(
      "Two ways to gate /export: move it into the paid group, or check the cap inside the handler.",
      turn: 2, id: "m3")
    log.goalCheck(
      turn: 2, met: true,
      clauses: [
        ("Every paid route goes through UsageGate", true, "4 / 4 routes"),
        ("swift test passes", true, "31 tests pass"),
      ])
    log.endTurn(2, files: 2, added: 25, removed: 1)
    try render(
      "5-goal-holds-fork-menu", width: 900, height: 1500,
      NodChatPaneView(
        store: store(log) { $0.forkMenuMessageID = "m3" }, projectName: "graphcode"))
  }

  @Test
  func theThreeFailureBanners() throws {
    var expired = NodLog.monetization
    expired.failure(
      "signInExpired", "Copilot sign-in expired. Nod paused after turn 6, and nothing was lost.")
    var context = NodLog.monetization
    context.usage(cost: 0.2, context: 0.82)
    var cap = NodLog.monetization
    cap.failure("spendCap", "Nightly deps hit its $2.00 cap this run. Stopped mid-turn 3.")

    let column = VStack(spacing: 10) {
      ForEach(Array([expired, context, cap].enumerated()), id: \.offset) { _, log in
        if let banner = NodChatPresentation.banner(for: log.transcript) {
          NodBannerView(banner: banner, onSignIn: {}, onCompact: {}, onRaiseCap: {})
        }
      }
    }
    .padding(20)
    .background(NodStyle.paneBackground)
    try render("6-banners", width: 720, height: 200, column)
  }

  @Test
  func theComposerWithAttachmentsAndItsMenus() throws {
    let idle = store(NodLog()) {
      $0.attachments = [
        NodAttachment(kind: .file, reference: "/repo/UsageGate.swift"),
        NodAttachment(kind: .image, reference: "/tmp/banner.png"),
        NodAttachment(kind: .loopTranscript, reference: UUID().uuidString, label: "Pricing"),
      ]
      $0.draft = "Make the upgrade banner match this screenshot, using the limits from Pricing."
    }
    let slash = store(.monetization) { $0.draft = "/" }
    let mention = store(.monetization) {
      $0.draft = "Check that @bi"
      $0.mentionCandidates = [
        NodMention(
          title: "Billing UI",
          kind: .loop(id: UUID(), isRunning: true, detail: "Turn · running")),
        NodMention(
          title: "Billing migration",
          kind: .loop(id: UUID(), isRunning: false, detail: "Composite · done 3d")),
        NodMention(title: "BillingBanner.swift", kind: .file(path: "App/BillingBanner.swift")),
      ]
    }
    let column = VStack(spacing: 24) {
      NodComposerView(store: idle).padding(.top, 10)
      NodComposerView(store: slash).padding(.top, 250)
      NodComposerView(store: mention).padding(.top, 170)
    }
    .padding(20)
    .frame(maxHeight: .infinity, alignment: .top)
    .background(NodStyle.paneBackground)
    try render("7-composer", width: 720, height: 700, column)
  }

  /// Design 2's composer grows with the draft up to five lines, then scrolls.
  @Test
  func theComposerGrowsToFiveLines() throws {
    let two = store(.monetization) {
      $0.draft =
        "Fix /export and add a test that hits the limit.\nAlso log when a request is blocked."
    }
    let seven = store(.monetization) {
      $0.draft = (1...7).map { "Line \($0) of a long instruction for Nod." }.joined(separator: "\n")
    }
    let column = VStack(spacing: 24) {
      NodComposerView(store: two)
      NodComposerView(store: seven)
    }
    .padding(20)
    .frame(maxHeight: .infinity, alignment: .top)
    .background(NodStyle.paneBackground)
    try render("10-composer-lines", width: 720, height: 360, column)
  }

  @Test
  func theGraphLayerSlots() throws {
    var log = NodLog.monetization
    log.goalCheck(turn: 2, met: true, clauses: [("Every paid route is capped", true, "4 / 4")])
    let placeholder = { (text: String) in
      AnyView(
        Text(text)
          .font(.system(size: 12))
          .foregroundStyle(NodStyle.actionInk)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(10)
          .overlay(
            RoundedRectangle(cornerRadius: 8)
              .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
              .foregroundStyle(NodStyle.actionInk)))
    }
    let slots = NodGraphSlots(
      contextStrip: { placeholder("contextStrip") },
      afterTurn: { placeholder("afterTurn \($0)") },
      aboveComposer: { placeholder("aboveComposer") },
      inboundMessage: { message, _ in
        message.id == "u1" ? placeholder("inboundMessage: \(message.text)") : nil
      },
      afterGoalCheck: { $0.met ? placeholder("afterGoalCheck: handoff offer") : nil })
    try render(
      "8-graph-slots", width: 900, height: 1500,
      NodChatPaneView(store: store(log), projectName: "graphcode")
        .environment(\.nodGraphSlots, slots))
  }

  /// The slots as `LoopWorkspaceView` installs them: the context strip, Billing UI's mail
  /// with Nod's draft, the editable plan, and the handoff offer under the held goal.
  @Test
  func theGraphLayerAsTheWorkspaceInstallsIt() throws {
    let store = Store(initialState: NodGraphLayerFixture.workspace()) {
      LoopWorkspaceFeature()
    } withDependencies: {
      $0.nodClient = .replaying(NodGraphLayerFixture.log.records)
    }
    let scoped: StoreOf<NodChatFeature>? = store.scope(state: \.nodChat, action: \.nodChat)
    let chat = try #require(scoped)
    try render(
      "9-graph-layer-wired", width: 900, height: 1700,
      NodChatPaneView(store: chat, projectName: "repo")
        .environment(\.nodGraphSlots, .workspace(store, chat: chat)))
  }
}
