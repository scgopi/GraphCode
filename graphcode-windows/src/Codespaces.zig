//! GitHub Codespaces ingress for the Windows shell — the parity twin of the macOS
//! `CodespaceClient`/`CodespaceFormView` pair.
//!
//! Everything rides the GitHub CLI rather than the REST API directly: `gh` owns the
//! credential store, the `codespace` scope check (whose error text carries its own
//! fix), and the SSH tunnel every later dial uses. Nothing in this module reads,
//! stores, or logs a token — the only thing persisted is the codespace name and the
//! repository path inside it, next to the SSH remote's own config.
//!
//! The project identity a validated codespace produces is `codespace://<name><path>`,
//! the same URI GraphcodeKit's `RemoteProjectLocation` parses, so the daemon needs no
//! new operation: `openProject` with that path is the whole protocol surface.

const std = @import("std");

/// One codespace as `gh codespace list --json` reports it — exactly the fields the
/// picker shows, so there is no scraping to drift.
pub const Codespace = struct {
    name: []u8,
    display_name: []u8,
    repository: []u8,
    state: []u8,

    pub fn deinit(self: *Codespace, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.display_name);
        allocator.free(self.repository);
        allocator.free(self.state);
        self.* = undefined;
    }

    /// What the picker row reads: the human's label, then the repository and gh's own
    /// state word so a stopped codespace is still recognisable (connecting starts it).
    pub fn rowLabel(self: Codespace, allocator: std.mem.Allocator) ![]u8 {
        const title = if (self.display_name.len != 0) self.display_name else self.name;
        return std.fmt.allocPrint(allocator, "{s}  —  {s} · {s}", .{ title, self.repository, self.state });
    }

    /// Where a codespace puts its clone by default. Prefill only — the dialog's path
    /// field stays editable for devcontainers that mount elsewhere.
    pub fn defaultWorkspacePath(self: Codespace, allocator: std.mem.Allocator) ![]u8 {
        return defaultWorkspacePathFor(allocator, self.repository);
    }
};

pub fn defaultWorkspacePathFor(allocator: std.mem.Allocator, repository: []const u8) ![]u8 {
    const leaf = if (std.mem.lastIndexOfScalar(u8, repository, '/')) |slash|
        repository[slash + 1 ..]
    else
        repository;
    if (leaf.len == 0) return allocator.dupe(u8, "/workspaces");
    return std.fmt.allocPrint(allocator, "/workspaces/{s}", .{leaf});
}

/// An owned list, so the dialog can hold gh's answer across message-loop turns.
pub const CodespaceList = struct {
    allocator: std.mem.Allocator,
    items: []Codespace,

    pub fn deinit(self: *CodespaceList) void {
        for (self.items) |*item| item.deinit(self.allocator);
        self.allocator.free(self.items);
        self.items = &.{};
    }
};

/// Why discovery couldn't answer. Each one has a single message whose remediation is
/// the actual next command — the missing-scope case is the one humans hit most, and
/// gh's own fix line is reproduced rather than paraphrased.
pub const Failure = enum {
    gh_missing,
    not_authenticated,
    missing_codespace_scope,
    network_unavailable,
    unreadable_list,
    list_failed,
};

pub fn failureMessage(failure: Failure) []const u8 {
    return switch (failure) {
        .gh_missing => "The GitHub CLI isn't installed — codespaces are reached through it. " ++
            "Install it with \"winget install GitHub.cli\", run \"gh auth login\", and try again.",
        .not_authenticated => "The GitHub CLI isn't signed in. Run \"gh auth login\" and try again.",
        .missing_codespace_scope => "Your GitHub CLI token is missing the codespace scope. " ++
            "Run \"gh auth refresh -h github.com -s codespace\" and try again.",
        .network_unavailable => "GitHub could not be reached. Check the network connection and try again.",
        .unreadable_list => "The codespace list from the GitHub CLI could not be read.",
        .list_failed => "The GitHub CLI could not list your codespaces.",
    };
}

