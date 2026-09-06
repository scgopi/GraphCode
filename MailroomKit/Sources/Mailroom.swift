import Foundation

/// One post on a Mailroom — the shared, unaddressed message board a graph of loops
/// writes to and reads without wiring anything: `node send` and edges are addressed
/// (a sender must already know a target's id, and the daemon routes to that one peer),
/// while the Mailroom is the ambient counterpart. A loop drops a note for *whoever
/// comes next* — a decision made, a dead end hit, a claim staked — and any other loop,
/// present or created after the author is gone, discovers it with one command. Posts
/// survive their authors: they live on the graph itself, outlasting resolution, the
/// author's deletion, and the daemon's own restarts.
///
/// Small on purpose. A post is a note to a peer, not a transcript — the same bargain
/// `NodeMemory`'s 512-byte log entries strike — and the caps below are what keep a
/// wake digest's advice to "check the board" from costing a loop its context budget.
public struct MailroomPost: Codable, Equatable, Identifiable, Sendable {
  /// What kind of traffic a post is, which is what decides *whose* budget prunes it.
  ///
  /// The two share a board and nothing else. A note is somebody choosing to tell the
  /// graph something; a record is the board keeping the receipt for a message that was
  /// already delivered elsewhere. They were pruned from one pool once, and a graph that
  /// merely *talked* — two hundred `node send`s, which a ten-way fanout reaches without
  /// trying — evicted every note on it. Separate budgets are the fix: chatter can fill
  /// its own quota to the brim and never touch a note.
  public enum Kind: String, Codable, Sendable {
    /// Somebody posted this on purpose — addressed to nobody, which is the whole of
    /// what separates it from a letter.
    case notice
    /// The room's copy of a direct message or handoff that was delivered elsewhere.
    case letter

    /// Boards written before the mail vocabulary spell these `note` and `record`. An
    /// unrecognised kind reads as a notice rather than throwing: `ProjectPersistence`
    /// turns any decode failure into "no saved graph", so a strict reading here would
    /// trade one unknown post for every post on the board.
    public init(from decoder: Decoder) throws {
      switch try decoder.singleValueContainer().decode(String.self) {
      case "letter", "record": self = .letter
      default: self = .notice
      }
    }
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

  public init(
    id: Int, at: Date, authorID: UUID?, author: String, topic: String?, body: String,
    kind: Kind = .notice
  ) {
    self.id = id
    self.at = at
    self.authorID = authorID
    self.author = author
    self.topic = topic
    self.body = body
    self.kind = kind
  }

  private enum CodingKeys: String, CodingKey {
    case id, at, authorID, author, topic, body, kind
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
    body = try container.decode(String.self, forKey: .body)
    kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .notice
  }

  /// The same post with its author's handle gone — what deleting a loop leaves behind.
  ///
  /// A note is addressed to *other* loops, so erasing it on delete retracts something
  /// peers may already have acted on, which is the one thing an append-only board must
  /// not do. What the delete does take is the handle: `authorID` goes, so nothing can
  /// address a loop that no longer exists, and the byline says plainly that it is gone.
  public func withAuthorDeleted() -> MailroomPost {
    MailroomPost(
      id: id, at: at, authorID: nil, author: "\(author) (deleted)", topic: topic,
      body: body, kind: kind)
  }

  /// The bound that keeps "check the board" cheap. A note that cannot fit in a
  /// kilobyte is a document — put it in the repo and post the path.
  public static let maxBodyBytes = 1024
  public static let maxTopicBytes = 64
}

/// A loop's standing subscription to its project's Mailroom — what turns the board
/// from something a loop must remember to poll into a mailbox that rings. `topic`
/// `nil` hears every post; a topic hears only posts labelled the same way.
public struct MailroomWatch: Codable, Equatable, Sendable {
  public var topic: String?

  public init(topic: String? = nil) { self.topic = topic }

  public func matches(_ topic: String?) -> Bool { self.topic == nil || self.topic == topic }
}

/// The board's own rules — the arithmetic every surface shares rather than
/// re-derives, so the CLI's unread count and the daemon's cursor can never disagree.
public enum Mailroom {
  /// How many *notices* a room keeps. The oldest fall off first: a Mailroom carries
  /// the work that is happening, it is not an archive — a loop's durable findings
  /// belong in its memory log, and the room's job is carrying them to loops that
  /// cannot read that log.
  public static let maxNotices = 200

