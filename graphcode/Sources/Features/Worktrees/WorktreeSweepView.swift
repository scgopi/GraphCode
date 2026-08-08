import AppKit
import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// The sweeper sheet — one folder's worktrees, grouped by what removing them would lose.
///
/// The grouping is the interface: safe rows arrive selected, look-before rows never do,
/// and in-use rows can't be selected at all. The footer says exactly what the button
/// will do before it does it, and the footnote carries the two safety facts (fully
/// committed directories only; branches recoverable from the reflog).
struct WorktreeSweepView: View {
  @Bindable var store: StoreOf<WorktreeSweepFeature>
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 15) {
      header
      if let assessments = store.assessments {
        if assessments.isEmpty {
          emptyState
        } else {
          ScrollView {
            VStack(alignment: .leading, spacing: 15) {
              tierSection(
                title: "Safe to remove", tint: Tint.safe, assessments: store.safe,
                headerAccessory: safeSelectionToggle)
              tierSection(
                title: "Look before removing", tint: Tint.look, assessments: store.look)
              tierSection(title: "In use", tint: Tint.inUse, assessments: store.inUse)
            }
          }
          .frame(maxHeight: 460)
        }
      } else {
        loadingState
      }
      if let failure = store.failure {
        Text(failure)
          .font(.system(size: 11))
          .foregroundStyle(Color(red: 1.0, green: 0.541, blue: 0.502))
          .lineLimit(3)
      }
      Divider().overlay(.white.opacity(0.08))
      footer
      Text(
        "Branches are deleted too, and stay recoverable from the reflog for 90 days. "
          + "Removing a worktree with uncommitted files asks first — those files are "
          + "gone for good."
      )
      .font(.system(size: 11))
      .foregroundStyle(.white.opacity(0.5))
    }
    .padding(.horizontal, 22)
    .padding(.top, 20)
    .padding(.bottom, 18)
    .frame(width: 640)
    .background(Theme.sheet)
    .task { await store.send(.task).finish() }
  }

  private var discardMessage: String {
    let dirty = store.selected.filter(\.removalDiscardsFiles)
    let files = dirty.map(\.facts.dirtyFileCount).reduce(0, +)
    let what =
      dirty.count == 1
      ? "1 selected worktree has" : "\(dirty.count) selected worktrees have"
    let cost = files == 1 ? "1 uncommitted file" : "\(files) uncommitted files"
    return
      "\(what) \(cost). Commits stay recoverable from the reflog; uncommitted work doesn't."
  }

  private enum Tint {
    static let safe = Color(red: 0.494, green: 0.894, blue: 0.608)
    static let look = Color(red: 1.0, green: 0.804, blue: 0.478)
    static let inUse = Color.white.opacity(0.45)
    static let safeFill = Color(red: 0.188, green: 0.820, blue: 0.345).opacity(0.06)
    static let safeBorder = Color(red: 0.188, green: 0.820, blue: 0.345).opacity(0.2)
    static let lookFill = Color(red: 1.0, green: 0.624, blue: 0.039).opacity(0.07)
    static let lookBorder = Color(red: 1.0, green: 0.624, blue: 0.039).opacity(0.24)
    static let inUseFill = Color.white.opacity(0.02)
    static let inUseBorder = Color.white.opacity(0.07)
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: 9) {
      Text("Worktrees")
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(.white.opacity(0.95))
      Text(headerCaption)
        .font(.system(size: 12))
        .foregroundStyle(.white.opacity(0.5))
    }
  }

  private var headerCaption: String {
    guard let assessments = store.assessments, !assessments.isEmpty else {
      return "in \(store.projectName)"
    }
    let count = assessments.count == 1 ? "1 of them" : "\(assessments.count) of them"
    guard store.totalBytes > 0 else { return "in \(store.projectName) · \(count)" }
    return "in \(store.projectName) · \(count) · \(Self.size(store.totalBytes)) total"
  }

  @ViewBuilder
  private func tierSection(
    title: String, tint: Color, assessments: [WorktreeAssessment],
    headerAccessory: (() -> AnyView)? = nil
  ) -> some View {
    if !assessments.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          Text(title.uppercased())
            .font(.system(size: 11, weight: .bold))
            .tracking(0.66)
            .foregroundStyle(tint.opacity(0.85))
          Text(sectionCount(assessments))
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(.white.opacity(0.5))
          Spacer()
          if let headerAccessory { headerAccessory() }
        }
        ForEach(assessments) { assessment in
          row(assessment)
        }
      }
    }
  }

  private func sectionCount(_ assessments: [WorktreeAssessment]) -> String {
    let bytes = assessments.compactMap(\.facts.sizeBytes).reduce(0, +)
    guard bytes > 0 else { return "\(assessments.count)" }
    return "\(assessments.count) · \(Self.size(bytes))"
  }

  private var safeSelectionToggle: (() -> AnyView)? {
    guard store.safe.count > 1 else { return nil }
    let allSelected = store.safe.allSatisfy { store.selection.contains($0.id) }
    return {
      AnyView(
        Button(allSelected ? "Deselect all" : "Select all") {
          store.send(.allSafeToggled)
        }
        .buttonStyle(.plain)
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(Color(red: 0.424, green: 0.714, blue: 1.0)))
    }
  }

  private func row(_ assessment: WorktreeAssessment) -> some View {
    let tier = assessment.tier
    let selected = assessment.isRemovable && store.selection.contains(assessment.id)
    return HStack(spacing: 11) {
      checkbox(selected: selected, selectable: assessment.isRemovable)
      VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(assessment.ref.branch)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.white.opacity(tier == .inUse ? 0.6 : 0.9))
          if let context = rowContext(assessment) {
            Text(context)
              .font(.system(size: 11.5))
              .foregroundStyle(.white.opacity(tier == .inUse ? 0.45 : 0.55))
          }
        }
        Text(assessment.summary)
          .font(.system(size: 10.5, design: .monospaced))
          .foregroundStyle(summaryInk(tier))
      }
      .lineLimit(1)
      Spacer(minLength: 8)
      if tier == .lookBeforeRemoving && !assessment.facts.prunable {
        Button("Reveal") {
          NSWorkspace.shared.activateFileViewerSelecting([
            URL(fileURLWithPath: assessment.ref.worktreePath)
          ])
        }
        .buttonStyle(.plain)
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(Color(red: 0.424, green: 0.714, blue: 1.0))
      }
      Text(assessment.facts.sizeBytes.map(Self.size) ?? "—")
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.white.opacity(assessment.facts.sizeBytes == nil ? 0.4 : 0.55))
    }
    .padding(.vertical, 9)
    .padding(.horizontal, 11)
    .background(rowFill(tier), in: RoundedRectangle(cornerRadius: 9))
    .overlay {
      RoundedRectangle(cornerRadius: 9).stroke(rowBorder(tier), lineWidth: 1)
    }
    .contentShape(Rectangle())
    .onTapGesture {
      if assessment.isRemovable { store.send(.rowToggled(assessment.id)) }
    }
    .help(rowHelp(assessment))
  }

  private func rowHelp(_ assessment: WorktreeAssessment) -> String {
    if assessment.tier == .inUse { return "A loop is running in it" }
    if assessment.removalDiscardsFiles {
      return "Has uncommitted files — removing it discards them, and asks first"
    }
    return assessment.ref.worktreePath
  }

  private func rowContext(_ assessment: WorktreeAssessment) -> String? {
    if assessment.facts.prunable { return "directory already gone" }
    return assessment.loopTitle
  }

  private func summaryInk(_ tier: WorktreeTier) -> Color {
    switch tier {
    case .safeToRemove: return Tint.safe.opacity(0.8)
    case .lookBeforeRemoving: return Tint.look.opacity(0.85)
    case .inUse: return .white.opacity(0.45)
    }
  }

  private func rowFill(_ tier: WorktreeTier) -> Color {
    switch tier {
    case .safeToRemove: return Tint.safeFill
    case .lookBeforeRemoving: return Tint.lookFill
    case .inUse: return Tint.inUseFill
    }
  }

  private func rowBorder(_ tier: WorktreeTier) -> Color {
    switch tier {
    case .safeToRemove: return Tint.safeBorder
    case .lookBeforeRemoving: return Tint.lookBorder
    case .inUse: return Tint.inUseBorder
    }
  }

  private func checkbox(selected: Bool, selectable: Bool) -> some View {
    ZStack {
      if selected {
        RoundedRectangle(cornerRadius: 4).fill(Color.accentColor)
        Image(systemName: "checkmark")
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(.white)
      } else {
        RoundedRectangle(cornerRadius: 4)
          .strokeBorder(.white.opacity(selectable ? 0.28 : 0.14), lineWidth: 1.5)
      }
    }
    .frame(width: 15, height: 15)
  }

  // The discard confirmation lives inline in the footer, not in a system
  // `confirmationDialog`: a dialog presented inside a sheet re-presents itself every
  // time the sheet's content changes underneath it, and the size stream changes it
  // row by row — the dialog "kept relaunching". A swapped footer can't.
  @ViewBuilder
  private var footer: some View {
    if store.isConfirmingRemoval {
      HStack(spacing: 12) {
        Text(discardMessage)
          .font(.system(size: 12))
          .foregroundStyle(Tint.look)
          .lineLimit(2)
        Spacer()
        Button("Cancel") { store.send(.removeCancelled) }
          .keyboardShortcut(.cancelAction)
        Button("Remove Anyway", role: .destructive) { store.send(.removeConfirmed) }
      }
    } else {
      HStack(spacing: 12) {
        Text(footerSummary)
          .font(.system(size: 12))
          .foregroundStyle(.white.opacity(0.62))
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Remove \(store.selected.count)") { store.send(.removeTapped) }
          .keyboardShortcut(.defaultAction)
          .disabled(store.selected.isEmpty)
      }
    }
  }

  private var footerSummary: String {
    let count = store.selected.count
    guard count > 0 else { return "Nothing selected" }
    let what = count == 1 ? "1 worktree" : "\(count) worktrees"
    guard store.selectedBytes > 0 else { return "Removes \(what)" }
    return "Removes \(what) · frees \(Self.size(store.selectedBytes))"
  }

  /// `412 MB`, the way the Finder would say it.
  static func size(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }

  private var loadingState: some View {
    HStack(spacing: 8) {
      ProgressView().controlSize(.small)
      Text("Reading worktrees…")
        .font(.system(size: 12))
        .foregroundStyle(.white.opacity(0.55))
    }
    .frame(maxWidth: .infinity, minHeight: 80)
  }

  private var emptyState: some View {
    Text("No worktrees in this folder.")
      .font(.system(size: 12))
      .foregroundStyle(.white.opacity(0.55))
      .frame(maxWidth: .infinity, minHeight: 80)
  }
}