/// gh's exit text, mapped to the failure that names its fix. Matching is on the
/// stable operator-facing phrases gh prints, lowercased so a capitalisation change
/// doesn't silently downgrade a scope problem to a generic failure.
pub fn classifyFailure(allocator: std.mem.Allocator, stderr: []const u8) Failure {
    const lowered = std.ascii.allocLowerString(allocator, stderr) catch return .list_failed;
    defer allocator.free(lowered);
    if (std.mem.indexOf(u8, lowered, "\"codespace\" scope") != null or
        std.mem.indexOf(u8, lowered, "'codespace' scope") != null or
        std.mem.indexOf(u8, lowered, "gh auth refresh") != null)
        return .missing_codespace_scope;
    if (std.mem.indexOf(u8, lowered, "gh auth login") != null or
        std.mem.indexOf(u8, lowered, "not logged in") != null or
        std.mem.indexOf(u8, lowered, "authentication token") != null)
        return .not_authenticated;
    if (std.mem.indexOf(u8, lowered, "dial tcp") != null or
        std.mem.indexOf(u8, lowered, "no such host") != null or
        std.mem.indexOf(u8, lowered, "connection refused") != null or
        std.mem.indexOf(u8, lowered, "i/o timeout") != null or
        std.mem.indexOf(u8, lowered, "network is unreachable") != null)
        return .network_unavailable;
    return .list_failed;
}

/// gh's own words, made safe to display: credential-shaped runs are removed before
/// the text can reach a label, a log, or a screenshot, control characters collapse to
/// spaces, and the result is bounded so a runaway stream can't own the dialog.
pub fn sanitizeMessage(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var safe = std.array_list.Managed(u8).init(allocator);
    defer safe.deinit();
    var index: usize = 0;
    while (index < raw.len) {
        if (secretRunLength(raw[index..])) |length| {
            try safe.appendSlice("<redacted>");
            index += length;
            continue;
        }
        const byte = raw[index];
        index += 1;
        if (byte < 0x20 or byte == 0x7f) {
            if (safe.items.len != 0 and safe.items[safe.items.len - 1] != ' ') try safe.append(' ');
            continue;
        }
        try safe.append(byte);
    }
    const trimmed = std.mem.trim(u8, safe.items, " ");
    const bounded = trimmed[0..@min(trimmed.len, message_limit)];
    return allocator.dupe(u8, bounded);
}

const message_limit = 400;

/// The credential shapes GitHub issues. Matching the prefix and consuming the whole
/// token run keeps a partial redaction from leaving a usable tail behind.
const secret_prefixes = [_][]const u8{ "gho_", "ghp_", "ghu_", "ghs_", "ghr_", "github_pat_" };

fn secretRunLength(text: []const u8) ?usize {
    for (secret_prefixes) |prefix| {
        if (!std.mem.startsWith(u8, text, prefix)) continue;
        var length = prefix.len;
        while (length < text.len and (std.ascii.isAlphanumeric(text[length]) or text[length] == '_')) : (length += 1) {}
        if (length > prefix.len) return length;
    }
    return null;
}

/// What the add-codespace dialog is collecting: one pick, and the repository path
/// inside it.
pub const Fields = struct {
    name: []const u8 = "",
    path: []const u8 = "",
};

pub fn validate(fields: Fields) !void {
    if (fields.name.len == 0) return error.MissingCodespaceName;
    if (fields.path.len == 0) return error.MissingCodespacePath;
    if (!std.mem.startsWith(u8, fields.path, "/")) return error.AbsolutePathRequired;
    if (std.mem.startsWith(u8, fields.name, "-") or std.mem.startsWith(u8, fields.path, "-"))
        return error.InvalidCodespaceName;
    // The name reaches `gh -c <name>` as an argument, so it passes the same door check
    // a hostname does: anything outside gh's own name alphabet is rejected rather than
    // quoted, because a quoted `--flag` is still a flag to some argument parsers.
    for (fields.name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, "-_.", byte) == null)
            return error.InvalidCodespaceName;
    }
    if (std.mem.indexOfAny(u8, fields.path, "\x00\r\n") != null) return error.InvalidCodespacePath;
}

pub fn validationMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingCodespaceName => "Choose a codespace from the list.",
        error.MissingCodespacePath => "Enter the repository path inside the codespace.",
        error.AbsolutePathRequired => "Repository path must be absolute and begin with /.",
        error.InvalidCodespaceName => "That codespace name contains an invalid value.",
        error.InvalidCodespacePath => "Repository path contains an invalid value.",
        else => "Check the codespace details and try again.",
    };
}

/// `codespace://<name><path>` — the identity a validated codespace travels as, and
/// exactly what `RemoteProjectLocation.parse` reads back.
pub fn projectURI(allocator: std.mem.Allocator, fields: Fields) ![]u8 {
    try validate(fields);
    var encoded = std.array_list.Managed(u8).init(allocator);
    defer encoded.deinit();
    try encoded.appendSlice("codespace://");
    try encoded.appendSlice(fields.name);
    for (fields.path) |byte| try appendURIByte(&encoded, byte, byte != '/');
    return encoded.toOwnedSlice();
}

