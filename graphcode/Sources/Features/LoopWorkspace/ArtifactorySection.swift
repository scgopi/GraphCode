import ArtifactoryKit
import GraphcodeKit
import SwiftUI

/// What the rail needs to know about the board without building a view to find out.
enum ArtifactoryPresentation {
  /// Whether this graph's board has anything to show. Absent while empty, for the
  /// reason the whole rail is absent while empty: a panel that is permanently blank
  /// teaches people to stop looking at the one beside it.
  ///
  /// The gate is the same bit the daemon enforces, read by the caller rather than here
  /// so the render path never touches the settings file.
  static func hasContent(graph: LoopGraph, enabled: Bool) -> Bool {
    enabled && !graph.artifactory.isEmpty
  }

  /// The posts somebody wrote on purpose, newest last — the direction the summary and
  /// the terminal beside it already run.
  static func notes(in graph: LoopGraph) -> [ArtifactoryPost] {
    graph.artifactory.filter { $0.kind == .note }
  }

  /// The mirrored direct messages and handoffs. Kept apart from the notes because they
  /// are receipts for deliveries that already happened, not something written to be
  /// read here.
  static func records(in graph: LoopGraph) -> [ArtifactoryPost] {
    graph.artifactory.filter { $0.kind == .record }
  }

  /// How many notes have landed since the human last looked — `seenPostID` is
  /// `LoopWorkspaceFeature.seenArtifactoryPostID`, not the loop's sync cursor. Records
  /// are excluded: they are folded away by default, and a badge counting mail nobody is
  /// being shown is a badge that cannot be cleared.
  static func unreadNoteCount(graph: LoopGraph, seenPostID: Int?) -> Int {
    Artifactory.unread(in: notes(in: graph), since: seenPostID).count
  }
}

/// The Artifactory in the workspace rail — a peer of `LoopSummarySection` and
/// `SummaryBoardSection`, and the one place a human meets the board without a shell.
///
/// The board is how loops leave notes for whoever comes next, and until this section
/// existed the only way to read one was a CLI verb nobody had been told about. That is
/// the whole reason it is here rather than behind a menu: a coordination channel a
/// supervisor never sees is the failure mode, not a missing convenience.
struct ArtifactorySection: View {
  let graph: LoopGraph
  /// What `SINCE YOU LOOKED` means here: the newest post that was on screen when this
  /// person last left a workspace in the project. The same words two sections up mean
  /// the same thing — a fact about a person at a screen, never about the loop.
  let seenPostID: Int?
  let isFolded: Bool
  let onToggleFold: () -> Void
  /// Posts as "a human" — a click in the app has no `ZMX_SESSION` and no loop identity,
  /// which is exactly what a person talking to the whole graph is.
  let onPost: (String, String?) -> Void

  /// Whether the mirrored records are unfolded. Local and unpersisted, unlike the
  /// section's own fold: opening the receipts is a thing you do once to answer a
  /// question, not a way you prefer to read the board.
  /// Past this the board scrolls rather than pushing the sections above it off the rail.
  /// Every note is on the board and reachable — this is only how much of it is on screen
  /// before the wheel takes over. About ten posts at the rail's default width, which is
  /// the number asked for: enough to read a conversation, not so many that the rail
  /// is nothing but the board.
  static let maxScrollHeight: CGFloat = 600

  @State private var showsRecords = false
  @State private var isComposing = false
  @State private var draft = ""
  @State private var draftTopic = ""
  @FocusState private var draftFocused: Bool

  private var notes: [ArtifactoryPost] { ArtifactoryPresentation.notes(in: graph) }
  private var records: [ArtifactoryPost] { ArtifactoryPresentation.records(in: graph) }
  private var unread: Int {
    ArtifactoryPresentation.unreadNoteCount(graph: graph, seenPostID: seenPostID)
  }

