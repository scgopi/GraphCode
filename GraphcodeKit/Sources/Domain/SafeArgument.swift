import Foundation

/// Guards the *argument injection* class: an untrusted string that begins with `-` being
/// read as an option flag by a CLI graphcode shells out to (git, ssh, an agent backend),
/// or a folder name that reaches into another directory. None of the values graphcode
/// legitimately builds from human input — a branch name, an ssh host or login, a clone's
/// destination folder — has any reason to start with a dash or to carry a path separator,
/// so refusing those shapes costs nothing real and closes the whole class at once:
/// git's `--upload-pack=<cmd>`, ssh's `-oProxyCommand=<cmd>`, a `..` that escapes the
/// chosen parent.
///
/// This is the door check. It pairs with — does not replace — a literal `--` separator
/// before the positional arguments of the commands that accept one (`git clone`,
/// `git worktree add`): validation stops a hostile value at the door, `--` stops it at
/// the parser.
public enum SafeArgument {
  /// A value a getopt-style parser would mistake for an option.
  public static func looksLikeOption(_ value: String) -> Bool {
    value.hasPrefix("-")
  }

  /// An ssh `user`/`host` token safe to hand to `ssh`. A real hostname or login name is
  /// never empty, never starts with a dash, and never contains whitespace or control
  /// characters — the shapes that would otherwise let a stored or typed value smuggle an
  /// `-o…` option into the dial (the `--` in `sshInvocation` sits *after* the
  /// destination, so it cannot protect the destination itself).
  public static func isSafeSSHComponent(_ value: String) -> Bool {
    !value.isEmpty
      && !looksLikeOption(value)
      && !value.contains(where: \.isWhitespace)
      && !value.unicodeScalars.contains { $0.value < 0x20 }
  }

  /// A single path component safe to append to a chosen directory: one non-empty
  /// segment, no `.`/`..` traversal, no separator, not option-shaped, no NUL. Rejecting
  /// these is what keeps a clone's destination — and the failure-path `removeItem` that
  /// follows it — inside the folder the human picked.
  public static func isSafePathComponent(_ value: String) -> Bool {
    !value.isEmpty
      && value != "."
      && value != ".."
      && !looksLikeOption(value)
      && !value.contains("/")
      && !value.unicodeScalars.contains { $0.value == 0 }
  }
}
