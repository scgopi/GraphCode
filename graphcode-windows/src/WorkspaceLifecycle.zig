const std = @import("std");

pub const directory_prefix = ".graphcode-";
pub const default_directory_name = ".graphcode";
pub const max_name_length: usize = 48;

pub const Workspace = struct {
    name: []const u8,
    path: []const u8,
    identity: []const u8,
    is_default: bool,
    created_at: ?i64 = null,

    pub fn deinit(self: *Workspace, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
        allocator.free(self.identity);
        self.* = undefined;
    }
};

pub fn copyWorkspace(allocator: std.mem.Allocator, workspace: Workspace) !Workspace {
    const name = try allocator.dupe(u8, workspace.name);
    errdefer allocator.free(name);
    const path = try allocator.dupe(u8, workspace.path);
    errdefer allocator.free(path);
    const identity = try pathIdentity(allocator, path);
    errdefer allocator.free(identity);
    if (!std.mem.eql(u8, identity, workspace.identity)) return error.WorkspaceIdentityChanged;
    return .{
        .name = name,
        .path = path,
        .identity = identity,
        .is_default = workspace.is_default,
        .created_at = workspace.created_at,
    };
}

/// Manager order is independent of the existing menu/cycling order.
pub fn managerListFromHome(allocator: std.mem.Allocator, home: []const u8, current: []const u8) !List {
    var found = try listFromHome(allocator, home);
    defer found.deinit(allocator);
    for (found.items) |*workspace| {
        workspace.created_at = directoryCreationTime(workspace.path) catch null;
    }
    return managerList(allocator, found.items, home, current);
}

pub fn managerList(allocator: std.mem.Allocator, known: []const Workspace, home: []const u8, current: []const u8) !List {
    var values = std.array_list.Managed(Workspace).init(allocator);
    errdefer {
        for (values.items) |*workspace| workspace.deinit(allocator);
        values.deinit();
    }
    for (known) |workspace| {
        var owned = try copyWorkspace(allocator, workspace);
        errdefer owned.deinit(allocator);
        for (values.items) |existing| {
            if (std.mem.eql(u8, existing.identity, owned.identity)) break;
        } else {
            try values.append(owned);
            continue;
        }
        owned.deinit(allocator);
    }
    std.sort.block(Workspace, values.items, {}, managerLessThan);
    const identity = try pathIdentity(allocator, current);
    defer allocator.free(identity);
    for (values.items) |workspace| {
        if (std.mem.eql(u8, workspace.identity, identity)) break;
    } else {
        const default_path = try std.fs.path.join(allocator, &.{ home, default_directory_name });
        defer allocator.free(default_path);
        const default_identity = try pathIdentity(allocator, default_path);
        defer allocator.free(default_identity);
        const is_default = std.mem.eql(u8, identity, default_identity);
        const resolved = try std.fs.path.resolveWindows(allocator, &.{current});
        defer allocator.free(resolved);
        const base = std.fs.path.basenameWindows(resolved);
        const name = if (is_default) "Default" else if (std.mem.startsWith(u8, base, directory_prefix))
            base[directory_prefix.len..]
        else
            base;
        var owned = try copyWorkspace(allocator, .{
            .name = name,
            .path = current,
            .identity = identity,
            .is_default = is_default,
        });
        errdefer owned.deinit(allocator);
        try values.append(owned);
    }
    return .{ .items = try values.toOwnedSlice() };
}

fn managerLessThan(_: void, left: Workspace, right: Workspace) bool {
    if (left.is_default != right.is_default) return left.is_default;
    if (left.created_at != right.created_at) {
        if (left.created_at == null) return false;
        if (right.created_at == null) return true;
        return left.created_at.? < right.created_at.?;
    }
    return std.mem.lessThan(u8, left.name, right.name);
}

fn directoryCreationTime(path: []const u8) !i64 {
    var directory = try std.fs.openDirAbsolute(path, .{ .no_follow = true });
    defer directory.close();
    const w = std.os.windows;
    var info: w.FILE_BASIC_INFORMATION = undefined;
    var io: w.IO_STATUS_BLOCK = undefined;
    const status = w.ntdll.NtQueryInformationFile(directory.fd, &io, &info, @sizeOf(@TypeOf(info)), .FileBasicInformation);
    if (status != .SUCCESS) return error.CreationTimeUnavailable;
    return info.CreationTime;
}

