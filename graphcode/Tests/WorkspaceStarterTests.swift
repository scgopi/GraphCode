import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

/// The one question a new workspace asks, and the switcher rows that say what is in each.
@Suite
struct WorkspaceStarterTests {
  private func makeHome() -> URL {
    let home = URL(fileURLWithPath: "/tmp")
      .appendingPathComponent("gcs-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
  }

  @Test
  func aNewWorkspaceCarriesTheSuggestionOfTheOneThatMadeIt() throws {
    let home = makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let workspace = try Workspace.create(name: "work", home: home)

    #expect(WorkspaceStarter.pending(workspace) == nil)

    WorkspaceStarter.invite(workspace, suggesting: .codex)
    #expect(WorkspaceStarter.pending(workspace)?.suggestedBackend == .codex)

    // Answered — by choosing or by skipping — and it does not come back.
    WorkspaceStarter.clear(workspace)
    #expect(WorkspaceStarter.pending(workspace) == nil)
  }

  @Test
  func theDefaultWorkspaceIsNeverInvited() {
    // It is configured by the tour, and an install upgrading into this feature must not
    // be interrogated about a workspace it has been using for months.
    WorkspaceStarter.invite(.default, suggesting: .codex)
    #expect(WorkspaceStarter.pending(.default) == nil)
    #expect(
      !FileManager.default.fileExists(
        atPath: Workspace.default.url.appendingPathComponent("starter.json").path))
  }

  @Test
  @MainActor
  func pickingAnAgentAppliesItImmediatelyAndSkippingStillAnswers() async {
    let applied = LockIsolated<[CLISessionBackendKind]>([])
    let finished = LockIsolated(0)
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.workspaceClient.starterInvitation = {
        WorkspaceStarter.Invitation(suggestedBackend: .copilotCLI)
      }
      $0.workspaceClient.applyDefaultBackend = { backend in
        applied.withValue { $0.append(backend) }
      }
      $0.workspaceClient.finishStarter = { finished.withValue { $0 += 1 } }
    }
    store.exhaustivity = .off

    await store.send(.workspaces(.starterChecked))
    // Preselected from the invitation, not from the built-in default.
    #expect(store.state.workspaces.starterBackend == .copilotCLI)
    #expect(store.state.workspaces.starter != nil)

    await store.send(.workspaces(.starterBackendPicked(.codex)))
    // Applied on the pick, like the tour's page — there is no Save on this dialog.
    #expect(applied.value == [.codex])

    await store.send(.workspaces(.starterDismissed))
    #expect(store.state.workspaces.starter == nil)
    #expect(finished.value == 1)
    // Dismissal re-applies what is on screen — idempotent here, load-bearing in the
    // untapped case below.
    #expect(applied.value == [.codex, .codex])
  }

  @Test
  @MainActor
  func startWorkingOverThePreselectionAppliesIt() async {
    // The reported bug: the starter opened with Copilot preselected — a filled
    // checkmark — and Start Working was pressed with no tap. Nothing was written, and
    // the workspace ran on the built-in default while Settings said Claude Code.
    // Tapping two rows in a row worked, because only taps applied. The dialog's exit
    // applies whatever is selected now, so the checkmark is the answer.
    let applied = LockIsolated<[CLISessionBackendKind]>([])
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.workspaceClient.starterInvitation = {
        WorkspaceStarter.Invitation(suggestedBackend: .copilotCLI)
      }
      $0.workspaceClient.applyDefaultBackend = { backend in
        applied.withValue { $0.append(backend) }
      }
      $0.workspaceClient.finishStarter = {}
    }
    store.exhaustivity = .off

    await store.send(.workspaces(.starterChecked))
    await store.send(.workspaces(.starterDismissed))
    #expect(applied.value == [.copilotCLI])

    // Answered is answered: a second dismissal (a late sheet callback, say) must not
    // write again.
    await store.send(.workspaces(.starterDismissed))
    #expect(applied.value == [.copilotCLI])
  }

  @Test
  @MainActor
  func aWorkspaceWithNoInvitationRaisesNothing() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.workspaceClient.starterInvitation = { nil }
    }

    // No state change at all: every workspace made before this shipped is treated as
    // already answered.
    await store.send(.workspaces(.starterChecked))
  }

  @Test
  func aSwitcherRowSaysWhatIsInTheWorkspaceAndWhetherAWindowHasIt() {
    let open = Workspace.Summary(projects: 2, loops: 7, isOpen: true)
    let closed = Workspace.Summary(projects: 1, loops: 1, isOpen: false)

    #expect(WorkspaceSwitcherPanel.subtitle(open, isCurrent: false) == "7 loops · open")
    #expect(WorkspaceSwitcherPanel.subtitle(open, isCurrent: true) == "7 loops · this window")
    // "not running" is worth naming: switching there launches an instance.
    #expect(WorkspaceSwitcherPanel.subtitle(closed, isCurrent: false) == "1 loop · not running")
    #expect(WorkspaceSwitcherPanel.subtitle(nil, isCurrent: true) == "this window")
  }

  @Test
  func aWorkspacesDotKeepsItsColourWhenTheListReorders() {
    // Hashed from the slug rather than assigned by position — a list that gains a
    // workspace must not repaint every dot.
    let work = Workspace(slug: "work", url: URL(fileURLWithPath: "/tmp/.graphcode-work"))
    let same = Workspace(slug: "work", url: URL(fileURLWithPath: "/tmp/.graphcode-work"))
    #expect(WorkspaceSwitcherPanel.tint(for: work) == WorkspaceSwitcherPanel.tint(for: same))
    #expect(WorkspaceSwitcherPanel.tint(for: .default) == Theme.paneFocusTint)
  }

  @Test
  func aRowThatCannotBeActedOnSaysWhyInThreeWords() {
    // On the row, rather than as an alert after the click.
    #expect(ManageWorkspacesView.reason(.isDefault(.delete)) == "the default")
    #expect(ManageWorkspacesView.reason(.isCurrent(.rename)) == "this window")
    #expect(ManageWorkspacesView.reason(.isOpen(pid: 42, .delete)) == "open elsewhere")
  }
}
