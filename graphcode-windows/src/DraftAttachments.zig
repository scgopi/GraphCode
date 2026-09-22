const std = @import("std");

/// Windows' half of the New Node dialog's file attachments — what a native file picker
/// hands the form, and where those bytes land before a node exists to own them.
///
/// The macOS reference is `graphcode/Sources/Features/Project/ProjectFeature+Attachments.swift`
/// and `NodeDraftAttachments.swift`: an image is written to disk under the *draft's own
/// id* the moment it is picked, and a `[image #N]` placeholder stands in for it in the
/// brief field the human is typing into. The daemon (`GraphcodeKit`'s shared
/// `PromptAttachments.resolving`) swaps the placeholder for the real path when the
/// session actually opens — this module never needs to know how that prompt gets built,
/// only where the bytes go and what a token looks like.
///
/// Everything here is pure logic plus filesystem calls: no Win32, so it is exercised the
/// same way `Forms.zig`'s validators are, with plain `zig test`.
/// Bigger than this is refused, matching macOS `DraftImageImport.maximumBytes` — an
/// agent reads a screenshot or a short note, not a poster, and every byte is copied
/// synchronously while the dialog is open.
pub const max_bytes: usize = 10 * 1024 * 1024;

/// How many files one draft may carry. Unlike macOS, the Windows dialog lays out a
/// fixed-size list control rather than a scrolling SwiftUI stack, so the count needs an
/// upper bound; eight is more than any one prompt should reasonably reference.
pub const max_attachments: usize = 8;

/// Extensions a backend can actually open once the path lands in its prompt. Images
/// mirror macOS's `DraftImageImport.imageExtensions` exactly; the plain-text kinds are
/// the Windows-only broadening the task asked for ("attach supported files/images"),
/// kept to formats every backend's own tools already read without a special viewer.
const supported_extensions = [_][]const u8{
    "png", "jpg", "jpeg", "gif",  "heic", "webp", "tiff", "tif", "bmp",
    "txt", "md",  "log",  "json", "csv",  "pdf",
};

pub const IngestError = error{
    UnsupportedFileType,
    FileTooLarge,
    EmptyFile,
    SourceUnreadable,
    TooManyAttachments,
    DestinationUnwritable,
} || std.mem.Allocator.Error;

/// The file extension (no dot, original case), or "" for a dotfile or extension-less
/// name — both of which fail `isSupportedExtension` rather than being special-cased.
pub fn extensionOf(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return "";
    if (dot == 0) return "";
    return base[dot + 1 ..];
}

/// Case-insensitive membership in `supported_extensions`. `.len` is bounded so a
/// pathological extension can't blow the stack buffer used for lowercasing; anything
/// that long was never going to match a three-or-four-letter extension anyway.
pub fn isSupportedExtension(extension: []const u8) bool {
    var buffer: [16]u8 = undefined;
    if (extension.len == 0 or extension.len > buffer.len) return false;
    const lower = std.ascii.lowerString(buffer[0..extension.len], extension);
    for (supported_extensions) |candidate| {
        if (std.mem.eql(u8, candidate, lower)) return true;
    }
    return false;
}

/// A byte-for-byte port of `SessionBriefing.slug(for:)`: every character that is not a
/// letter, digit, or dash becomes a dash, then leading/trailing dashes are trimmed.
/// Kept identical on purpose — `NodeMemory.attachmentsDirectory`'s macOS layout names
/// the project component with this slug, and matching it means a human browsing
/// `~/.graphcode/memory` sees the same directory name regardless of which client wrote
/// it.
pub fn projectSlug(allocator: std.mem.Allocator, project_path: []const u8) ![]u8 {
    var buffer = try std.ArrayList(u8).initCapacity(allocator, project_path.len);
    errdefer buffer.deinit(allocator);
    for (project_path) |byte| {
        const keep = std.ascii.isAlphanumeric(byte) or byte == '-';
        try buffer.append(allocator, if (keep) byte else '-');
    }
    var start: usize = 0;
    while (start < buffer.items.len and buffer.items[start] == '-') start += 1;
    var end: usize = buffer.items.len;
    while (end > start and buffer.items[end - 1] == '-') end -= 1;
    const trimmed = try allocator.dupe(u8, buffer.items[start..end]);
    buffer.deinit(allocator);
    return trimmed;
}

/// `%GRAPHCODE_SUPPORT_DIR%` when set, otherwise `%USERPROFILE%\.graphcode` — the same
/// default `DaemonClient.zig`'s own `defaultSupportDirectory` resolves, so a node's
/// attachment directory sits beside the memory log the daemon keeps for the same node
/// (`NodeMemory.attachmentsDirectory`).
pub fn supportDirectory(allocator: std.mem.Allocator) ![]u8 {
    return supportDirectoryFrom(allocator, std.process.getEnvVarOwned);
}

