import Foundation
import Testing

@testable import GraphcodeKit
@testable import graphcode

/// The naming rules for backend-suggested loop titles: at most two precise words, and
/// never a name any open project — local folder, remote repository, or the Graph —
/// already shows.
@Suite
struct TitleSuggestionTests {
  @Test
  func aNameIsAtMostTwoCleanWords() {
    #expect(TitleSuggestionClient.sanitize("Research") == "Research")
    #expect(TitleSuggestionClient.sanitize("Database Migration") == "Database Migration")
    #expect(TitleSuggestionClient.sanitize("Fix flaky login tests") == "Fix flaky")
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
  func aTakenNameIsRefusedWhateverItsCase() {
    #expect(TitleSuggestionClient.accept("Deploy", taken: ["deploy"]) == nil)
    #expect(TitleSuggestionClient.accept("Deploy", taken: ["Research"]) == "Deploy")
    #expect(
      TitleSuggestionClient.accept("Database Migration", taken: ["database migration"]) == nil)
  }

  @Test
  func theInstructionAsksForOneOrTwoWordsAndListsTakenNames() {
    let instruction = TitleSuggestionClient.instruction(
      for: "fix the build", taken: ["Deploy", "Research"])
    #expect(instruction.contains("one or two words"))
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