pub const List = struct {
    items: []Workspace,

    pub fn deinit(self: *List, allocator: std.mem.Allocator) void {
        for (self.items) |*workspace| workspace.deinit(allocator);
        allocator.free(self.items);
        self.* = undefined;
    }
};

pub const NameError = error{
    EmptyName,
    InvalidName,
    NameTooLong,
    NameTaken,
};

pub fn defaultPath(allocator: std.mem.Allocator) ![]u8 {
    const home = std.process.getEnvVarOwned(allocator, "USERPROFILE") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return error.UserProfileMissing,
        else => return err,
    };
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, default_directory_name });
}

pub fn currentPath(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "GRAPHCODE_SUPPORT_DIR")) |value| {
        defer allocator.free(value);
        if (value.len != 0) return resolvePath(allocator, value);
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => return err,
    }
    return defaultPath(allocator);
}

pub fn normalizeName(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();
    var previous_dash = false;
    for (input) |byte| {
        if (std.ascii.isAlphanumeric(byte)) {
            try result.append(std.ascii.toLower(byte));
            previous_dash = false;
        } else if (!previous_dash and result.items.len != 0) {
            try result.append('-');
            previous_dash = true;
        }
    }
    while (result.items.len != 0 and result.items[result.items.len - 1] == '-') {
        _ = result.pop();
    }
    if (result.items.len == 0) return NameError.EmptyName;
    if (result.items.len > max_name_length) return NameError.NameTooLong;
    return result.toOwnedSlice();
}

pub fn validateName(
    allocator: std.mem.Allocator,
    input: []const u8,
    home: []const u8,
) ![]u8 {
    const name = try normalizeName(allocator, input);
    errdefer allocator.free(name);
    const path = try workspacePath(allocator, name, home);
    defer allocator.free(path);
    std.fs.cwd().access(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return name,
        else => return err,
    };
    return NameError.NameTaken;
}

pub fn workspacePath(
    allocator: std.mem.Allocator,
    name: []const u8,
    home: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}\\{s}{s}", .{ home, directory_prefix, name });
}

pub fn create(allocator: std.mem.Allocator, input: []const u8, home: []const u8) !Workspace {
    const name = try validateName(allocator, input, home);
    errdefer allocator.free(name);
    const path = try workspacePath(allocator, name, home);
    errdefer allocator.free(path);
    const identity = try pathIdentity(allocator, path);
    errdefer allocator.free(identity);
    try std.fs.makeDirAbsolute(path);
    return .{ .name = name, .path = path, .identity = identity, .is_default = false };
}

pub fn resolvePath(allocator: std.mem.Allocator, configured: []const u8) ![]u8 {
    if (isAbsoluteWindowsPath(configured)) return allocator.dupe(u8, configured);
    const home = std.process.getEnvVarOwned(allocator, "USERPROFILE") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return error.UserProfileMissing,
        else => return err,
    };
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, configured });
}

pub fn list(allocator: std.mem.Allocator) !List {
    const home = std.process.getEnvVarOwned(allocator, "USERPROFILE") catch
        return error.UserProfileMissing;
    defer allocator.free(home);
    return listFromHome(allocator, home);
}

pub fn listFromHome(allocator: std.mem.Allocator, home: []const u8) !List {
    var values = std.array_list.Managed(Workspace).init(allocator);
    errdefer {
        for (values.items) |*workspace| workspace.deinit(allocator);
        values.deinit();
    }
    try appendWorkspace(allocator, &values, home, default_directory_name, "Default", true);
    var directory = std.fs.openDirAbsolute(home, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return .{ .items = try values.toOwnedSlice() },
        else => return err,
    };
    defer directory.close();
    var iterator = directory.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .directory or !std.mem.startsWith(u8, entry.name, directory_prefix))
            continue;
        const suffix = entry.name[directory_prefix.len..];
        if (suffix.len == 0) continue;
        try appendWorkspace(allocator, &values, home, entry.name, suffix, false);
    }
    std.sort.block(Workspace, values.items, {}, lessThan);
    return .{ .items = try values.toOwnedSlice() };
}