const EnvLookup = fn (std.mem.Allocator, []const u8) anyerror![]u8;

fn supportDirectoryFrom(allocator: std.mem.Allocator, lookup: EnvLookup) ![]u8 {
    if (lookup(allocator, "GRAPHCODE_SUPPORT_DIR")) |value| {
        return value;
    } else |_| {}
    const home = lookup(allocator, "USERPROFILE") catch return error.SourceUnreadable;
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".graphcode" });
}

/// Where a draft's attachments land: `<support>\memory\<projectSlug>\<draftID>\attachments`.
/// Deliberately the same directory `NodeMemory.attachmentsDirectory` computes for the
/// eventual node — once the draft is submitted with this same id, the daemon's own
/// `NodeMemory.remove` (fired on node deletion) is what cleans this up; before that, a
/// cancelled draft has to take care of it itself (`discardAll`).
pub fn attachmentsDirectory(
    allocator: std.mem.Allocator,
    support_dir: []const u8,
    project_path: []const u8,
    draft_id: []const u8,
) ![]u8 {
    const slug = try projectSlug(allocator, project_path);
    defer allocator.free(slug);
    return std.fs.path.join(allocator, &.{ support_dir, "memory", slug, draft_id, "attachments" });
}

/// Copies `source_path` into `dest_dir` as `attachment-<number><.extension>`, refusing
/// anything unsupported, empty, or over `max_bytes`. Returns the destination's absolute
/// path, owned by `allocator`. Synchronous and whole-file, like macOS's
/// `DraftImageImport.write` — the dialog is open and modal, so nothing else is
/// competing for the bytes in flight.
pub fn ingest(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    dest_dir: []const u8,
    number: usize,
) IngestError![]u8 {
    const extension = extensionOf(source_path);
    if (!isSupportedExtension(extension)) return error.UnsupportedFileType;
    var file = std.fs.cwd().openFile(source_path, .{}) catch return error.SourceUnreadable;
    defer file.close();
    const stat = file.stat() catch return error.SourceUnreadable;
    if (stat.size == 0) return error.EmptyFile;
    if (stat.size > max_bytes) return error.FileTooLarge;
    const data = file.readToEndAlloc(allocator, max_bytes) catch return error.SourceUnreadable;
    defer allocator.free(data);
    std.fs.cwd().makePath(dest_dir) catch return error.DestinationUnwritable;
    const dest_path = try std.fmt.allocPrint(allocator, "{s}\\attachment-{d}.{s}", .{ dest_dir, number, extension });
    errdefer allocator.free(dest_path);
    var dest_file = std.fs.cwd().createFile(dest_path, .{ .truncate = true }) catch
        return error.DestinationUnwritable;
    defer dest_file.close();
    dest_file.writeAll(data) catch return error.DestinationUnwritable;
    return dest_path;
}

/// Drops a cancelled draft's whole attachment tree. Mirrors macOS
/// `DraftImageImport.discardAll`: the draft id is a node id nothing will ever create, so
/// nothing else owns this directory. Failures (already gone, never created) are
/// swallowed for the same reason macOS's `try?` is — there is no node left to report the
/// failure against.
pub fn discardAll(dest_dir: []const u8) void {
    std.fs.cwd().deleteTree(dest_dir) catch {};
}

/// The placeholder for the `number`-th attachment, 1-based — byte-identical to macOS
/// `PromptAttachments.token`, since the daemon's shared `PromptAttachments.resolving`
/// is what actually looks for it in the prompt text.
pub fn token(allocator: std.mem.Allocator, number: usize) ![]u8 {
    return std.fmt.allocPrint(allocator, "[image #{d}]", .{number});
}

/// `text` with the `number`-th placeholder dropped and every later one renumbered, so
/// removing the middle chip of three doesn't leave `[image #3]` pointing at nothing.
/// A direct port of macOS `PromptAttachments.removing(attachment:from:of:)`.
pub fn removing(allocator: std.mem.Allocator, text: []const u8, number: usize, count: usize) ![]u8 {
    var current = try allocator.dupe(u8, text);
    {
        const target = try token(allocator, number);
        defer allocator.free(target);
        const replaced = try replaceAll(allocator, current, target, "");
        allocator.free(current);
        current = replaced;
    }
    var later = number + 1;
    while (later <= count) : (later += 1) {
        const from = try token(allocator, later);
        defer allocator.free(from);
        const to = try token(allocator, later - 1);
        defer allocator.free(to);
        const replaced = try replaceAll(allocator, current, from, to);
        allocator.free(current);
        current = replaced;
    }
    while (std.mem.indexOf(u8, current, "  ") != null) {
        const replaced = try replaceAll(allocator, current, "  ", " ");
        allocator.free(current);
        current = replaced;
    }
    const trimmed = std.mem.trim(u8, current, " \t");
    const result = try allocator.dupe(u8, trimmed);
    allocator.free(current);
    return result;
}