fn appendURIByte(list: *std.array_list.Managed(u8), byte: u8, encode: bool) !void {
    const safe = std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "-._~", byte) != null;
    if (safe or (!encode and byte == '/')) return list.append(byte);
    const hex = "0123456789ABCDEF";
    try list.append('%');
    try list.append(hex[byte >> 4]);
    try list.append(hex[byte & 15]);
}

/// POSIX single-quote escaping — the remote side of a codespace dial is a Linux login
/// shell no matter what the local machine is.
pub fn shellQuote(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var size: usize = 2;
    for (value) |byte| size += if (byte == '\'') 4 else 1;
    var result = try allocator.alloc(u8, size);
    var index: usize = 0;
    result[index] = '\'';
    index += 1;
    for (value) |byte| {
        if (byte == '\'') {
            @memcpy(result[index .. index + 4], "'\\''");
            index += 4;
        } else {
            result[index] = byte;
            index += 1;
        }
    }
    result[index] = '\'';
    return result;
}

/// `gh codespace list` with an explicit limit: gh's default is 30 and the truncation
/// is silent, so a 31st codespace would simply never appear in the picker.
pub fn listArgs(allocator: std.mem.Allocator, gh_path: []const u8) ![][]u8 {
    var args = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (args.items) |arg| allocator.free(arg);
        args.deinit();
    }
    try args.append(try allocator.dupe(u8, gh_path));
    try args.append(try allocator.dupe(u8, "codespace"));
    try args.append(try allocator.dupe(u8, "list"));
    try args.append(try allocator.dupe(u8, "--limit"));
    try args.append(try allocator.dupe(u8, "500"));
    try args.append(try allocator.dupe(u8, "--json"));
    try args.append(try allocator.dupe(u8, "name,displayName,repository,state"));
    return args.toOwnedSlice();
}

/// The validation dial, and the shape every later session dial takes: everything
/// after `--` reaches gh's underlying ssh untouched, so the keepalive posture is the
/// same one the SSH remote form uses. `BatchMode=yes` because nothing here has a tty
/// to answer a prompt — gh's own auth or fail fast.
pub fn sshValidationArgs(allocator: std.mem.Allocator, gh_path: []const u8, fields: Fields) ![][]u8 {
    try validate(fields);
    var args = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (args.items) |arg| allocator.free(arg);
        args.deinit();
    }
    try args.append(try allocator.dupe(u8, gh_path));
    try args.append(try allocator.dupe(u8, "codespace"));
    try args.append(try allocator.dupe(u8, "ssh"));
    try args.append(try allocator.dupe(u8, "-c"));
    try args.append(try allocator.dupe(u8, fields.name));
    try args.append(try allocator.dupe(u8, "--"));
    try args.append(try allocator.dupe(u8, "-o"));
    try args.append(try allocator.dupe(u8, "BatchMode=yes"));
    try args.append(try allocator.dupe(u8, "-o"));
    try args.append(try allocator.dupe(u8, "ConnectTimeout=10"));
    try args.append(try allocator.dupe(u8, "-o"));
    try args.append(try allocator.dupe(u8, "ServerAliveInterval=5"));
    try args.append(try allocator.dupe(u8, "-o"));
    try args.append(try allocator.dupe(u8, "ServerAliveCountMax=3"));
    const quoted_path = try shellQuote(allocator, fields.path);
    defer allocator.free(quoted_path);
    try args.append(try std.fmt.allocPrint(allocator, "git -C {s} rev-parse --show-toplevel", .{quoted_path}));
    return args.toOwnedSlice();
}

pub fn freeArgs(allocator: std.mem.Allocator, args: [][]u8) void {
    for (args) |arg| allocator.free(arg);
    allocator.free(args);
}

/// `owner/repo` from any of the ways a GitHub origin is written, and `null` for an
/// origin that isn't github.com — a repository no codespace link can be made for,
/// which is not an error. Anchored to the start: a bare substring match would take
/// `notgithub.com` too.
pub fn githubRepository(allocator: std.mem.Allocator, origin: []const u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, origin, " \t\r\n");
    const lowered = try std.ascii.allocLowerString(allocator, trimmed);
    defer allocator.free(lowered);
    const prefixes = [_][]const u8{
        "https://github.com/", "http://github.com/",
        "ssh://git@github.com/", "git://github.com/",
        "git@github.com:",
    };
    const prefix = for (prefixes) |candidate| {
        if (std.mem.startsWith(u8, lowered, candidate)) break candidate;
    } else return null;
    var slug = trimmed[prefix.len..];
    if (std.mem.endsWith(u8, slug, ".git")) slug = slug[0 .. slug.len - 4];
    slug = std.mem.trimRight(u8, slug, "/");
    const slash = std.mem.indexOfScalar(u8, slug, '/') orelse return null;
    const owner = slug[0..slash];
    const name = slug[slash + 1 ..];
    if (!isSafeSlugComponent(owner) or !isSafeSlugComponent(name)) return null;
    return try allocator.dupe(u8, slug);
}