fn appendWorkspace(
    allocator: std.mem.Allocator,
    values: *std.array_list.Managed(Workspace),
    home: []const u8,
    directory_name: []const u8,
    name: []const u8,
    is_default: bool,
) !void {
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    const path = try std.fs.path.join(allocator, &.{ home, directory_name });
    errdefer allocator.free(path);
    const identity = try pathIdentity(allocator, path);
    errdefer allocator.free(identity);
    try values.append(.{ .name = owned_name, .path = path, .identity = identity, .is_default = is_default });
}

pub fn directoryExists(path: []const u8) bool {
    var directory = std.fs.openDirAbsolute(path, .{}) catch return false;
    directory.close();
    return true;
}

pub fn isAbsoluteWindowsPath(path: []const u8) bool {
    return (path.len >= 2 and path[1] == ':') or
        (path.len >= 2 and path[0] == '\\' and path[1] == '\\') or
        (path.len >= 2 and path[0] == '/' and path[1] == '/');
}

pub fn pathIdentity(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const parsed = std.fs.path.windowsParsePath(path);
    if (!parsed.is_abs or parsed.kind == .None or std.mem.indexOfScalar(u8, path, 0) != null or
        !std.unicode.utf8ValidateSlice(path)) return error.InvalidWorkspacePath;
    const identity = try std.fs.path.resolveWindows(allocator, &.{path});
    for (identity) |*byte| {
        byte.* = if (byte.* == '\\') '/' else std.ascii.toLower(byte.*);
    }
    return identity;
}

pub fn instanceName(allocator: std.mem.Allocator, user: []const u8, path: []const u8) ![]u8 {
    const identity = try pathIdentity(allocator, path);
    defer allocator.free(identity);
    return legacyInstanceName(allocator, user, identity);
}

pub fn legacyInstanceName(allocator: std.mem.Allocator, user: []const u8, path: []const u8) ![]u8 {
    if (user.len == 0 or path.len == 0) return error.InvalidWorkspaceIdentity;
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(path, &digest, .{});
    const digest_text = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "Local\\graphcode-windows-{s}-{s}", .{ user, digest_text[0..20] });
}

fn lessThan(_: void, left: Workspace, right: Workspace) bool {
    return std.ascii.lessThanIgnoreCase(left.name, right.name);
}

test "workspace manager ordering uses Default creation time ordinal ties unknown last then outside current" {
    const known = [_]Workspace{
        .{ .name = "late", .path = "C:\\fixture\\.graphcode-late", .identity = "c:/fixture/.graphcode-late", .is_default = false },
        .{ .name = "beta", .path = "C:\\fixture\\.graphcode-beta", .identity = "c:/fixture/.graphcode-beta", .is_default = false, .created_at = 2 },
        .{ .name = "alpha", .path = "C:\\fixture\\.graphcode-alpha", .identity = "c:/fixture/.graphcode-alpha", .is_default = false, .created_at = 2 },
        .{ .name = "old", .path = "C:\\fixture\\.graphcode-old", .identity = "c:/fixture/.graphcode-old", .is_default = false, .created_at = 1 },
        .{ .name = "Default", .path = "C:\\fixture\\.graphcode", .identity = "c:/fixture/.graphcode", .is_default = true },
        .{ .name = "alias", .path = "c:/FIXTURE/.graphcode-alpha/", .identity = "c:/fixture/.graphcode-alpha", .is_default = false },
    };
    var found = try managerList(std.testing.allocator, &known, "C:\\fixture", "C:\\Outside\\Workspace");
    defer found.deinit(std.testing.allocator);
    const expected = [_][]const u8{ "Default", "old", "alpha", "beta", "late", "Workspace" };
    try std.testing.expectEqual(expected.len, found.items.len);
    for (expected, found.items) |name, workspace| try std.testing.expectEqualStrings(name, workspace.name);
    var current_inside = try managerList(std.testing.allocator, &known, "C:\\fixture", "c:/fixture/.graphcode-alpha/");
    defer current_inside.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 5), current_inside.items.len);
}