fn replaceAll(allocator: std.mem.Allocator, haystack: []const u8, needle: []const u8, replacement: []const u8) ![]u8 {
    const count = std.mem.replacementSize(u8, haystack, needle, replacement);
    const buffer = try allocator.alloc(u8, count);
    _ = std.mem.replace(u8, haystack, needle, replacement, buffer);
    return buffer;
}

test "extensionOf reads the extension without the dot" {
    try std.testing.expectEqualStrings("png", extensionOf("C:\\Users\\me\\Pictures\\shot.png"));
    try std.testing.expectEqualStrings("", extensionOf("C:\\Users\\me\\.gitignore"));
    try std.testing.expectEqualStrings("", extensionOf("C:\\Users\\me\\README"));
}

test "isSupportedExtension accepts images and plain text, case-insensitively" {
    try std.testing.expect(isSupportedExtension("PNG"));
    try std.testing.expect(isSupportedExtension("jpg"));
    try std.testing.expect(isSupportedExtension("md"));
    try std.testing.expect(!isSupportedExtension("exe"));
    try std.testing.expect(!isSupportedExtension(""));
}

test "projectSlug matches SessionBriefing.slug's replace-and-trim rule" {
    const allocator = std.testing.allocator;
    const slug = try projectSlug(allocator, "C:\\work\\graph one");
    defer allocator.free(slug);
    try std.testing.expectEqualStrings("C--work-graph-one", slug);

    const trimmed = try projectSlug(allocator, "//C:/work//");
    defer allocator.free(trimmed);
    try std.testing.expectEqualStrings("C--work", trimmed);
}

test "attachmentsDirectory joins support, memory, slug and draft id" {
    const allocator = std.testing.allocator;
    const dir = try attachmentsDirectory(allocator, "C:\\Users\\me\\.graphcode", "C:\\work\\graph", "11111111-1111-4111-8111-111111111111");
    defer allocator.free(dir);
    try std.testing.expectEqualStrings(
        "C:\\Users\\me\\.graphcode\\memory\\C--work-graph\\11111111-1111-4111-8111-111111111111\\attachments",
        dir,
    );
}

test "ingest refuses unsupported types, empty files and oversized files" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "note.exe", .data = "hello" });
    const exe_path = try tmp.dir.realpathAlloc(allocator, "note.exe");
    defer allocator.free(exe_path);
    const dest_dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dest_dir);
    const attachments_dir = try std.fs.path.join(allocator, &.{ dest_dir, "attachments" });
    defer allocator.free(attachments_dir);

    try std.testing.expectError(error.UnsupportedFileType, ingest(allocator, exe_path, attachments_dir, 1));

    try tmp.dir.writeFile(.{ .sub_path = "empty.txt", .data = "" });
    const empty_path = try tmp.dir.realpathAlloc(allocator, "empty.txt");
    defer allocator.free(empty_path);
    try std.testing.expectError(error.EmptyFile, ingest(allocator, empty_path, attachments_dir, 1));

    try tmp.dir.writeFile(.{ .sub_path = "note.txt", .data = "hello there" });
    const ok_path = try tmp.dir.realpathAlloc(allocator, "note.txt");
    defer allocator.free(ok_path);
    const written = try ingest(allocator, ok_path, attachments_dir, 1);
    defer allocator.free(written);
    try std.testing.expect(std.mem.endsWith(u8, written, "attachment-1.txt"));
    const copied = try std.fs.cwd().readFileAlloc(allocator, written, 4096);
    defer allocator.free(copied);
    try std.testing.expectEqualStrings("hello there", copied);
}

test "discardAll removes the whole attachment tree" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("draft-dir\\attachments");
    try tmp.dir.writeFile(.{ .sub_path = "draft-dir\\attachments\\attachment-1.png", .data = "x" });
    const draft_dir = try tmp.dir.realpathAlloc(allocator, "draft-dir");
    defer allocator.free(draft_dir);
    discardAll(draft_dir);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("draft-dir", .{}));
}

test "removing drops the numbered token and renumbers the rest" {
    const allocator = std.testing.allocator;
    const result = try removing(allocator, "before [image #2] after [image #3]", 2, 3);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("before after [image #2]", result);
}

test "token matches macOS PromptAttachments.token exactly" {
    const allocator = std.testing.allocator;
    const value = try token(allocator, 3);
    defer allocator.free(value);
    try std.testing.expectEqualStrings("[image #3]", value);
}
