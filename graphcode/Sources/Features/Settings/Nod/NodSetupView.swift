import GraphcodeKit
import SwiftUI

/// "Set up Nod" (design 5a): pick the engine Nod thinks with, then sign in to it. Shown as
/// a sheet from the Welcome tour's agent page and from Settings › Agents › Nod.
struct NodSetupView: View {
  @Bindable var model: NodSetupModel
  var onDone: (() -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Set up Nod")
          .font(.system(size: 22, weight: .bold))
        Text(
          "GraphCode's built-in agent. Pick the engine it thinks with. You can switch later, "
            + "and existing loops keep the engine they started on."
        )
        .font(.system(size: 13))
        .foregroundStyle(.white.opacity(0.65))
        .fixedSize(horizontal: false, vertical: true)
      }

      HStack(alignment: .top, spacing: 10) {
        ForEach(NodEngine.allCases, id: \.self) { engine in
          NodEngineCard(
            engine: engine,
            isSelected: model.settings.engine == engine,
            isSignedIn: model.isSignedIn(engine)
          ) { model.selectEngine(engine) }
        }
      }
      .fixedSize(horizontal: false, vertical: true)

      VStack(alignment: .leading, spacing: 10) {
        Text("SIGN IN")
          .font(.system(size: 10, weight: .bold))
          .tracking(0.6)
          .foregroundStyle(.white.opacity(0.55))
        switch model.settings.engine {
        case .claudeAgentSDK: NodClaudeSignInSection(model: model)
        case .copilotSDK: NodCopilotSignInCard(model: model)
        }
      }

      Text(
        "Keys go in the macOS Keychain, not in ~/.graphcode. Nod reads the project's existing "
          + "CLAUDE.md, AGENTS.md and MCP config, so it starts out knowing what the CLIs know."
      )
      .font(.system(size: 11))
      .foregroundStyle(.white.opacity(0.55))
      .fixedSize(horizontal: false, vertical: true)

      if let onDone {
        HStack {
          Spacer()
          Button("Done", action: onDone)
            .keyboardShortcut(.defaultAction)
        }
      }
    }
    .padding(22)
    .frame(width: 520)
  }
}

struct NodEngineCard: View {
  let engine: NodEngine
  let isSelected: Bool
  let isSignedIn: Bool
  let select: () -> Void

  var body: some View {
    Button(action: select) {
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text(engine.displayName)
            .font(.system(size: 13, weight: .semibold))
          Spacer(minLength: 4)
          if isSignedIn {
            Image(systemName: "checkmark")
              .font(.system(size: 10.5, weight: .semibold))
              .foregroundStyle(NodSetupInk.ok)
              .help("Signed in")
          }
          Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(isSelected ? Theme.paneFocusTint : .white.opacity(0.25))
        }
        Text(Self.blurb(engine))
          .font(.system(size: 11.5))
          .foregroundStyle(.white.opacity(0.6))
          .fixedSize(horizontal: false, vertical: true)
        Text(NodModelCatalog.familySummary(for: engine))
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(.white.opacity(0.55))
          .padding(.top, 4)
      }
      .padding(13)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(
        isSelected ? Theme.paneFocusTint.opacity(0.1) : Color.white.opacity(0.03),
        in: RoundedRectangle(cornerRadius: 11)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 11)
          .stroke(
            isSelected ? Theme.paneFocusTint : .white.opacity(0.08),
            lineWidth: isSelected ? 1.5 : 1)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  static func blurb(_ engine: NodEngine) -> String {
    switch engine {
    case .claudeAgentSDK:
      return NodClaudeSignIn.subscriptionLoginAllowed
        ? "Claude models. Sign in with a Claude subscription or an Anthropic API key."
        : "Claude models. Sign in with an Anthropic API key."
    case .copilotSDK:
      return "Your Copilot plan's models, billed to that seat. Sign in with GitHub."
    }
  }
}