test "workspace manager listing owns long unicode names and cleans allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, managerOwnershipCase, .{});
}

fn managerOwnershipCase(allocator: std.mem.Allocator) !void {
    const name = "Workspace-\xe5\xb7\xa5\xe4\xbd\x9c-" ** 30;
    const path = "C:\\fixture\\" ++ name;
    const identity = try pathIdentity(allocator, path);
    defer allocator.free(identity);
    const item = Workspace{ .name = name, .path = path, .identity = identity, .is_default = false };
    var found = try managerList(allocator, &.{item}, "C:\\fixture", path);
    defer found.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), found.items.len);
    try std.testing.expectEqualStrings(name, found.items[0].name);
    try std.testing.expectEqualStrings(path, found.items[0].path);
}

test "workspace manager creation metadata only reads explicitly owned fixture" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.makeDir(".graphcode-new");
    const home = try temporary.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(home);
    var found = try managerListFromHome(std.testing.allocator, home, home);
    defer found.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), found.items.len);
    try std.testing.expect(found.items[0].is_default);
    try std.testing.expect(found.items[1].created_at != null);
}

test "workspace names normalize to safe stable directory suffixes" {
    const name = try normalizeName(std.testing.allocator, "Café / Zürich");
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("caf-z-rich", name);
}

test "workspace validation rejects long names" {
    var long_name: [max_name_length + 2]u8 = undefined;
    @memset(&long_name, 'x');
    try std.testing.expectError(NameError.NameTooLong, normalizeName(std.testing.allocator, &long_name));
}

test "workspace paths use the Windows sibling convention" {
    const path = try workspacePath(std.testing.allocator, "alpha", "C:\\Users\\tester");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("C:\\Users\\tester\\.graphcode-alpha", path);
}

test "workspace enumeration owns every allocation including partial entries" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.makeDir(".graphcode-alpha");
    try temporary.dir.makeDir(".graphcode-beta");
    try temporary.dir.makeDir("unrelated");
    try temporary.dir.writeFile(.{ .sub_path = ".graphcode-not-a-directory", .data = "sentinel" });
    const home = try temporary.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(home);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkWorkspaceList, .{home});
}

fn checkWorkspaceList(allocator: std.mem.Allocator, home: []const u8) !void {
    var found = try listFromHome(allocator, home);
    defer found.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), found.items.len);
    try std.testing.expectEqualStrings("alpha", found.items[0].name);
    try std.testing.expectEqualStrings("beta", found.items[1].name);
    try std.testing.expectEqualStrings("Default", found.items[2].name);
    try std.testing.expect(found.items[2].is_default);
    for (found.items[0..2]) |workspace| try std.testing.expect(!workspace.is_default);
}

test "workspace validation rejects directory and file collisions" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.makeDir(".graphcode-existing");
    try temporary.dir.writeFile(.{ .sub_path = ".graphcode-file", .data = "do-not-overwrite" });
    const home = try temporary.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(home);
    try std.testing.expectError(error.NameTaken, validateName(std.testing.allocator, "Existing", home));
    try std.testing.expectError(error.NameTaken, validateName(std.testing.allocator, "file", home));
    const contents = try temporary.dir.readFileAlloc(std.testing.allocator, ".graphcode-file", 100);
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("do-not-overwrite", contents);
}

test "workspace normalization cannot turn input into a traversal path" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "", "...", "/\\", " \t\r\n" }) |input| {
        try std.testing.expectError(error.EmptyName, normalizeName(allocator, input));
    }
    const name = try normalizeName(allocator, "..\\..//Outside workspace");
    defer allocator.free(name);
    try std.testing.expectEqualStrings("outside-workspace", name);
    const path = try workspacePath(allocator, name, "C:\\fixture");
    defer allocator.free(path);
    try std.testing.expectEqualStrings("C:\\fixture\\.graphcode-outside-workspace", path);
}

