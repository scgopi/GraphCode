import Foundation
import Testing

@testable import GraphcodeKit
@testable import graphcode

/// The naming rules for backend-suggested loop titles: one precise word — two concepts
/// folded into CamelCase rather than split — and never a name any open project — local
/// folder, remote repository, or the Graph — already shows.
@Suite
struct TitleSuggestionTests {
  @Test
  func aNameIsOneCleanWord() {
    #expect(TitleSuggestionClient.sanitize("Research") == "Research")
    #expect(TitleSuggestionClient.sanitize("Database Migration") == "DatabaseMigration")
    #expect(TitleSuggestionClient.sanitize("GraphCode Templates") == "GraphCodeTemplates")
    #expect(TitleSuggestionClient.sanitize("Fix flaky login tests") == "FixFlaky")
    #expect(TitleSuggestionClient.sanitize("deploy") == "Deploy")
    #expect(TitleSuggestionClient.sanitize("\"Deploy!\"") == "Deploy")
    #expect(TitleSuggestionClient.sanitize("") == nil)
    #expect(TitleSuggestionClient.sanitize("   \n  ") == nil)
  }

  @Test
  func theAnswerIsTheLastNonEmptyLine() {
    // `codex exec` wraps its answer in log lines; any model can get chatty.
    #expect(
      TitleSuggestionClient.sanitize("[2026-08-12] model: gpt\nthinking...\nRefactor\n")
        == "Refactor")
  }

  @Test
  func codexTitleSuggestionsRunWithoutAnApprovalPrompt() throws {
    let invocation = try #require(TitleSuggestionClient.invocation(for: .codex))
    let command = try #require(invocation.last)
    #expect(command.contains("codex exec --dangerously-bypass-approvals-and-sandbox"))
  }

  @Test
  func aTakenNameIsRefusedWhateverItsCase() {
    #expect(TitleSuggestionClient.accept("Deploy", taken: ["deploy"]) == nil)
    #expect(TitleSuggestionClient.accept("Deploy", taken: ["Research"]) == "Deploy")
    #expect(
      TitleSuggestionClient.accept("DatabaseMigration", taken: ["databasemigration"]) == nil)
  }

  @Test
  func theInstructionAsksForOneWordAndListsTakenNames() {
    let instruction = TitleSuggestionClient.instruction(
      for: "fix the build", taken: ["Deploy", "Research"])
    #expect(instruction.contains("as a single word"))
    #expect(instruction.contains("join them in CamelCase"))
    #expect(!instruction.contains("two words"))
    #expect(instruction.contains("Deploy, Research"))
    #expect(instruction.contains("fix the build"))
    let bare = TitleSuggestionClient.instruction(for: "fix the build", taken: [])
    #expect(!bare.contains("already taken"))
  }

  @Test
  func theDirectoryCollectsTitlesAcrossProjectsAndSubgraphs() {
    let child = LoopNode(title: "Child")
    let composite = LoopNode(
      title: "Composite",
      subGraph: LoopGraph(
        project: ProjectRef(path: "/tmp/sub", name: "sub"), nodes: [child]))
    let local = LoopGraph(project: ProjectRef(path: "/tmp/a", name: "a"), nodes: [composite])
    let remote = LoopGraph(
      project: ProjectRef(path: "ssh://dev@host/w", name: "w"),
      nodes: [LoopNode(title: "Deploy")])
    let directory = LoopTitleDirectory.liveValue
    directory.register(local.project.path, local)
    directory.register(remote.project.path, remote)
    let titles = directory.allTitles()
    #expect(titles.isSuperset(of: ["Composite", "Child", "Deploy"]))
  }
}