struct NodClaudeSignInSection: View {
  @Bindable var model: NodSetupModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if model.isSignedIn(.claudeAgentSDK) {
        NodSignedInRow(text: "Signed in with an Anthropic API key") {
          model.signOut(.claudeAgentSDK)
        }
      } else {
        HStack(spacing: 8) {
          if NodClaudeSignIn.subscriptionLoginAllowed {
            Button("Continue with Claude") {}
              .buttonStyle(.borderedProminent)
          }
          Button("Use an API key") { model.showsAPIKeyField = true }
        }
        if model.showsAPIKeyField {
          HStack(spacing: 8) {
            SecureField("sk-ant-…", text: $model.apiKeyDraft)
              .textFieldStyle(.roundedBorder)
              .onSubmit { model.saveAPIKey() }
            Button("Save") { model.saveAPIKey() }
          }
          if let error = model.apiKeyError {
            Text(error)
              .font(.system(size: 11))
              .foregroundStyle(NodSetupInk.warning)
          }
        }
        if model.claudeCodeSignInFound {
          HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(NodSetupInk.ok)
            Text("Found a Claude Code sign-in on this Mac. Use it for Nod too?")
              .font(.system(size: 12))
            Spacer(minLength: 4)
            Button("Use it") {}
          }
          .padding(10)
          .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        }
      }
    }
  }
}

/// Design 5b: the device code, Copy, the countdown, and the success state that replaces
/// the code once GitHub confirms.
struct NodCopilotSignInCard: View {
  @Bindable var model: NodSetupModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      switch model.copilotPhase {
      case .idle where model.canStartDeviceFlow:
        Button("Sign in to GitHub") { model.startCopilotSignIn() }
          .buttonStyle(.borderedProminent)
      case .idle:
        Text("Sign in with the Copilot CLI: run copilot login in a terminal, then check again.")
          .font(.system(size: 12))
          .foregroundStyle(.white.opacity(0.75))
          .textSelection(.enabled)
        Button("Check again") { model.refreshSignIn() }
      case .requesting:
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Asking GitHub for a code…").font(.system(size: 12))
        }
      case .waiting(let code):
        waiting(code)
      case .signedIn(let account):
        signedIn(account)
      case .failed(let message):
        Text(message)
          .font(.system(size: 12))
          .foregroundStyle(NodSetupInk.warning)
        Button("Try again") { model.startCopilotSignIn() }
      }
    }
  }

  private func waiting(_ code: CopilotDeviceFlow.DeviceCode) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(
        "We've opened \(code.verificationURL.host() ?? "github.com")\(code.verificationURL.path()). Enter this code there:"
      )
      .font(.system(size: 12))
      .foregroundStyle(.white.opacity(0.75))
      HStack(spacing: 12) {
        Text(code.userCode)
          .font(.system(size: 24, weight: .semibold, design: .monospaced))
          .tracking(2)
          .textSelection(.enabled)
        Button("Copy") { model.copyToPasteboard(code.userCode) }
      }
      .padding(.vertical, 10)
      .padding(.horizontal, 14)
      .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
      TimelineView(.periodic(from: .now, by: 1)) { context in
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text(
            "Waiting for GitHub… code expires in "
              + CopilotSignInText.countdown(until: code.expiresAt, now: context.date)
          )
          .font(.system(size: 11.5).monospacedDigit())
          .foregroundStyle(.white.opacity(0.6))
          Spacer(minLength: 4)
          Button("Cancel") { model.cancelCopilotSignIn() }
            .buttonStyle(.plain)
            .font(.system(size: 11.5))
            .foregroundStyle(.white.opacity(0.6))
        }
      }
    }
  }

  private func signedIn(_ account: CopilotDeviceFlow.Account?) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 16))
        .foregroundStyle(NodSetupInk.ok)
      VStack(alignment: .leading, spacing: 3) {
        Text(
          model.usesCopilotCLISignIn
            ? "Using your Copilot CLI sign-in"
            : [
              account.map { "Signed in as \($0.login)" } ?? "Signed in to GitHub",
              account?.planName,
            ]
            .compactMap { $0 }.joined(separator: " · ")
        )
        .font(.system(size: 12.5, weight: .medium))
        if let account, !CopilotSignInText.accountDetail(account).isEmpty {
          Text(CopilotSignInText.accountDetail(account))
            .font(.system(size: 11.5))
            .foregroundStyle(.white.opacity(0.6))
        }
      }
      Spacer(minLength: 4)
      if !model.usesCopilotCLISignIn {
        Button("Sign out") { model.signOut(.copilotSDK) }
      }
    }
    .padding(10)
    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
  }
}

struct NodSignedInRow: View {
  let text: String
  let signOut: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "checkmark.circle.fill").foregroundStyle(NodSetupInk.ok)
      Text(text).font(.system(size: 12.5))
      Spacer(minLength: 4)
      Button("Sign out", action: signOut)
    }
  }
}

enum NodSetupInk {
  static let ok = Color(red: 0.494, green: 0.894, blue: 0.608)
  static let warning = Color(red: 1.0, green: 0.804, blue: 0.478)
}
