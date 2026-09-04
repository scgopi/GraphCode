import Foundation
import Testing

@testable import GraphcodeKit

/// `send(_:to:)` driven end to end against a **real** `zmx` session, because issue #277
/// is the second silent-loss bug in this path that every unit test of the day passed.
///
/// The first (0.1.29) split oversized writes; its tests asserted that `messageChunks`
/// split correctly, which it did, and the message still vanished. #277 broke the split
/// path itself: every multi-chunk message arrived with its head gone and `delivered`
/// printed. A test that only checks the splitter would pass on both bugs, so this suite
/// sends the real thing through the real transport and reads back what a session actually
/// received.
///
/// What the measurements said, since the fix is built on them rather than on a theory.
/// Nothing below the agent's TUI loses anything: 2 KB writes reach a raw-mode reader
/// byte-for-byte, and reach one that stalls 300 ms between reads byte-for-byte too. The
/// loss is the composer swallowing a long burst of keystrokes (2634 bytes sent, 590
/// received). It cannot be fixed by chunking smaller, because the reader's reads are not
/// our writes — two 512-byte writes arrived as one 1022-byte read when the reader
/// stalled. Bracketed paste is what removes the question.
/// Disabled rather than returned early when `zmx` is missing: every test here needs a
/// real session, and a `guard … else { return }` reports a test that never ran as a
/// passing one — which is the same class of thing this suite exists to catch.
@Suite(.serialized, .enabled(if: ZmxLocator.isInstalled, "zmx is not installed"))
struct MessageDeliveryTests {
  private static let zmx = ZmxLocator.binaryURL.path

  private static func quoted(_ value: String) -> String {
    RemoteProjectLocation.shellQuoted(value)
  }

  @discardableResult
  private func run(_ command: String) async -> (succeeded: Bool, output: String) {
    guard
      let session = try? PTYProcessSession(
        executable: "/bin/zsh", arguments: ["-c", command], workingDirectory: nil)
    else { return (false, "") }
    return await session.waitCollectingOutput()
  }

  private func kill(_ name: String) async {
    await run("\(Self.quoted(Self.zmx)) kill \(Self.quoted(name)) --force >/dev/null 2>&1")
  }