fn isSafeSlugComponent(value: []const u8) bool {
    if (value.len == 0) return false;
    if (value[0] == '-' or value[0] == '.') return false;
    for (value) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, "-._", byte) == null) return false;
    }
    return true;
}

/// The `owner/repo` behind each open local project, deduplicated and order-preserving
/// — what the empty state's "create one" links point at.
pub fn repositorySuggestions(
    allocator: std.mem.Allocator,
    project_paths: []const []const u8,
) ![][]u8 {
    var found = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (found.items) |item| allocator.free(item);
        found.deinit();
    }
    for (project_paths) |path| {
        if (path.len == 0 or std.mem.indexOf(u8, path, "://") != null) continue;
        const origin = originURL(allocator, path) catch continue;
        defer allocator.free(origin);
        const repository = githubRepository(allocator, origin) catch continue orelse continue;
        var duplicate = false;
        for (found.items) |item| {
            if (std.mem.eql(u8, item, repository)) duplicate = true;
        }
        if (duplicate) {
            allocator.free(repository);
            continue;
        }
        try found.append(repository);
    }
    return found.toOwnedSlice();
}

fn originURL(allocator: std.mem.Allocator, project_path: []const u8) ![]u8 {
    const argv = [_][]const u8{ "git", "-C", project_path, "remote", "get-url", "origin" };
    var captured = try capture(allocator, &argv);
    defer captured.deinit(allocator);
    if (captured.status != 0) return error.NoOrigin;
    return allocator.dupe(u8, std.mem.trim(u8, captured.stdout, " \t\r\n"));
}

/// The GitHub create page for a repository, or the generic picker when there is no
/// repository to be specific about.
pub const create_url = "https://github.com/codespaces/new";

pub fn createURLFor(allocator: std.mem.Allocator, repository: []const u8) ![]u8 {
    if (repository.len == 0) return allocator.dupe(u8, create_url);
    return std.fmt.allocPrint(allocator, "https://codespaces.new/{s}", .{repository});
}

/// Where `gh.exe` is on Windows. `Child` never searches `PATH` for us in every spawn
/// posture, and the shell may run from a launcher with a trimmed environment, so an
/// absolute path is resolved once and reused. `GRAPHCODE_GH` is the explicit override
/// tests and unusual installs use.
pub fn locateGh(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "GRAPHCODE_GH")) |override| {
        if (override.len != 0 and isExecutableFile(override)) return override;
        allocator.free(override);
    } else |_| {}

    for ([_]struct { env: []const u8, suffix: []const u8 }{
        .{ .env = "ProgramFiles", .suffix = "GitHub CLI\\gh.exe" },
        .{ .env = "ProgramFiles(x86)", .suffix = "GitHub CLI\\gh.exe" },
        .{ .env = "LOCALAPPDATA", .suffix = "Programs\\GitHub CLI\\gh.exe" },
        .{ .env = "LOCALAPPDATA", .suffix = "Microsoft\\WinGet\\Links\\gh.exe" },
    }) |candidate| {
        const base = std.process.getEnvVarOwned(allocator, candidate.env) catch continue;
        defer allocator.free(base);
        const path = std.fs.path.join(allocator, &.{ base, candidate.suffix }) catch continue;
        if (isExecutableFile(path)) return path;
        allocator.free(path);
    }

    if (searchPath(allocator)) |path| return path;
    return error.GhNotInstalled;
}

fn searchPath(allocator: std.mem.Allocator) ?[]u8 {
    const path_value = std.process.getEnvVarOwned(allocator, "PATH") catch return null;
    defer allocator.free(path_value);
    var entries = std.mem.splitScalar(u8, path_value, ';');
    while (entries.next()) |entry| {
        const directory = std.mem.trim(u8, entry, " \"");
        if (directory.len == 0) continue;
        const candidate = std.fs.path.join(allocator, &.{ directory, "gh.exe" }) catch continue;
        if (isExecutableFile(candidate)) return candidate;
        allocator.free(candidate);
    }
    return null;
}

fn isExecutableFile(path: []const u8) bool {
    var file = std.fs.cwd().openFile(path, .{}) catch return false;
    defer file.close();
    const stat = file.stat() catch return false;
    return stat.kind == .file;
}