  /// The id the unread rule is drawn above — the first note that landed after the human
  /// last looked. `nil` when everything is read, which is when nothing should be drawn.
  private var firstUnreadID: Int? {
    guard unread > 0 else { return nil }
    return notes.suffix(unread).first?.id
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      header
      if isFolded {
        foldedLine
      } else {
        ScrollView(.vertical) {
          VStack(alignment: .leading, spacing: 11) {
            recordsRollup
            ForEach(notes) { post in
              if post.id == firstUnreadID { sinceYouLooked }
              postRow(post)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.bottom)
        // Hug the posts, and only then scroll. A `ScrollView` is greedy — offered the
        // rail's slack it takes it, and `defaultScrollAnchor(.bottom)` then pins the
        // posts to the foot of that box with a gap between them and the header. Two
        // attempts measured the content through a preference and sized the box to it;
        // both mis-sized (a zero start that never laid out, then a stale reading that
        // left the gap). This is the idiom that needs no measuring: `fixedSize`
        // (vertical) asks the scroll view for its *ideal* height, which is its
        // content's, and `frame(maxHeight:)` under it clamps that. The box is exactly
        // as tall as the posts until the cap, and scrolls after — no state, nothing to
        // go stale, nothing to fire late.
        .frame(maxHeight: Self.maxScrollHeight)
        .fixedSize(horizontal: false, vertical: true)
        // Outside the scroll view on purpose. Inside it the composer was one more row
        // in a list that can be taller than the rail — it could open scrolled out of
        // sight, and it moved under the pointer as posts arrived. Pinned here it is
        // always the thing directly above the section's rule while you are writing.
        leaveANoteButton
      }
      Rectangle().fill(.white.opacity(0.07)).frame(height: 1)
    }
    // A sheet, not a field in the rail — the only shape text entry has ever worked in
    // this app, and now it is clear why. Ghostty's `NSView` holds the window's first
    // responder while a loop is open, and `@FocusState` cannot take it off an AppKit
    // view inside the same window: the caret never arrived, so every keystroke went to
    // the terminal and the draft stayed empty. A sheet gets its own key window, which
    // is why `JumpPaletteView` focuses with a bare `onAppear` and why the rename and
    // delete prompts are hosted the same way. See `AppView`'s note on ⌘K opening over
    // a terminal as readily as over a canvas.
    .sheet(isPresented: $isComposing) {
      composerSheet
    }
  }

  private var unreadIDs: Set<Int> {
    Set(notes.suffix(unread).map(\.id))
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 7) {
      Text("ARTIFACTORY")
        .font(.system(size: 10.5, weight: .bold))
        .tracking(0.63)
        .foregroundStyle(.white.opacity(0.5))
      Spacer(minLength: 0)
      if unread > 0 {
        Text("\(unread) NEW")
          .font(.system(size: 9.5, weight: .bold))
          .tracking(0.38)
          .foregroundStyle(Color(red: 0.549, green: 0.773, blue: 1.0))
          .padding(.horizontal, 5)
          .frame(height: 14)
          .background(
            Theme.paneFocusTint.opacity(0.22), in: RoundedRectangle(cornerRadius: 3))
      }
      Image(systemName: isFolded ? "chevron.down" : "chevron.up")
        .font(.system(size: 8, weight: .semibold))
        .foregroundStyle(.white.opacity(0.6))
        .frame(width: 14, height: 14)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 3))
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggleFold)
    }
    .contentShape(Rectangle())
    .help(isFolded ? "Show the board" : "Collapse to one line")
  }

  /// Folded keeps the newest note, for the reason the summary's fold keeps its beat: a
  /// folded section that shows nothing is a section you forget exists.
  private var foldedLine: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(accent(for: notes.last))
        .frame(width: 6, height: 6)
      Text(notes.last?.body ?? "no notes yet")
        .font(.system(size: 11.5))
        .foregroundStyle(.white.opacity(0.75))
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 0)
    }
    .contentShape(Rectangle())
    .onTapGesture(perform: onToggleFold)
  }

  /// The one place a human speaks to the graph, and it says so in words.
  ///
  /// This was a `+` on the header, drawn only under the pointer — the manners every
  /// other header control in the app has, and wrong here. Those are all *second* ways
  /// to do something reachable elsewhere; this is the only way to put a human's note on
  /// the board without leaving for a terminal, and an affordance you have to hover to
  /// discover is one nobody discovers. Named, always drawn, and sitting exactly where
  /// the composer opens, so the click and its result are in the same place.
  private var leaveANoteButton: some View {
    Button {
      isComposing = true
    } label: {
      HStack(spacing: 5) {
        Image(systemName: "square.and.pencil")
          .font(.system(size: 10, weight: .medium))
        Text("Leave a note")
          .font(.system(size: 11, weight: .semibold))
      }
      .foregroundStyle(.white.opacity(0.62))
      .frame(maxWidth: .infinity, minHeight: 24)
      .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
      .overlay {
        RoundedRectangle(cornerRadius: 5).stroke(.white.opacity(0.08), lineWidth: 1)
      }
    }
    .buttonStyle(.plain)
    .help("Post a note to this project's board, as a human")
  }

  private var sinceYouLooked: some View {
    HStack(spacing: 7) {
      Text("SINCE YOU LOOKED")
        .font(.system(size: 9.5, weight: .bold))
        .tracking(0.38)
        .foregroundStyle(Color(red: 0.549, green: 0.773, blue: 1.0).opacity(0.85))
      Rectangle().fill(Theme.paneFocusTint.opacity(0.35)).frame(height: 1)
    }
  }

  // MARK: - Records

  /// The mirrored traffic, one line each and never a body: a record says that two loops
  /// spoke, which is all a reader of the board needs from it.
  @ViewBuilder
  private var recordsRollup: some View {
    if !records.isEmpty {
      VStack(alignment: .leading, spacing: 7) {
        HStack(spacing: 6) {
          Image(systemName: showsRecords ? "chevron.down" : "chevron.right")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.white.opacity(0.38))
          Text(
            records.count == 1 ? "1 message record" : "\(records.count) message records"
          )
          .font(.system(size: 10.5))
          .foregroundStyle(.white.opacity(0.5))
          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { showsRecords.toggle() }
        if showsRecords {
          VStack(alignment: .leading, spacing: 7) {
            ForEach(records.suffix(8)) { record in
              HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(ArtifactoryPost.stampFormat.string(from: record.at))
                  .font(.system(size: 10.5, design: .monospaced))
                  .foregroundStyle(.white.opacity(0.32))
                Text(record.body)
                  .font(.system(size: 11))
                  .foregroundStyle(.white.opacity(0.5))
                  .lineLimit(1)
                  .truncationMode(.tail)
              }
            }
            if records.count > 8 {
              Text("\(records.count - 8) earlier")
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.4))
            }
          }
          .padding(.leading, 14)
        }
      }
    }
  }

  // MARK: - Posts

  private func postRow(_ post: ArtifactoryPost) -> some View {
    let read = !unreadIDs.contains(post.id)
    return HStack(alignment: .top, spacing: 8) {
      RoundedRectangle(cornerRadius: 1)
        .fill(accent(for: post).opacity(read ? 0.45 : 1))
        .frame(width: 2)
      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          if let topic = post.topic {
            Text(topic.uppercased())
              .font(.system(size: 9.5, weight: .bold))
              .tracking(0.48)
              .foregroundStyle(accent(for: post).opacity(read ? 0.85 : 1))
              .lineLimit(1)
          }
          Text(ArtifactoryPost.stampFormat.string(from: post.at))
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(.white.opacity(0.4))
          Spacer(minLength: 0)
        }
        Text(post.body)
          .font(.system(size: 12.5))
          .lineSpacing(2)
          .foregroundStyle(.white.opacity(read ? 0.55 : 0.9))
          .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 4) {
          if post.authorID == nil {
            Image(systemName: "person")
              .font(.system(size: 8))
              .foregroundStyle(.white.opacity(0.38))
          }
          Text(post.author)
            .font(.system(size: 10.5))
            .foregroundStyle(.white.opacity(0.38))
            .lineLimit(1)
        }
      }
    }
  }

  /// A post wears its author's loop colour, so a board read at a glance says who is
  /// talking before it says what about. A human's note is the achromatic slot, which is
  /// the one distinction no dichromacy erodes — see `LoopTypeAppearance.accent`.
  private func accent(for post: ArtifactoryPost?) -> Color {
    guard let post else { return .white.opacity(0.3) }
    guard let authorID = post.authorID, let author = graph.nodes[id: authorID] else {
      return LoopType.sketch.accent
    }
    return author.loopType.accent
  }

  // MARK: - Composing

  /// A human's voice on the board.
  private var composerSheet: some View {
    VStack(spacing: 12) {
      Text("Leave a note").font(.headline)

      Text(
        """
        Every loop in this project reads this board, including loops that do not exist \
        yet. Post what a peer or a successor should not have to rediscover — a dead end, \
        a decision, a claim you are staking.
        """
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)

      Form {
        TextField("Topic (optional)", text: $draftTopic, prompt: Text("claims, build, findings"))
          .autocorrectionDisabled()
        TextField("Note", text: $draft, axis: .vertical)
          .lineLimit(3...10)
          .focused($draftFocused)
      }
      .formStyle(.columns)
      .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 6) {
        Image(systemName: "person")
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
        Text("Posts as “a human” — the app carries no loop identity.")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer(minLength: 0)
        // Only as the bound approaches: the daemon refuses anything over it, and a
        // counter on an empty field is chrome.
        if remainingBytes <= 120 {
          Text("\(remainingBytes)")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(remainingBytes < 0 ? .red : .secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      HStack {
        Button("Cancel") { cancelCompose() }
          .keyboardShortcut(.cancelAction)
        Spacer()
        Button("Post") { submit() }
          .keyboardShortcut(.defaultAction)
          .disabled(!canPost)
      }
    }
    .padding(24)
    .frame(width: 420)
    // No run-loop hop needed, unlike the rail: the sheet's own window is key by the
    // time this runs, which is the whole reason the composer moved into one.
    .onAppear { draftFocused = true }
  }

  private var trimmedDraft: String {
    draft.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var remainingBytes: Int {
    ArtifactoryPost.maxBodyBytes - trimmedDraft.utf8.count
  }

  private var canPost: Bool { !trimmedDraft.isEmpty && remainingBytes >= 0 }

  private func submit() {
    guard canPost else { return }
    let topic = draftTopic.trimmingCharacters(in: .whitespacesAndNewlines)
    onPost(trimmedDraft, topic.isEmpty ? nil : topic)
    cancelCompose()
  }

  private func cancelCompose() {
    isComposing = false
    draftFocused = false
    draft = ""
    draftTopic = ""
  }
}
