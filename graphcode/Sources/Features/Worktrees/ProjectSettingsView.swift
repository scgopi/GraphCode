import GraphcodeKit
import SwiftUI

/// One folder's settings — today, its worktree policy. The policy is the real fix the
/// sweeper only backstops: a user who sets "Remove it" once never sees the sweeper
/// again, which is the outcome to design for, not a cleanup screen they visit monthly.
///
/// Writes through `SettingsModel.shared` the way the app-wide settings scene does, so
/// every change lands in `~/.graphcode/settings.json` the moment it is made — which is
/// why the sheet says so and Done only closes.
///
/// The policy is three **radio rows**, not a segmented control: segments over a body of
/// content read as tabs, and this sheet's first field test produced exactly that
/// misreading — "each tab shows the same numbers" — about what is really one choice
/// above one shared threshold.
struct ProjectSettingsView: View {
  let projectPath: String
  let projectName: String

  @Environment(\.dismiss) private var dismiss

  /// The threshold fields, text-backed so editing works like a text field: empty is a
  /// legal state *while typing* (an Int binding snapped every backspace straight back),
  /// and only a valid number is committed to the policy. Seeded in `init`, not
  /// `onAppear`: the sheet keeps its SwiftUI identity between presentations, and
  /// seeded-on-appear state showed one folder's numbers over another folder's name.
  @State private var gigabytesText: String
  @State private var countText: String

  init(projectPath: String, projectName: String) {
    self.projectPath = projectPath
    self.projectName = projectName
    let policy = SettingsModel.shared.settings.worktreePolicy(forProjectPath: projectPath)
    _gigabytesText = State(
      initialValue: String(Int((Double(policy.noticeSizeBytes) / Double(1 << 30)).rounded())))
    _countText = State(initialValue: String(policy.noticeCount))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
          Text("Project Settings")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white.opacity(0.95))
          Text(projectName)
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.5))
        }
        Text("Changes apply as you make them — Done just closes.")
          .font(.system(size: 11))
          .foregroundStyle(.white.opacity(0.5))
      }

      VStack(alignment: .leading, spacing: 11) {
        Text("WORKTREES")
          .font(.system(size: 11, weight: .bold))
          .tracking(0.66)
          .foregroundStyle(.white.opacity(0.55))

        VStack(alignment: .leading, spacing: 7) {
          Text("When a loop resolves and its branch has landed")
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))
          VStack(alignment: .leading, spacing: 2) {
            ForEach(WorktreeHygienePolicy.ResolveAction.allCases, id: \.self) { action in
              resolveRow(action)
            }
          }
          Text(
            "Only ever the safe tier — landed, clean, pushed, and bound to no loop. "
              + "Anything else waits for you regardless of this setting."
          )
          .font(.system(size: 11))
          .foregroundStyle(.white.opacity(0.6))
          .fixedSize(horizontal: false, vertical: true)
        }

        Divider().overlay(.white.opacity(0.08))

        VStack(alignment: .leading, spacing: 7) {
          Text("Mention worktrees on the lane when this folder passes")
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))
          HStack(spacing: 9) {
            TextField("2", text: $gigabytesText)
              .textFieldStyle(.roundedBorder)
              .frame(width: 64)
              .onChange(of: gigabytesText) { _, text in
                commitGigabytes(text)
              }
            Text("GB").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
            Text("or").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
            TextField("8", text: $countText)
              .textFieldStyle(.roundedBorder)
              .frame(width: 64)
              .onChange(of: countText) { _, text in
                commitCount(text)
              }
            Text("worktrees").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
          }
          Text(
            "This decides when GraphCode mentions worktrees — the chip on the lane "
              + "turns amber and the titlebar counts them once the folder passes either "
              + "line. It removes nothing; removal is the setting above."
          )
          .font(.system(size: 11))
          .foregroundStyle(.white.opacity(0.6))
        }
      }
      .padding(15)
      .background(Theme.draftField, in: RoundedRectangle(cornerRadius: 11))
      .overlay {
        RoundedRectangle(cornerRadius: 11).stroke(.white.opacity(0.1), lineWidth: 1)
      }

      HStack {
        Spacer()
        Button("Done") { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(.horizontal, 22)
    .padding(.top, 20)
    .padding(.bottom, 18)
    .frame(width: 470)
    .background(Theme.sheet)
  }

  /// One choice with its consequence on the same line — what the segmented control
  /// could not say.
  private func resolveRow(_ action: WorktreeHygienePolicy.ResolveAction) -> some View {
    let selected = policy.onResolveLanded == action
    return Button {
      update { $0.onResolveLanded = action }
    } label: {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        ZStack {
          Circle().strokeBorder(
            selected ? Color.accentColor : .white.opacity(0.3), lineWidth: 1.5)
          if selected {
            Circle().fill(Color.accentColor).frame(width: 7, height: 7)
          }
        }
        .frame(width: 14, height: 14)
        Text(action.displayName)
          .font(.system(size: 12, weight: selected ? .semibold : .regular))
          .foregroundStyle(.white.opacity(selected ? 0.92 : 0.75))
          .frame(width: 76, alignment: .leading)
        Text(explanation(for: action))
          .font(.system(size: 11))
          .foregroundStyle(.white.opacity(0.55))
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
      }
      .padding(.vertical, 4)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func explanation(for action: WorktreeHygienePolicy.ResolveAction) -> String {
    switch action {
    case .remove: return "Removed automatically, the moment the loop finishes."
    case .ask: return "The finished loop's card offers Reclaim / Keep."
    case .keep: return "Nothing happens until you open Worktrees… yourself."
    }
  }

  private var policy: WorktreeHygienePolicy {
    SettingsModel.shared.settings.worktreePolicy(forProjectPath: projectPath)
  }

  private func update(_ transform: (inout WorktreeHygienePolicy) -> Void) {
    var updated = policy
    transform(&updated)
    SettingsModel.shared.settings.worktreePolicies[projectPath] = updated
  }

  /// An empty or half-typed field commits nothing — the last valid value stands, and
  /// the field is free to be empty on the way to the next number.
  private func commitGigabytes(_ text: String) {
    guard let gigabytes = Int(text.trimmingCharacters(in: .whitespaces)), gigabytes >= 1
    else { return }
    update { $0.noticeSizeBytes = Int64(gigabytes) * Int64(1 << 30) }
  }

  private func commitCount(_ text: String) {
    guard let count = Int(text.trimmingCharacters(in: .whitespaces)), count >= 1
    else { return }
    update { $0.noticeCount = count }
  }
}