/// gh's `--json` answer, decoded into owned rows. Rows missing the fields the picker
/// needs are dropped rather than failing the whole list: one odd codespace must not
/// hide the rest.
pub fn parseList(allocator: std.mem.Allocator, json: []const u8) !CodespaceList {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch
        return error.UnreadableCodespaceList;
    defer parsed.deinit();
    const array = switch (parsed.value) {
        .array => |value| value,
        .null => return CodespaceList{ .allocator = allocator, .items = &.{} },
        else => return error.UnreadableCodespaceList,
    };
    var items = std.array_list.Managed(Codespace).init(allocator);
    errdefer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit();
    }
    for (array.items) |entry| {
        const object = switch (entry) {
            .object => |value| value,
            else => continue,
        };
        const name = stringField(object, "name") orelse continue;
        if (name.len == 0) continue;
        const repository = stringField(object, "repository") orelse "";
        const display_name = stringField(object, "displayName") orelse "";
        const state = stringField(object, "state") orelse "";
        var row = Codespace{
            .name = try allocator.dupe(u8, name),
            .display_name = try allocator.dupe(u8, display_name),
            .repository = try allocator.dupe(u8, repository),
            .state = try allocator.dupe(u8, if (state.len != 0) state else "Unknown"),
        };
        errdefer row.deinit(allocator);
        try items.append(row);
    }
    return CodespaceList{ .allocator = allocator, .items = try items.toOwnedSlice() };
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

pub const Captured = struct {
    status: u8,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: *Captured, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }
};

const capture_limit = 1024 * 1024;

/// Both pipes drained concurrently, then the exit awaited: a full pipe cannot wedge
/// the child, which is how a long `gh codespace list` deadlocked when only one was
/// read.
pub fn capture(allocator: std.mem.Allocator, argv: []const []const u8) !Captured {
    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    var out_buffer = std.array_list.Managed(u8).init(allocator);
    errdefer out_buffer.deinit();
    var err_buffer = std.array_list.Managed(u8).init(allocator);
    errdefer err_buffer.deinit();
    var out_thread = try std.Thread.spawn(.{}, drain, .{ &child.stdout.?, &out_buffer });
    var err_thread = try std.Thread.spawn(.{}, drain, .{ &child.stderr.?, &err_buffer });
    out_thread.join();
    err_thread.join();
    const status: u8 = switch (try child.wait()) {
        .Exited => |code| code,
        else => 255,
    };
    return .{
        .status = status,
        .stdout = try out_buffer.toOwnedSlice(),
        .stderr = try err_buffer.toOwnedSlice(),
    };
}

fn drain(file: *std.fs.File, sink: *std.array_list.Managed(u8)) void {
    var buffer: [4096]u8 = undefined;
    while (true) {
        const count = file.read(&buffer) catch return;
        if (count == 0) return;
        if (sink.items.len >= capture_limit) continue;
        sink.appendSlice(buffer[0..count]) catch return;
    }
}

/// Discovery. The gh-missing case is answered before any spawn so the dialog can say
/// what to install rather than surfacing a "file not found" from the process layer.
pub fn listCodespaces(allocator: std.mem.Allocator) !CodespaceList {
    const gh = locateGh(allocator) catch return error.GhNotInstalled;
    defer allocator.free(gh);
    const args = try listArgs(allocator, gh);
    defer freeArgs(allocator, args);
    var captured = capture(allocator, args) catch return error.CodespaceListFailed;
    defer captured.deinit(allocator);
    if (captured.status != 0) {
        return switch (classifyFailure(allocator, captured.stderr)) {
            .missing_codespace_scope => error.MissingCodespaceScope,
            .not_authenticated => error.GhNotAuthenticated,
            .network_unavailable => error.GitHubUnreachable,
            else => error.CodespaceListFailed,
        };
    }
    return parseList(allocator, captured.stdout) catch error.UnreadableCodespaceList;
}

pub fn listFailure(err: anyerror) Failure {
    return switch (err) {
        error.GhNotInstalled => .gh_missing,
        error.GhNotAuthenticated => .not_authenticated,
        error.MissingCodespaceScope => .missing_codespace_scope,
        error.GitHubUnreachable => .network_unavailable,
        error.UnreadableCodespaceList => .unreadable_list,
        else => .list_failed,
    };
}

