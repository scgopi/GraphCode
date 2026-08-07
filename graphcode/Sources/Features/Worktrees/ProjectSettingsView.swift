import GraphcodeKit
import SwiftUI

/// One folder's settings — today, its worktree policy. The policy is the real fix the
/// sweeper only backstops: a user who sets "Remove it" once never sees the sweeper
/// again, which is the outcome to design for, not a cleanup screen they visit monthly.
///
/// Writes through `SettingsModel.shared` the way the app-wide settings scene does, so
/// every change lands in `~/.graphcode/settings.json` the moment it is made.
struct ProjectSettingsView: View {
  let projectPath: String
  let projectName: String

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .firstTextBaseline, spacing: 9) {
        Text("Project Settings")
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(.white.opacity(0.95))
        Text(projectName)
          .font(.system(size: 12))
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
          Picker("", selection: resolveAction) {
            ForEach(WorktreeHygienePolicy.ResolveAction.allCases, id: \.self) { action in
              Text(action.displayName).tag(action)
            }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          Text(
            "Only ever the safe tier — landed, clean, pushed, and bound to no loop. "
              + "Anything else waits for you regardless of this setting."
          )
          .font(.system(size: 11))
          .foregroundStyle(.white.opacity(0.6))
        }

        Divider().overlay(.white.opacity(0.08))

        VStack(alignment: .leading, spacing: 7) {
          Text("Mention it on the lane when this folder passes")
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))
          HStack(spacing: 9) {
            TextField("", value: noticeGigabytes, format: .number)
              .textFieldStyle(.roundedBorder)
              .frame(width: 64)
            Text("GB").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
            Text("or").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
            TextField("", value: noticeCount, format: .number)
              .textFieldStyle(.roundedBorder)
              .frame(width: 64)
            Text("worktrees").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
          }
          Text(
            "A repo with four worktrees is working as designed. The chip appears when "
              + "the folder is genuinely accumulating — and it stays a chip: no badge, "
              + "no modal, no red."
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

  private var policy: WorktreeHygienePolicy {
    SettingsModel.shared.settings.worktreePolicy(forProjectPath: projectPath)
  }

  private func update(_ transform: (inout WorktreeHygienePolicy) -> Void) {
    var updated = policy
    transform(&updated)
    SettingsModel.shared.settings.worktreePolicies[projectPath] = updated
  }

  private var resolveAction: Binding<WorktreeHygienePolicy.ResolveAction> {
    Binding(
      get: { policy.onResolveLanded },
      set: { action in update { $0.onResolveLanded = action } })
  }

  /// Whole gigabytes are the honest granularity here: the threshold is a "genuinely
  /// accumulating" line, not an accounting figure.
  private var noticeGigabytes: Binding<Int> {
    Binding(
      get: { Int((Double(policy.noticeSizeBytes) / Double(1 << 30)).rounded()) },
      set: { gigabytes in
        update { $0.noticeSizeBytes = Int64(max(gigabytes, 1)) * Int64(1 << 30) }
      })
  }

  private var noticeCount: Binding<Int> {
    Binding(
      get: { policy.noticeCount },
      set: { count in update { $0.noticeCount = max(count, 1) } })
  }
}
