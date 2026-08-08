import GraphcodeKit
import SwiftUI

/// The titlebar's centred chip: how many loops want a human, and nothing else.
///
/// It used to carry standing counts of running and idle loops beside this one. They were
/// answers to a question nobody was asking: knowing five loops are running and four are
/// not is not something you act on, and both numbers are already legible from the cards,
/// the sidebar rows and the canvas rail — so the strip that is on screen in every pane
/// spent itself restating them. What is left is the only count that asks for something
/// back, and it is absent whenever the answer is zero.
///
/// The number is the same `AttentionRollup` the rail and the sidebar read; nothing here
/// rolls up twice.
struct NeedsYouChip: View {
  let count: Int
  /// The same verb as the canvas rail's Review button and ⇧⌘R: open the loop waiting
  /// longest, then the next on each press. A count that names loops wanting a human
  /// and does nothing when clicked reads as broken next to the worktree chip beside
  /// it, which does.
  let action: () -> Void

  var body: some View {
    // Bare chip: the toolbar's own glass capsule is the container, same as
    // `JumpFieldButton` — a second rounded rect around it doubled the chrome.
    Button(action: action) {
      HStack(spacing: 5) {
        StateIndicator(state: .awaitingInput, diameter: 6)
        Text("\(count) need you")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Self.ink)
      }
      .padding(.vertical, 2)
      .padding(.horizontal, 8)
      .background(Self.tint, in: RoundedRectangle(cornerRadius: 5))
    }
    .buttonStyle(.plain)
    .help("Review what needs you (⇧⌘R)")
  }

  private static let tint = Color(red: 1.0, green: 0.624, blue: 0.039).opacity(0.16)
  private static let ink = Color(red: 1.0, green: 0.745, blue: 0.361)  // #ffbe5c
}

/// The titlebar's worktree notice — the needs-you chip's quieter cousin, present only
/// while some folder is past its own notice threshold (`WorktreeHygienePolicy`).
///
/// One chip, not one per folder: it names the worst accumulator and counts the rest,
/// and clicking it opens the sweeper already scoped to that folder. Amber like the
/// lane chip because it is the same fact surfacing one level up — but it stays a chip:
/// no badge, no modal, no red.
struct WorktreeNoticeChip: View {
  let notice: WorktreeNotice
  /// How many *other* folders are also past their threshold.
  let extraFolders: Int
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 5) {
        Circle()
          .fill(Color(red: 1.0, green: 0.624, blue: 0.039))
          .frame(width: 5, height: 5)
        Text(label)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Self.ink)
      }
      .padding(.vertical, 2)
      .padding(.horizontal, 8)
      .background(Self.tint, in: RoundedRectangle(cornerRadius: 5))
    }
    .buttonStyle(.plain)
    .help("Worktrees are accumulating in \(notice.folderName) — click to review")
  }

  private var label: String {
    let what =
      notice.stats.reclaimable > 0
      ? "\(notice.stats.reclaimable) reclaimable"
      : (notice.stats.total == 1 ? "1 worktree" : "\(notice.stats.total) worktrees")
    let more = extraFolders > 0 ? " +\(extraFolders)" : ""
    return "\(notice.folderName) · \(what)\(more)"
  }

  private static let tint = Color(red: 1.0, green: 0.624, blue: 0.039).opacity(0.12)
  private static let ink = Color(red: 1.0, green: 0.804, blue: 0.478).opacity(0.92)
}

/// The sidebar's bottom-left update banner — quiet standing news that a newer build is
/// waiting, set by the silent launch check (`AppFeature.checkForUpdatesInBackground`).
///
/// Accent blue, not amber: an update is an offer, not something that needs a human the
/// way the attention surfaces do. Clicking it opens the same offer alert the menu's
/// "Check for Updates" raises on success — Install / Release Notes / Later.
struct SidebarUpdateBanner: View {
  let version: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: "arrow.down.circle.fill")
          .font(.system(size: 14))
          .foregroundStyle(Self.accent)
        VStack(alignment: .leading, spacing: 1) {
          Text("Update available")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.92))
          Text("\(version) · click to install")
            .font(.system(size: 10.5))
            .foregroundStyle(.white.opacity(0.55))
            .lineLimit(1)
        }
        Spacer(minLength: 0)
      }
      .padding(.vertical, 7)
      .padding(.horizontal, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Self.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8).stroke(Self.accent.opacity(0.3), lineWidth: 1)
      }
    }
    .buttonStyle(.plain)
    .help("A newer version of GraphCode is available — click to install")
  }

  private static let accent = Color(red: 0.039, green: 0.518, blue: 1.0)  // #0A84FF
}

/// The ⌘K affordance, in the titlebar where a search field belongs.
///
/// A shortcut nobody can see is a shortcut nobody uses. This is the discoverable half of
/// the jump palette — it opens exactly what ⌘K opens.
struct JumpFieldButton: View {
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    // No pill of its own: the toolbar already wraps the item in the system's glass
    // capsule, and a hand-drawn rounded rect inside it read as a button on a button.
    Button(action: action) {
      HStack(spacing: 8) {
        Text("Jump to loop")
          .font(.system(size: 11.5))
          .foregroundStyle(.white.opacity(isHovered ? 0.6 : 0.42))
        Text("⌘K")
          .font(.system(size: 10.5, design: .monospaced))
          .foregroundStyle(.white.opacity(0.5))
      }
      // The capsule is the toolbar's, so this padding is what sets its inset: at 2 the
      // text sat against the glass edge and the whole item read as cramped.
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .help("Jump to a loop by name")
  }
}