/// Validation is the remote form's: a codespace that passes is one whose sessions can
/// start. A stopped codespace is started by this dial, which is why it is allowed to
/// take longer than an ordinary SSH check.
pub fn validateConnection(allocator: std.mem.Allocator, fields: Fields) !void {
    try validate(fields);
    const gh = locateGh(allocator) catch return error.GhNotInstalled;
    defer allocator.free(gh);
    const args = try sshValidationArgs(allocator, gh, fields);
    defer freeArgs(allocator, args);
    var captured = capture(allocator, args) catch return error.CodespaceValidationFailed;
    defer captured.deinit(allocator);
    if (captured.status != 0) return error.CodespaceValidationFailed;
}

/// The codespace's identity, stored beside the SSH remote's own record. Name and path
/// only: gh keeps the credential, and nothing token-shaped is ever written here.
pub fn saveConfig(allocator: std.mem.Allocator, fields: Fields) !void {
    try validate(fields);
    const base = std.process.getEnvVarOwned(allocator, "LOCALAPPDATA") catch
        try std.process.getEnvVarOwned(allocator, "USERPROFILE");
    defer allocator.free(base);
    const dir = try std.fs.path.join(allocator, &.{ base, "GraphCode" });
    defer allocator.free(dir);
    try std.fs.cwd().makePath(dir);
    const path = try std.fs.path.join(allocator, &.{ dir, "codespace.ini" });
    defer allocator.free(path);
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    const data = try std.fmt.allocPrint(allocator, "name={s}\npath={s}\n", .{ fields.name, fields.path });
    defer allocator.free(data);
    try file.writeAll(data);
}

/// Discovery on its own thread, polled by the dialog's timer: the message loop stays
/// responsive, so Cancel and Try Again are live while gh is still thinking.
pub const ListStatus = enum { loading, loaded, failed };

pub const ListOperation = struct {
    allocator: std.mem.Allocator,
    thread: std.Thread,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    abandoned: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    status: ListStatus = .loading,
    list: ?CodespaceList = null,
    failure: Failure = .list_failed,

    pub fn start(allocator: std.mem.Allocator) !*ListOperation {
        const operation = try allocator.create(ListOperation);
        errdefer allocator.destroy(operation);
        operation.* = .{ .allocator = allocator, .thread = undefined };
        operation.thread = try std.Thread.spawn(.{}, worker, .{operation});
        return operation;
    }

    pub fn poll(self: *ListOperation) ?ListStatus {
        if (!self.done.load(.acquire)) return null;
        return self.status;
    }

    /// The list the caller now owns; the operation keeps none of it.
    pub fn takeList(self: *ListOperation) ?CodespaceList {
        const list = self.list orelse return null;
        self.list = null;
        return list;
    }

    pub fn deinit(self: *ListOperation) void {
        self.thread.join();
        if (self.list) |*list| list.deinit();
        self.allocator.destroy(self);
    }

    fn worker(self: *ListOperation) void {
        if (listCodespaces(self.allocator)) |list| {
            self.list = list;
            self.status = .loaded;
        } else |err| {
            self.failure = listFailure(err);
            self.status = .failed;
        }
        self.done.store(true, .release);
    }
};

pub const ValidationStatus = enum { validating, succeeded, failed };

pub const ValidationOperation = struct {
    allocator: std.mem.Allocator,
    name: []u8,
    path: []u8,
    thread: std.Thread,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    status: ValidationStatus = .validating,

    pub fn start(allocator: std.mem.Allocator, fields: Fields) !*ValidationOperation {
        try validate(fields);
        const operation = try allocator.create(ValidationOperation);
        errdefer allocator.destroy(operation);
        const name = try allocator.dupe(u8, fields.name);
        errdefer allocator.free(name);
        const path = try allocator.dupe(u8, fields.path);
        errdefer allocator.free(path);
        operation.* = .{ .allocator = allocator, .name = name, .path = path, .thread = undefined };
        operation.thread = try std.Thread.spawn(.{}, worker, .{operation});
        return operation;
    }

    pub fn poll(self: *ValidationOperation) ?ValidationStatus {
        if (!self.done.load(.acquire)) return null;
        return self.status;
    }

    pub fn deinit(self: *ValidationOperation) void {
        self.thread.join();
        self.allocator.free(self.name);
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }

    fn worker(self: *ValidationOperation) void {
        validateConnection(self.allocator, .{ .name = self.name, .path = self.path }) catch {
            self.status = .failed;
            self.done.store(true, .release);
            return;
        };
        self.status = .succeeded;
        self.done.store(true, .release);
    }
};