  /// A live session of the shape graphcode launches, running a reader that records what
  /// it was typed. `composerLimit` is how big a run of plain keystrokes it will accept
  /// before swallowing it — `nil` for a reader that keeps everything.
  private func startSink(_ node: LoopNode, composerLimit: Int?) async -> (name: String, out: URL)? {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("gc-277-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let script = directory.appendingPathComponent("sink.py")
    let out = directory.appendingPathComponent("received.bin")
    guard (try? Self.sinkSource.write(to: script, atomically: true, encoding: .utf8)) != nil
    else { return nil }

    let name = SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName
    let ready = directory.appendingPathComponent("ready")
    await run(
      "\(Self.quoted(Self.zmx)) run \(Self.quoted(name)) -d /usr/bin/python3 "
        + "\(Self.quoted(script.path)) \(Self.quoted(out.path)) \(composerLimit ?? 0)")
    // Waited on, not slept through. `zmx run` returns once the command is typed, and
    // until the reader reaches `tty.setraw` its tty is still cooked — where a write
    // longer than `MAX_CANON` is clipped by the line discipline and `setraw`'s
    // `TCSAFLUSH` throws away whatever did land. A test that raced that would report
    // exactly the head loss it exists to detect, from the wrong cause.
    for _ in 0..<200 {
      if FileManager.default.fileExists(atPath: ready.path) { return (name, out) }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return nil
  }

  /// Waits the same twenty seconds `startSink` does. Six was enough on an idle machine
  /// and not on a loaded one, and a read that gives up early fails as a short message —
  /// indistinguishable from the head loss this suite exists to catch.
  private func received(from out: URL) async -> String? {
    for _ in 0..<200 {
      if let data = try? Data(contentsOf: out) { return String(bytes: data, encoding: .utf8) }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return nil
  }

  private func node() -> LoopNode {
    LoopNode(title: "Sink", loopType: .goalBased, goal: GoalSpec(summary: "receive"))
  }

  /// What `send` should put in front of the receiver: the message as it will be typed,
  /// plus the trailer a long one carries.
  private func expected(_ message: String) -> String {
    let flat = ZmxSessionLauncher.flattened(message)
    guard flat.utf8.count > ZmxSessionLauncher.maxUnbracketedSendBytes else { return flat }
    return flat + ZmxSessionLauncher.deliveryTrailer(for: flat)
  }

  private func message(bytes: Int, tag: String) -> String {
    let filler = (0..<(bytes / 6 + 2)).map { String(format: "<%04d>", $0) }.joined()
    return String(("[graphcode] \(tag): " + filler).prefix(bytes))
  }

  @Test
  func anOversizedMessageArrivesByteForByte() async throws {
    let node = node()
    let sink = try #require(await startSink(node, composerLimit: nil))
    defer { Task { await kill(sink.name) } }

    // Comfortably over `maxSendChunkBytes`, so it is carried by several writes — the
    // shape that lost its head in the field.
    let sent = message(bytes: 6000, tag: "Sender")
    #expect(await ZmxSessionLauncher.send(sent, to: node))

    let arrived = try #require(await received(from: sink.out))
    // Byte for byte, not "contains": the failure being guarded is a message that arrives
    // looking complete because only its head is missing.
    #expect(arrived == expected(sent))
    #expect(arrived.hasPrefix("[graphcode] Sender: "))
  }

  @Test
  func aLongMessageSurvivesAComposerThatSwallowsKeystrokeBursts() async throws {
    let node = node()
    // The reader models what was measured of the real composer: a run of plain
    // keystrokes above this size is swallowed whole, and a bracketed paste is not,
    // however large. Before the fix this message travelled as one keystroke run and the
    // assertion below found an empty composer — which is #277, reproduced.
    let sink = try #require(
      await startSink(node, composerLimit: ZmxSessionLauncher.maxUnbracketedSendBytes))
    defer { Task { await kill(sink.name) } }

    let sent = message(bytes: 2600, tag: "Sender")
    #expect(await ZmxSessionLauncher.send(sent, to: node))

    let arrived = try #require(await received(from: sink.out))
    #expect(arrived == expected(sent))
  }

  @Test
  func aShortMessageStillTravelsAsPlainKeystrokes() async throws {
    let node = node()
    // Same swallowing reader. A short message is deliberately *not* pasted — it is
    // measured to arrive intact as typing, and leaving it on the path it already
    // survives is what keeps this fix confined to the case that is broken.
    let sink = try #require(
      await startSink(node, composerLimit: ZmxSessionLauncher.maxUnbracketedSendBytes))
    defer { Task { await kill(sink.name) } }

    let sent = message(bytes: 400, tag: "Sender")
    #expect(await ZmxSessionLauncher.send(sent, to: node))

    let arrived = try #require(await received(from: sink.out))
    #expect(arrived == sent)
    #expect(!arrived.contains(ZmxSessionLauncher.pasteStart))
  }

  /// A reader standing in for an agent's composer: raw mode, bracketed paste understood,
  /// and — when given a limit — the measured habit of swallowing a long run of plain
  /// keystrokes rather than keeping it. It writes what the composer holds when Enter
  /// arrives, which is the moment `send` says the message was delivered.
  private static let sinkSource = """
    import os, sys, tty

    target, limit = sys.argv[1], int(sys.argv[2])
    START, END = b"\\x1b[200~", b"\\x1b[201~"
    fd = sys.stdin.fileno()
    tty.setraw(fd)
    open(os.path.join(os.path.dirname(target), "ready"), "w").close()

    composer, pending, buf = bytearray(), bytearray(), bytearray()
    pasting = False

    def commit():
        # The whole of issue #277 in one branch: a burst of typing the composer will not
        # take is dropped entirely rather than truncated, so what follows still reads as
        # a complete message.
        if not limit or len(pending) <= limit:
            composer.extend(pending)
        del pending[:]

    def holdback(data, marker):
        # Never hand on a tail that could be the front of a marker split across reads.
        for n in range(len(marker) - 1, 0, -1):
            if data.endswith(marker[:n]):
                return n
        return 0

    def absorb(data):
        global pasting
        buf.extend(data)
        while True:
            if pasting:
                cut = buf.find(END)
                if cut < 0:
                    keep = len(buf) - holdback(buf, END)
                    composer.extend(buf[:keep])
                    del buf[:keep]
                    return
                composer.extend(buf[:cut])
                del buf[: cut + len(END)]
                pasting = False
                continue
            cut = buf.find(START)
            if cut < 0:
                keep = len(buf) - holdback(buf, START)
                pending.extend(buf[:keep])
                del buf[:keep]
                return
            pending.extend(buf[:cut])
            del buf[: cut + len(START)]
            commit()
            pasting = True

    while True:
        chunk = os.read(fd, 65536)
        if not chunk:
            break
        absorb(chunk)
        if b"\\r" in pending:
            del pending[pending.index(b"\\r"):]
            commit()
            # Written aside and renamed: `open(target, "wb")` truncates on open, so a
            # reader polling for the file catches it empty or half-filled and compares a
            # short string against the whole message. `os.replace` is atomic, so the
            # target either is not there or is complete.
            partial = target + ".partial"
            open(partial, "wb").write(bytes(composer))
            os.replace(partial, target)
            break
    """
}
