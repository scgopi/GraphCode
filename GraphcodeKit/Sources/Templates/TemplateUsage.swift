import Foundation

/// How many loops a template is answerable for — the number behind the template
/// editor's load-bearing line (PROMPT_TEMPLATES.md § Follow vs snapshot):
///
/// > "3 scheduled loops use this — they'll pick up changes on their next run."
///
/// The design calls that line load-bearing rather than decorative, and it is: a
/// committed edit to a project template changes what runs on a teammate's machine,
/// so the person editing has to be told how far the edit reaches *before* they save.
///
/// Two counts, because they are two different promises:
/// - `following` — timed and composite loops that re-read the file on their next
///   run. Editing the body changes what these do. This is the number in the line.
/// - `snapshots` — main, goal and turn loops created from it, which took a copy at
///   creation and are untouched by any edit. Counted so the editor can say the edit
///   *won't* reach them rather than leaving it ambiguous.
public struct TemplateUsage: Equatable, Sendable {
  public var following: Int
  public var snapshots: Int

  public init(following: Int = 0, snapshots: Int = 0) {
    self.following = following
    self.snapshots = snapshots
  }

  public var isEmpty: Bool { following == 0 && snapshots == 0 }

  /// The design's own sentence, or `nil` when nothing follows this template and
  /// there is nothing load-bearing to say.
  public var followingLine: String? {
    switch following {
    case 0: return nil
    case 1: return "1 scheduled loop uses this — it'll pick up changes on its next run."
    default:
      return "\(following) scheduled loops use this — they'll pick up changes on their next run."
    }
  }

  /// The other half, for the loops an edit will *not* reach. Stated so "3 loops use
  /// this" is never read as "and the other four change too".
  public var snapshotLine: String? {
    switch snapshots {
    case 0: return nil
    case 1: return "1 loop started from it and keeps the brief it was created with."
    default: return "\(snapshots) loops started from it and keep the brief they were created with."
    }
  }

  /// Counts across every graph handed in — the app passes every project it knows
  /// about, because a template in `~/.graphcode/templates` is offered in all of them
  /// and its reach is not one project's business.
  ///
  /// Composites are searched at any depth: a following loop inside a composite's
  /// sub-graph re-reads its template exactly like a top-level one.
  public static func of(_ templateID: UUID, in graphs: [LoopGraph]) -> TemplateUsage {
    var usage = TemplateUsage()
    for graph in graphs {
      for node in graph.nodesAtAnyDepth {
        if node.templateFollow?.id == templateID {
          usage.following += 1
        } else if node.createdFromTemplateID == templateID {
          usage.snapshots += 1
        }
      }
    }
    return usage
  }
}