test "codespace list decodes gh json and keeps gh's own state words" {
    const json =
        \\[{"name":"dev-widget-x5jq4w","displayName":"widget dev","repository":"octo/widget","state":"Available"},
        \\ {"name":"dev-widget-stopped","displayName":"","repository":"octo/widget","state":"Shutdown"}]
    ;
    var list = try parseList(std.testing.allocator, json);
    defer list.deinit();
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("dev-widget-x5jq4w", list.items[0].name);
    try std.testing.expectEqualStrings("Shutdown", list.items[1].state);

    const label = try list.items[0].rowLabel(std.testing.allocator);
    defer std.testing.allocator.free(label);
    try std.testing.expectEqualStrings("widget dev  —  octo/widget · Available", label);

    const fallback = try list.items[1].rowLabel(std.testing.allocator);
    defer std.testing.allocator.free(fallback);
    try std.testing.expectEqualStrings("dev-widget-stopped  —  octo/widget · Shutdown", fallback);
}

test "codespace list tolerates an empty answer and rejects a non-list one" {
    var empty = try parseList(std.testing.allocator, "[]");
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.items.len);

    var partial = try parseList(std.testing.allocator, "[{\"repository\":\"octo/widget\"},{\"name\":\"kept\"}]");
    defer partial.deinit();
    try std.testing.expectEqual(@as(usize, 1), partial.items.len);
    try std.testing.expectEqualStrings("kept", partial.items[0].name);
    try std.testing.expectEqualStrings("Unknown", partial.items[0].state);

    try std.testing.expectError(error.UnreadableCodespaceList, parseList(std.testing.allocator, "not json"));
}

test "default workspace path prefills the repository leaf" {
    const path = try defaultWorkspacePathFor(std.testing.allocator, "octo/widget");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/workspaces/widget", path);

    const bare = try defaultWorkspacePathFor(std.testing.allocator, "widget");
    defer std.testing.allocator.free(bare);
    try std.testing.expectEqualStrings("/workspaces/widget", bare);
}

test "gh scope failure carries its own remediation" {
    const scope_error =
        "error getting codespaces: HTTP 403: Must have admin rights to Repository.\n" ++
        "This API operation needs the \"codespace\" scope. To request it, run:  " ++
        "gh auth refresh -h github.com -s codespace\n";
    try std.testing.expectEqual(
        Failure.missing_codespace_scope,
        classifyFailure(std.testing.allocator, scope_error),
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        failureMessage(.missing_codespace_scope),
        "gh auth refresh -h github.com -s codespace",
    ) != null);
    try std.testing.expectEqual(
        Failure.not_authenticated,
        classifyFailure(std.testing.allocator, "To get started with GitHub CLI, please run: gh auth login"),
    );
    try std.testing.expectEqual(
        Failure.network_unavailable,
        classifyFailure(std.testing.allocator, "Get \"https://api.github.com\": dial tcp: lookup api.github.com"),
    );
    try std.testing.expectEqual(
        Failure.list_failed,
        classifyFailure(std.testing.allocator, "something else entirely"),
    );
    try std.testing.expectEqual(Failure.gh_missing, listFailure(error.GhNotInstalled));
    try std.testing.expectEqual(Failure.missing_codespace_scope, listFailure(error.MissingCodespaceScope));
}

test "surfaced gh output never carries a credential or control characters" {
    const raw = "denied for gho_0123456789abcdefABCDEF token\r\nand github_pat_11ABCDE_secretpart too";
    const safe = try sanitizeMessage(std.testing.allocator, raw);
    defer std.testing.allocator.free(safe);
    try std.testing.expect(std.mem.indexOf(u8, safe, "gho_") == null);
    try std.testing.expect(std.mem.indexOf(u8, safe, "github_pat_") == null);
    try std.testing.expect(std.mem.indexOf(u8, safe, "secretpart") == null);
    try std.testing.expect(std.mem.indexOf(u8, safe, "<redacted>") != null);
    try std.testing.expect(std.mem.indexOfAny(u8, safe, "\r\n") == null);

    var long = std.array_list.Managed(u8).init(std.testing.allocator);
    defer long.deinit();
    try long.appendNTimes('x', 900);
    const bounded = try sanitizeMessage(std.testing.allocator, long.items);
    defer std.testing.allocator.free(bounded);
    try std.testing.expectEqual(@as(usize, message_limit), bounded.len);
}

test "codespace identities reject injection-shaped names and relative paths" {
    try std.testing.expectError(error.InvalidCodespaceName, validate(.{ .name = "-oProxyCommand=x", .path = "/workspaces/widget" }));
    try std.testing.expectError(error.InvalidCodespaceName, validate(.{ .name = "dev widget", .path = "/workspaces/widget" }));
    try std.testing.expectError(error.AbsolutePathRequired, validate(.{ .name = "dev-widget", .path = "workspaces/widget" }));
    try std.testing.expectError(error.InvalidCodespacePath, validate(.{ .name = "dev-widget", .path = "/workspaces/wid\nget" }));
    try std.testing.expectError(error.MissingCodespaceName, validate(.{ .name = "", .path = "/workspaces/widget" }));
    try validate(.{ .name = "dev-widget-x5jq4w", .path = "/workspaces/widget" });
}

