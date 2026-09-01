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

  /// How many notes this loop's cursor has not covered. Records are excluded: they are
  /// folded away by default, and a badge counting mail nobody is being shown is a badge
  /// that cannot be cleared.
  static func unreadNoteCount(graph: LoopGraph, node: LoopNode) -> Int {
    Artifactory.unread(in: notes(in: graph), since: node.lastArtifactoryRead).count
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
  let node: LoopNode
  let graph: LoopGraph
  let isFolded: Bool
  let onToggleFold: () -> Void
  /// Posts as "a human" — a click in the app has no `ZMX_SESSION` and no loop identity,
  /// which is exactly what a person talking to the whole graph is.
  let onPost: (String, String?) -> Void

  /// Whether the mirrored records are unfolded. Local and unpersisted, unlike the
  /// section's own fold: opening the receipts is a thing you do once to answer a
  /// question, not a way you prefer to read the board.
  @State private var showsRecords = false
  @State private var isComposing = false
  @State private var draft = ""
  @State private var draftTopic = ""
  @FocusState private var draftFocused: Bool

  private var notes: [ArtifactoryPost] { ArtifactoryPresentation.notes(in: graph) }
  private var records: [ArtifactoryPost] { ArtifactoryPresentation.records(in: graph) }
  private var unread: Int {
    ArtifactoryPresentation.unreadNoteCount(graph: graph, node: node)
  }

  /// The id the unread rule is drawn above — the first note this loop's cursor has not
  /// covered. `nil` when everything is read, which is when nothing should be drawn.
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
            if isComposing { composer }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.bottom)
        .frame(minHeight: 90, maxHeight: .infinity)
      }
      Rectangle().fill(.white.opacity(0.07)).frame(height: 1)
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
      if !isFolded {
        Button {
          isComposing = true
          draftFocused = true
        } label: {
          Image(systemName: "plus")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white.opacity(0.62))
            .frame(width: 14, height: 14)
        }
        .buttonStyle(.plain)
        .help("Leave a note on the board")
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

  /// A human's voice on the board. Anchored at the foot, where the post will land.
  private var composer: some View {
    VStack(alignment: .leading, spacing: 7) {
      TextField("topic (optional)", text: $draftTopic)
        .textFieldStyle(.plain)
        .font(.system(size: 10.5))
        .foregroundStyle(.white.opacity(0.75))
      TextField("a note for whoever comes next", text: $draft, axis: .vertical)
        .textFieldStyle(.plain)
        .font(.system(size: 12.5))
        .foregroundStyle(.white.opacity(0.92))
        .lineLimit(2...6)
        .focused($draftFocused)
      HStack(spacing: 6) {
        Image(systemName: "person")
          .font(.system(size: 8))
          .foregroundStyle(.white.opacity(0.42))
        Text("posting as a human")
          .font(.system(size: 10))
          .foregroundStyle(.white.opacity(0.42))
        Spacer(minLength: 0)
        // Shown only as the bound approaches: a counter on an empty field is chrome,
        // and the daemon refuses anything over this anyway.
        if remainingBytes <= 120 {
          Text("\(remainingBytes)")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(remainingBytes < 0 ? .red : .white.opacity(0.5))
        }
        Button("Cancel") { cancelCompose() }
          .buttonStyle(.plain)
          .font(.system(size: 10.5))
          .foregroundStyle(.white.opacity(0.5))
          .keyboardShortcut(.cancelAction)
        Button("Post") { submit() }
          .buttonStyle(.plain)
          .font(.system(size: 10.5, weight: .semibold))
          .foregroundStyle(
            canPost
              ? AnyShapeStyle(Color(red: 0.549, green: 0.773, blue: 1.0))
              : AnyShapeStyle(.white.opacity(0.3))
          )
          .disabled(!canPost)
          .keyboardShortcut(.return, modifiers: .command)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 9)
    .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
    .overlay {
      RoundedRectangle(cornerRadius: 9)
        .stroke(Theme.paneFocusTint.opacity(0.45), lineWidth: 1)
    }
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