  /// How many *letters* a room keeps, pruned entirely separately from the notices.
  ///
  /// Was 50, on the reading that a letter is a mere receipt for something already
  /// delivered. That undersold it: correspondence is half of what the room is for,
  /// and a ten-way fanout spends 50 slots in a single pass — so the loop that joins
  /// afterwards finds the graph's history already evicted, which is the failure the
  /// separate budgets existed to prevent. Level with the notices, and pruned apart
  /// from them, so neither kind of traffic can crowd the other out.
  public static let maxLetters = 200

  /// The id the next post gets. Maximum-plus-one, never count-plus-one: pruning
  /// removes the oldest posts, and reusing their ids would make unread cursors
  /// mistake old mail for new.
  public static func nextID(after posts: [MailroomPost]) -> Int {
    (posts.map(\.id).max() ?? 0) + 1
  }

  /// Past this many unread posts, or this many bytes of them, `sync` triages itself
  /// down to one line per post rather than printing every body.
  ///
  /// The pair `sync --headlines` / `read <id>` already existed, but choosing between
  /// them is a decision a loop cannot make: it learns how much mail it has by reading
  /// it, and a loop created after a busy week inherits the whole board on its first
  /// sync — measured at 200 notices, that is ~180 KB, or something like 45,000 tokens
  /// spent before the loop has done anything. So the verb decides, and says which
  /// way it went; `--full` overrides for a caller that really does want every body.
  public static let triageAfterPosts = 12
  public static let triageAfterBytes = 4096

  /// Whether this many posts is more than a loop should be handed in full.
  public static func needsTriage(_ posts: [MailroomPost]) -> Bool {
    posts.count > triageAfterPosts
      || posts.reduce(0) { $0 + $1.body.utf8.count } > triageAfterBytes
  }

  /// The posts a loop with `lastRead` on its cursor has not seen yet.
  public static func unread(
    in posts: [MailroomPost], since lastRead: Int?
  ) -> [MailroomPost] {
    guard let lastRead else { return posts }
    return posts.filter { $0.id > lastRead }
  }

  /// A board pruned to both budgets, oldest of each kind gone first and the survivors
  /// back in one sequence. Applied by the store on every write so no caller can forget.
  public static func pruned(_ posts: [MailroomPost]) -> [MailroomPost] {
    let notices = posts.filter { $0.kind == .notice }
    let letters = posts.filter { $0.kind == .letter }
    guard notices.count > maxNotices || letters.count > maxLetters else { return posts }
    let kept = Set(
      (notices.suffix(maxNotices) + letters.suffix(maxLetters)).map(\.id))
    return posts.filter { kept.contains($0.id) }
  }
}

/// What a graph snapshot says about the room in place of the room itself.
///
/// The posts used to ride every `.graphChanged`, and on a busy graph they were three
/// quarters of every frame — 133 KB of a 176 KB broadcast, re-sent to every client on
/// every presence tick, to clients that already had them and clients that never read
/// mail at all (issue #288). A snapshot now carries only this: enough for `status` to
/// say there is mail, for a poster to learn its sequence number, and for a client
/// holding a copy of the room to know whether that copy is stale. The posts themselves
/// are served on request, bounded, by `Mailroom.serve`.
public struct MailroomDigest: Codable, Equatable, Sendable {
  public var count: Int
  /// The highest id on the room, `0` while empty.
  public var latestID: Int
  /// Changes whenever a post is added, pruned, or edited in place — the one in-place
  /// edit being an author's deletion, which `count` and `latestID` cannot see. Stable
  /// across processes (FNV-1a over the fields that can change), so two daemons
  /// describing the same room agree and a client can compare digests from before and
  /// after a restart.
  public var fingerprint: UInt64

  public init(count: Int, latestID: Int, fingerprint: UInt64) {
    self.count = count
    self.latestID = latestID
    self.fingerprint = fingerprint
  }

  public init(of posts: [MailroomPost]) {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    func mix(_ text: String) {
      for byte in text.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01b3
      }
      hash ^= 0xff
      hash = hash &* 0x0000_0100_0000_01b3
    }
    for post in posts {
      mix(String(post.id))
      mix(post.authorID?.uuidString ?? "")
      mix(post.author)
    }
    self.init(count: posts.count, latestID: posts.last?.id ?? 0, fingerprint: hash)
  }

  public var isEmpty: Bool { count == 0 }
}

/// What a client asks the room for — the read half of every mail verb.
public struct MailboxQuery: Codable, Equatable, Sendable {
  public enum Selection: Codable, Equatable, Sendable {
    /// The whole room — `mail list`, a human's window.
    case board
    /// Only what `reader`'s cursor has not covered — `mail inbox`.
    case unread(reader: UUID)
    /// One post in full — `mail read <id>`.
    case post(id: Int)
  }