test "codespace project URI percent-encodes the path and keeps the name verbatim" {
    const uri = try projectURI(std.testing.allocator, .{
        .name = "dev-widget-x5jq4w",
        .path = "/workspaces/repo name/#q?x%雪",
    });
    defer std.testing.allocator.free(uri);
    try std.testing.expectEqualStrings(
        "codespace://dev-widget-x5jq4w/workspaces/repo%20name/%23q%3Fx%25%E9%9B%AA",
        uri,
    );
}

test "codespace validation argv dials through gh with one quoted remote command" {
    const args = try sshValidationArgs(std.testing.allocator, "C:\\gh\\gh.exe", .{
        .name = "dev-widget-x5jq4w",
        .path = "/workspaces/граф",
    });
    defer freeArgs(std.testing.allocator, args);
    try std.testing.expectEqualStrings("C:\\gh\\gh.exe", args[0]);
    try std.testing.expectEqualStrings("codespace", args[1]);
    try std.testing.expectEqualStrings("ssh", args[2]);
    try std.testing.expectEqualStrings("-c", args[3]);
    try std.testing.expectEqualStrings("dev-widget-x5jq4w", args[4]);
    try std.testing.expectEqualStrings("--", args[5]);
    try std.testing.expectEqualStrings("BatchMode=yes", args[7]);
    try std.testing.expectEqualStrings(
        "git -C '/workspaces/граф' rev-parse --show-toplevel",
        args[args.len - 1],
    );
}

test "codespace validation argv quotes shell metacharacters in the path" {
    const args = try sshValidationArgs(std.testing.allocator, "gh.exe", .{
        .name = "dev-widget",
        .path = "/workspaces/a;$(touch p)'q",
    });
    defer freeArgs(std.testing.allocator, args);
    try std.testing.expectEqualStrings(
        "git -C '/workspaces/a;$(touch p)'\\''q' rev-parse --show-toplevel",
        args[args.len - 1],
    );
}

test "codespace list argv asks gh for every codespace and only the picker's fields" {
    const args = try listArgs(std.testing.allocator, "gh.exe");
    defer freeArgs(std.testing.allocator, args);
    try std.testing.expectEqualStrings("--limit", args[3]);
    try std.testing.expectEqualStrings("500", args[4]);
    try std.testing.expectEqualStrings("name,displayName,repository,state", args[6]);
}

test "github origins resolve to owner/repo and non-GitHub origins do not" {
    for ([_][]const u8{
        "https://github.com/octo/widget.git",
        "git@github.com:octo/widget.git",
        "ssh://git@github.com/octo/widget",
        "HTTPS://GitHub.com/octo/widget/",
    }) |origin| {
        const repository = (try githubRepository(std.testing.allocator, origin)) orelse
            return error.TestUnexpectedResult;
        defer std.testing.allocator.free(repository);
        try std.testing.expectEqualStrings("octo/widget", repository);
    }
    try std.testing.expectEqual(
        @as(?[]u8, null),
        try githubRepository(std.testing.allocator, "https://notgithub.com/octo/widget.git"),
    );
    try std.testing.expectEqual(
        @as(?[]u8, null),
        try githubRepository(std.testing.allocator, "https://github.com/octo"),
    );
    try std.testing.expectEqual(
        @as(?[]u8, null),
        try githubRepository(std.testing.allocator, "https://github.com/-octo/wid;get"),
    );
}

test "create links prefer the repository and fall back to the GitHub picker" {
    const specific = try createURLFor(std.testing.allocator, "octo/widget");
    defer std.testing.allocator.free(specific);
    try std.testing.expectEqualStrings("https://codespaces.new/octo/widget", specific);

    const generic = try createURLFor(std.testing.allocator, "");
    defer std.testing.allocator.free(generic);
    try std.testing.expectEqualStrings("https://github.com/codespaces/new", generic);
}

test "validation messages name the field a human has to change" {
    try std.testing.expectEqualStrings(
        "Choose a codespace from the list.",
        validationMessage(error.MissingCodespaceName),
    );
    try std.testing.expectEqualStrings(
        "Repository path must be absolute and begin with /.",
        validationMessage(error.AbsolutePathRequired),
    );
}
