import Foundation

/// One post on a Mailboard — the shared, unaddressed message board a graph of loops
/// writes to and reads without wiring anything: `node send` and edges are addressed
/// (a sender must already know a target's id, and the daemon routes to that one peer),
/// while the Mailboard is the ambient counterpart. A loop drops a note for *whoever
/// comes next* — a decision made, a dead end hit, a claim staked — and any other loop,
/// present or created after the author is gone, discovers it with one command. Posts
/// survive their authors: they live on the graph itself, outlasting resolution,
/// deletion's siblings, and the daemon's own restarts.
///
/// Small on purpose. A post is a note to a peer, not a transcript — the same bargain
/// `NodeMemory`'s 512-byte log entries strike — and the caps below are what keep a
/// wake digest's advice to "check the board" from costing a loop its context budget.
public struct MailboardPost: Codable, Equatable, Identifiable, Sendable {
  /// Position in the board's sequence, 1-based. The unread cursor is this number, so
  /// ids must only ever grow — they are assigned by `GraphStore` from the current
  /// maximum, never from the post count, which pruning would shrink.
  public let id: Int
  public let at: Date
  /// The posting loop's node id, when a loop posted it. `nil` from a human's shell
  /// (`$ZMX_SESSION` absent), which is how a person talks to the whole graph at once.
  public let authorID: UUID?
  /// The author's loop title, or "a human" — what a reader sees; the id above is
  /// what it uses to reply in person with `node send`.
  public let author: String
  /// An optional label for threads that keep themselves together — `auth`, `build`,
  /// `issues`. A watcher subscribed to a topic only hears matching posts; `nil` posts
  /// reach watchers of every topic except the ones that asked for another.
  public let topic: String?
  public let body: String

  public init(
    id: Int, at: Date, authorID: UUID?, author: String, topic: String?, body: String
  ) {
    self.id = id
    self.at = at
    self.authorID = authorID
    self.author = author
    self.topic = topic
    self.body = body
  }

  /// The bound that keeps "check the board" cheap. A note that cannot fit in a
  /// kilobyte is a document — put it in the repo and post the path.
  public static let maxBodyBytes = 1024
  public static let maxTopicBytes = 64
}

/// A loop's standing subscription to its project's Mailboard — what turns the board
/// from something a loop must remember to poll into a mailbox that rings. `topic`
/// `nil` hears every post; a topic hears only posts labelled the same way.
public struct MailboardWatch: Codable, Equatable, Sendable {
  public var topic: String?

  public init(topic: String? = nil) { self.topic = topic }

  public func matches(_ topic: String?) -> Bool { self.topic == nil || self.topic == topic }
}

/// The board's own rules — the arithmetic every surface shares rather than
/// re-derives, so the CLI's unread count and the daemon's cursor can never disagree.
public enum Mailboard {
  /// How many posts a board keeps. The oldest fall off first: a Mailboard is a
  /// mailbox for the work that is happening, not an archive — a loop's durable
  /// findings belong in its memory log, and the board's job is carrying them to
  /// loops that cannot read that log.
  public static let maxPosts = 200

  /// The id the next post gets. Maximum-plus-one, never count-plus-one: pruning
  /// removes the oldest posts, and reusing their ids would make unread cursors
  /// mistake old mail for new.
  public static func nextID(after posts: [MailboardPost]) -> Int {
    (posts.map(\.id).max() ?? 0) + 1
  }

  /// The posts a loop with `lastRead` on its cursor has not seen yet.
  public static func unread(
    in posts: [MailboardPost], since lastRead: Int?
  ) -> [MailboardPost] {
    guard let lastRead else { return posts }
    return posts.filter { $0.id > lastRead }
  }

  /// A board that grew past `maxPosts`, oldest first gone. Applied by the store on
  /// every post so no caller can forget.
  public static func pruned(_ posts: [MailboardPost]) -> [MailboardPost] {
    guard posts.count > maxPosts else { return posts }
    return Array(posts.suffix(maxPosts))
  }
}