test "workspace identity normalizes lexical Windows aliases without changing non ASCII bytes" {
    const allocator = std.testing.allocator;
    const expected = "c:/users/test/.graphcode-alpha";
    for ([_][]const u8{
        "C:\\Users\\Test\\.graphcode-alpha",
        "c:/users/TEST/.graphcode-alpha/",
        "C:\\Users\\Test\\ignored\\..\\.\\.graphcode-alpha\\",
    }) |path| {
        const identity = try pathIdentity(allocator, path);
        defer allocator.free(identity);
        try std.testing.expectEqualStrings(expected, identity);
        const name = try instanceName(allocator, "fixture", path);
        defer allocator.free(name);
        const canonical_name = try instanceName(allocator, "fixture", expected);
        defer allocator.free(canonical_name);
        try std.testing.expectEqualStrings(canonical_name, name);
    }
    const distinct = try pathIdentity(allocator, "C:\\Users\\Test\\.graphcode-beta");
    defer allocator.free(distinct);
    try std.testing.expect(!std.mem.eql(u8, expected, distinct));
    const unicode = try pathIdentity(allocator, "C:\\Users\\\xc3\x9cber\\.graphcode-alpha");
    defer allocator.free(unicode);
    try std.testing.expectEqualStrings("c:/users/\xc3\x9cber/.graphcode-alpha", unicode);
    const lower_unicode = try pathIdentity(allocator, "C:\\Users\\\xc3\xbcber\\.graphcode-alpha");
    defer allocator.free(lower_unicode);
    try std.testing.expect(!std.mem.eql(u8, unicode, lower_unicode));
    const network = try pathIdentity(allocator, "\\\\Server\\Share\\nested\\..\\.graphcode-alpha\\");
    defer allocator.free(network);
    try std.testing.expectEqualStrings("//server/share/.graphcode-alpha", network);
}

test "workspace identity rejects absent relative and malformed paths" {
    for ([_][]const u8{ "", "relative", "C:relative", "\\relative", "C:\\bad\x00path", "C:\\\xff" }) |path| {
        try std.testing.expectError(error.InvalidWorkspacePath, pathIdentity(std.testing.allocator, path));
    }
    try std.testing.expectError(error.InvalidWorkspaceIdentity, instanceName(std.testing.allocator, "", "C:\\fixture"));
}

test "workspace instance identities release partial allocations" {
    const Probe = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const name = try instanceName(allocator, "fixture", "C:\\Users\\Test\\ignored\\..\\.graphcode-alpha\\");
            defer allocator.free(name);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{});
}

test "workspace creation normalizes safely and refuses invalid or colliding targets" {
    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const home = try temporary.dir.realpathAlloc(allocator, ".");
    defer allocator.free(home);
    try temporary.dir.writeFile(.{ .sub_path = "unrelated", .data = "untouched" });
    var created = try create(allocator, "..\\..//My workspace", home);
    defer created.deinit(allocator);
    try std.testing.expectEqualStrings("my-workspace", created.name);
    var directory = try std.fs.openDirAbsolute(created.path, .{});
    directory.close();
    try std.testing.expectError(error.NameTaken, create(allocator, "My workspace", home));
    try std.testing.expectError(error.EmptyName, create(allocator, "...", home));
    const untouched = try temporary.dir.readFileAlloc(allocator, "unrelated", 100);
    defer allocator.free(untouched);
    try std.testing.expectEqualStrings("untouched", untouched);
    var listed = try listFromHome(allocator, home);
    defer listed.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), listed.items.len);
}

test "workspace creation allocates before creating any directory" {
    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const home = try temporary.dir.realpathAlloc(allocator, ".");
    defer allocator.free(home);
    const destination = try workspacePath(allocator, "created", home);
    defer allocator.free(destination);
    const Probe = struct {
        fn run(failing: std.mem.Allocator, parent: []const u8, path: []const u8) !void {
            var created = create(failing, "created", parent) catch |err| {
                std.fs.cwd().access(path, .{}) catch |access_error| switch (access_error) {
                    error.FileNotFound => return err,
                    else => return access_error,
                };
                return error.DirectoryCreatedBeforeAllocationCompleted;
            };
            defer created.deinit(failing);
            try std.fs.deleteDirAbsolute(created.path);
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Probe.run, .{ home, destination });
}
