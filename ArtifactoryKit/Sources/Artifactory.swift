import Foundation

/// One post on an Artifactory — the shared, unaddressed message board a graph of loops
/// writes to and reads without wiring anything: `node send` and edges are addressed
/// (a sender must already know a target's id, and the daemon routes to that one peer),
/// while the Artifactory is the ambient counterpart. A loop drops a note for *whoever
/// comes next* — a decision made, a dead end hit, a claim staked — and any other loop,
/// present or created after the author is gone, discovers it with one command. Posts
/// survive their authors: they live on the graph itself, outlasting resolution, the
/// author's deletion, and the daemon's own restarts.
///
/// Small on purpose. A post is a note to a peer, not a transcript — the same bargain
/// `NodeMemory`'s 512-byte log entries strike — and the caps below are what keep a
/// wake digest's advice to "check the board" from costing a loop its context budget.
public struct ArtifactoryPost: Codable, Equatable, Identifiable, Sendable {
  /// What kind of traffic a post is, which is what decides *whose* budget prunes it.
  ///
  /// The two share a board and nothing else. A note is somebody choosing to tell the
  /// graph something; a record is the board keeping the receipt for a message that was
  /// already delivered elsewhere. They were pruned from one pool once, and a graph that
  /// merely *talked* — two hundred `node send`s, which a ten-way fanout reaches without
  /// trying — evicted every note on it. Separate budgets are the fix: chatter can fill
  /// its own quota to the brim and never touch a note.
  public enum Kind: String, Codable, Sendable {
    /// Somebody posted this on purpose (`graphcode artifactory post`).
    case note
    /// The board's mirror of a delivered direct message or handoff.
    case record
  }

  /// Position in the board's sequence, 1-based. The unread cursor is this number, so
  /// ids must only ever grow — they are assigned by `GraphStore` from the current
  /// maximum, never from the post count, which pruning would shrink.
  public let id: Int
  public let at: Date
  /// The posting loop's node id, when a loop posted it. `nil` from a human's shell
  /// (`$ZMX_SESSION` absent), which is how a person talks to the whole graph at once,
  /// and `nil` again once the authoring loop is deleted — the note stays, the handle
  /// to reply to it does not.
  ///
  /// Derived from the caller's environment, so it is an attribution and not an
  /// authentication: anything that can reach the daemon socket can claim any identity
  /// here, exactly as it can for `node send` and `node memo`. Closing that would take
  /// peer credentials on the socket, which no graphcode surface has yet.
  public let authorID: UUID?
  /// The author's loop title, or "a human" — what a reader sees; the id above is
  /// what it uses to reply in person with `node send`.
  public let author: String
  /// An optional label for threads that keep themselves together — `auth`, `build`,
  /// `issues`. A watcher subscribed to a topic only hears posts labelled exactly that
  /// way; a watcher with no topic hears everything.
  public let topic: String?
  public let body: String
  /// Which budget prunes this post. Absent from graphs saved before records had their
  /// own quota, where everything on the board was a note.
  public let kind: Kind

  /// Whether a loop *wrote* this, or the board is only noting that a delivery happened.
  ///
  /// A separate axis from `kind` on purpose, and the two were conflated once. `kind`
  /// answers "whose budget prunes this" — mirrored traffic must have its own quota or a
  /// talkative graph evicts every note. It was also read as "is there anything in here
  /// to read", which it never was: `node send` mirrors as a `.record` because that is
  /// the budget it belongs to, and the whole text a loop typed rode along inside it.
  /// Every surface then folded it away, so two loops correcting each other's diagnosis
  /// held the conversation somewhere no supervisor ever looked (#273).
  ///
  /// A hand-off nudge carrying no payload really is a receipt. The text of a `node send`
  /// is not, and this is the bit that says so.
  ///
  /// Absent from boards saved before the split, where a record was only ever a receipt —
  /// which is also why it rides beside `kind` rather than becoming a third case of it:
  /// an older build decoding a newer board must not meet a raw value it has never heard
  /// of, and losing a project's whole graph to a rolled-back beta is a steep price for a
  /// tidier enum.
  public let wasWritten: Bool

  /// Cached formatter for CLI rendering — one `DateFormatter` per process rather than
  /// per post, and a fixed `dateFormat` with a pinned locale rather than
  /// `Date.formatted` or named `DateFormatter.Style` cases, neither of which is
  /// something to find out about from the Linux CI toolchains.
  public static let stampFormat: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM d, HH:mm"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
  }()

  /// `wasWritten` defaults to what the kind implies: a note is always somebody speaking,
  /// and a record is a receipt unless its caller says otherwise.
  public init(
    id: Int, at: Date, authorID: UUID?, author: String, topic: String?, body: String,
    kind: Kind = .note, wasWritten: Bool? = nil
  ) {
    self.id = id
    self.at = at
    self.authorID = authorID
    self.author = author
    self.topic = topic
    self.body = body
    self.kind = kind
    self.wasWritten = wasWritten ?? (kind == .note)
  }

  private enum CodingKeys: String, CodingKey {
    case id, at, authorID, author, topic, body, kind, wasWritten
  }

  /// Hand-written for the reason `LoopNode`'s is: a board saved before `kind` existed
  /// must decode rather than take the whole graph down with it, and everything on such
  /// a board was posted deliberately.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(Int.self, forKey: .id)
    at = try container.decode(Date.self, forKey: .at)
    authorID = try container.decodeIfPresent(UUID.self, forKey: .authorID)
    author = try container.decode(String.self, forKey: .author)
    topic = try container.decodeIfPresent(String.self, forKey: .topic)
    kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .note
    let body = try container.decode(String.self, forKey: .body)
    self.body = body
    wasWritten =
      try container.decodeIfPresent(Bool.self, forKey: .wasWritten)
      ?? (kind == .note || !Artifactory.readsAsADeliveryReceipt(body))
  }

  /// The same post with its author's handle gone — what deleting a loop leaves behind.
  ///
  /// A note is addressed to *other* loops, so erasing it on delete retracts something
  /// peers may already have acted on, which is the one thing an append-only board must
  /// not do. What the delete does take is the handle: `authorID` goes, so nothing can
  /// address a loop that no longer exists, and the byline says plainly that it is gone.
  public func withAuthorDeleted() -> ArtifactoryPost {
    ArtifactoryPost(
      id: id, at: at, authorID: nil, author: "\(author) (deleted)", topic: topic,
      body: body, kind: kind, wasWritten: wasWritten)
  }

  /// The bound that keeps "check the board" cheap. A note that cannot fit in a
  /// kilobyte is a document — put it in the repo and post the path.
  public static let maxBodyBytes = 1024
  public static let maxTopicBytes = 64
}