  public var selection: Selection
  /// Keeps only posts whose author, topic or body contains the text,
  /// case-insensitively — applied before bodies are cut, so a match deep in a body
  /// still counts.
  public var search: String?
  /// `true` for whole bodies, `false` for headlines, `nil` to let the room decide by
  /// `Mailroom.needsTriage` — what `mail inbox` does unless told `--full` or
  /// `--headlines`, since a loop cannot know how much mail it has before reading it.
  public var fullBodies: Bool?

  public init(selection: Selection, search: String? = nil, fullBodies: Bool? = nil) {
    self.selection = selection
    self.search = search
    self.fullBodies = fullBodies
  }
}

/// The room's answer to a `MailboxQuery`: the posts asked for, and the numbers a
/// reader needs to act on them without holding the whole room.
public struct Mailbox: Codable, Equatable, Sendable {
  /// Oldest first, the room's own order.
  public var posts: [MailroomPost]
  /// Whether `posts` carry headlines rather than whole bodies
  /// (`Mailroom.headlineBodyBudget`). Said explicitly so a caller that left the choice
  /// to the room can tell its reader it is reading a triaged room.
  public var bodiesTrimmed: Bool
  /// The room the answer was drawn from, for the same purposes a snapshot's is.
  public var digest: MailroomDigest
  /// The reader's cursor, for an `.unread` selection whose reader the room knows.
  public var lastRead: Int?
  /// The id of the last post in `posts` — what a cursor may honestly advance to,
  /// since it is the highest post the reader was actually handed.
  public var highestDeliveredID: Int?

  public init(
    posts: [MailroomPost], bodiesTrimmed: Bool, digest: MailroomDigest, lastRead: Int? = nil,
    highestDeliveredID: Int? = nil
  ) {
    self.posts = posts
    self.bodiesTrimmed = bodiesTrimmed
    self.digest = digest
    self.lastRead = lastRead
    self.highestDeliveredID = highestDeliveredID
  }
}

extension MailroomPost {
  /// The same post with its body cut to the first `Mailroom.headlineBodyBudget`
  /// characters — what a triaged mailbox carries instead of the whole note. Cut in
  /// grapheme clusters, never mid-glyph.
  public func headlined() -> MailroomPost {
    guard body.count > Mailroom.headlineBodyBudget else { return self }
    return MailroomPost(
      id: id, at: at, authorID: authorID, author: author, topic: topic,
      body: String(body.prefix(Mailroom.headlineBodyBudget)), kind: kind)
  }
}

extension Mailroom {
  /// How much of a body a headline keeps. The CLI's triage line is cut at 80
  /// characters *including* the post's byline, so 80 characters of body is always
  /// enough for it to render exactly what the whole body would have — the room can
  /// trim on the wire without the reader being able to tell.
  public static let headlineBodyBudget = 80

  /// Answers a query against a room. `cursor` is the reader's `lastMailroomRead`, or
  /// `nil` for a reader the graph does not know — who, as before, is shown everything
  /// and refused the cursor advance afterwards.
  ///
  /// `search` filters before bodies are cut. A `.post` selection is never trimmed: it
  /// is the deep read a headline points at.
  public static func serve(
    _ query: MailboxQuery, from posts: [MailroomPost], cursor: (UUID) -> Int?
  ) -> Mailbox {
    var selected: [MailroomPost]
    var lastRead: Int?
    var deepRead = false
    switch query.selection {
    case .board:
      selected = posts
    case .unread(let reader):
      lastRead = cursor(reader)
      selected = unread(in: posts, since: lastRead)
    case .post(let id):
      selected = posts.filter { $0.id == id }
      deepRead = true
    }
    if let search = query.search, !search.isEmpty {
      let needle = search.lowercased()
      selected = selected.filter {
        $0.body.lowercased().contains(needle) || $0.author.lowercased().contains(needle)
          || $0.topic?.lowercased().contains(needle) == true
      }
    }
    let trimmed: Bool
    switch query.fullBodies {
    case .some(let full): trimmed = !full && !deepRead
    case .none: trimmed = !deepRead && needsTriage(selected)
    }
    if trimmed { selected = selected.map { $0.headlined() } }
    return Mailbox(
      posts: selected, bodiesTrimmed: trimmed, digest: MailroomDigest(of: posts),
      lastRead: lastRead, highestDeliveredID: selected.last?.id)
  }
}