/// A loop's standing subscription to its project's Artifactory — what turns the board
/// from something a loop must remember to poll into a mailbox that rings. `topic`
/// `nil` hears every post; a topic hears only posts labelled the same way.
public struct ArtifactoryWatch: Codable, Equatable, Sendable {
  public var topic: String?

  public init(topic: String? = nil) { self.topic = topic }

  public func matches(_ topic: String?) -> Bool { self.topic == nil || self.topic == topic }
}

/// The board's own rules — the arithmetic every surface shares rather than
/// re-derives, so the CLI's unread count and the daemon's cursor can never disagree.
public enum Artifactory {
  /// How many *notes* a board keeps. The oldest fall off first: an Artifactory is a
  /// mailbox for the work that is happening, not an archive — a loop's durable
  /// findings belong in its memory log, and the board's job is carrying them to
  /// loops that cannot read that log.
  public static let maxNotes = 200

  /// How many mirrored records a board keeps, pruned entirely separately from the
  /// notes. Smaller because a record is a receipt for something already delivered:
  /// enough that a loop joining mid-flight can see what was recently said, not so
  /// many that the graph's chatter becomes the board.
  public static let maxRecords = 50

  /// Whether a record saved before `wasWritten` existed is one of the two lines the
  /// daemon generates itself, rather than something a loop said.
  ///
  /// Boards written before the split carry no flag, and a default of "receipt" would
  /// leave every conversation already on them exactly as buried as #273 found it — a
  /// fix that only helps graphs created after it shipped. There is no other signal left
  /// on those posts, so this reads the two shapes the mirror produces when an edge fires
  /// with nothing in it (`MessageBus.messageText`'s `.none`, and a hand-off with no
  /// payload). Everything else on those topics is a `node send` or a payload, which is
  /// somebody talking.
  ///
  /// Deliberately narrow. A written message that happens to end "… finished." is read as
  /// a receipt and stays folded, which is where it already was; the opposite mistake
  /// would put the daemon's own bookkeeping in front of a reader as though a loop had
  /// said it. Only posts decoded without the flag are ever asked.
  public static func readsAsADeliveryReceipt(_ body: String) -> Bool {
    body.hasSuffix(" finished.")
      || body.hasSuffix(" finished and handed its work off to you.")
  }

  /// The id the next post gets. Maximum-plus-one, never count-plus-one: pruning
  /// removes the oldest posts, and reusing their ids would make unread cursors
  /// mistake old mail for new.
  public static func nextID(after posts: [ArtifactoryPost]) -> Int {
    (posts.map(\.id).max() ?? 0) + 1
  }

  /// Past this many unread posts, or this many bytes of them, `sync` triages itself
  /// down to one line per post rather than printing every body.
  ///
  /// The pair `sync --headlines` / `read <id>` already existed, but choosing between
  /// them is a decision a loop cannot make: it learns how much mail it has by reading
  /// it, and a loop created after a busy week inherits the whole board on its first
  /// sync — measured at 200 notes, that is ~180 KB, or something like 45,000 tokens
  /// spent before the loop has done anything. So the verb decides, and says which
  /// way it went; `--full` overrides for a caller that really does want every body.
  public static let triageAfterPosts = 12
  public static let triageAfterBytes = 4096

  /// Whether this many posts is more than a loop should be handed in full.
  public static func needsTriage(_ posts: [ArtifactoryPost]) -> Bool {
    posts.count > triageAfterPosts
      || posts.reduce(0) { $0 + $1.body.utf8.count } > triageAfterBytes
  }

  /// The posts a loop with `lastRead` on its cursor has not seen yet.
  public static func unread(
    in posts: [ArtifactoryPost], since lastRead: Int?
  ) -> [ArtifactoryPost] {
    guard let lastRead else { return posts }
    return posts.filter { $0.id > lastRead }
  }

  /// A board pruned to both budgets, oldest of each kind gone first and the survivors
  /// back in one sequence. Applied by the store on every write so no caller can forget.
  public static func pruned(_ posts: [ArtifactoryPost]) -> [ArtifactoryPost] {
    let notes = posts.filter { $0.kind == .note }
    let records = posts.filter { $0.kind == .record }
    guard notes.count > maxNotes || records.count > maxRecords else { return posts }
    let kept = Set(
      (notes.suffix(maxNotes) + records.suffix(maxRecords)).map(\.id))
    return posts.filter { kept.contains($0.id) }
  }
}
