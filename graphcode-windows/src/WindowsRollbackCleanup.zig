const std = @import("std");
const c = @import("Win32.zig").c;

const rollback_prefix = ".GraphCode-rollback-";
const marker_suffix = ".cleanup-ready";
const retry_count = 4;
const retry_delay_ns = 500 * std.time.ns_per_ms;

pub const Result = struct {
    deleted: usize = 0,
    locked: usize = 0,
    failed: usize = 0,
    orphan_markers: usize = 0,

    fn pending(self: Result) bool {
        return self.locked != 0 or self.failed != 0;
    }
};

const Outcome = enum {
    deleted,
    locked,
    failed,
    orphan_marker,
    skipped,
};

const DeleteApi = struct {
    context: ?*anyopaque = null,
    deleteTree: *const fn (context: ?*anyopaque, path: []const u8) anyerror!void = deleteTree,
};

fn deleteTree(_: ?*anyopaque, path: []const u8) !void {
    try std.fs.deleteTreeAbsolute(path);
}

pub fn start(allocator: std.mem.Allocator) void {
    const thread = std.Thread.spawn(.{}, cleanupWorker, .{allocator}) catch |err| {
        std.log.warn("Unable to start committed rollback cleanup: {s}", .{@errorName(err)});
        return;
    };
    thread.detach();
}

fn cleanupWorker(allocator: std.mem.Allocator) void {
    var attempt: usize = 0;
    while (attempt < retry_count) : (attempt += 1) {
        const result = cleanupInstalled(allocator) catch |err| {
            std.log.warn("Committed rollback cleanup failed: {s}", .{@errorName(err)});
            return;
        };
        if (!result.pending()) return;
        if (attempt + 1 < retry_count) std.Thread.sleep(retry_delay_ns);
    }
}

pub fn cleanupInstalled(allocator: std.mem.Allocator) !Result {
    const parent = try installedParent(allocator) orelse return .{};
    defer allocator.free(parent);
    return cleanupParent(allocator, parent);
}

fn installedParent(allocator: std.mem.Allocator) !?[]u8 {
    const executable = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(executable);
    const bin = std.fs.path.dirnameWindows(executable) orelse return null;
    if (!std.ascii.eqlIgnoreCase(std.fs.path.basenameWindows(bin), "bin")) return null;
    const install_root = std.fs.path.dirnameWindows(bin) orelse return null;
    if (!std.ascii.eqlIgnoreCase(std.fs.path.basenameWindows(install_root), "current")) return null;
    const setup = try std.fs.path.join(allocator, &.{ install_root, "GraphCode-Setup.ps1" });
    defer allocator.free(setup);
    std.fs.accessAbsolute(setup, .{}) catch return null;
    const parent = std.fs.path.dirnameWindows(install_root) orelse return null;
    return try allocator.dupe(u8, parent);
}

pub fn cleanupParent(allocator: std.mem.Allocator, parent: []const u8) !Result {
    var result = Result{};
    var directory = try std.fs.openDirAbsolute(parent, .{ .iterate = true, .no_follow = true });
    defer directory.close();
    var iterator = directory.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .file or !validMarkerName(entry.name)) continue;
        switch (try cleanupMarker(allocator, parent, entry.name)) {
            .deleted => result.deleted += 1,
            .locked => result.locked += 1,
            .failed => result.failed += 1,
            .orphan_marker => result.orphan_markers += 1,
            .skipped => {},
        }
    }
    return result;
}

fn validMarkerName(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, rollback_prefix) or !std.mem.endsWith(u8, name, marker_suffix)) return false;
    const rollback_name = name[0 .. name.len - marker_suffix.len];
    if (rollback_name.len != rollback_prefix.len + 36) return false;
    const guid = rollback_name[rollback_prefix.len..];
    for (guid, 0..) |character, index| {
        const hyphen = index == 8 or index == 13 or index == 18 or index == 23;
        if (hyphen) {
            if (character != '-') return false;
        } else if (!std.ascii.isHex(character)) {
            return false;
        }
    }
    return true;
}

fn cleanupMarker(
    allocator: std.mem.Allocator,
    parent: []const u8,
    marker_name: []const u8,
) !Outcome {
    return cleanupMarkerWith(allocator, parent, marker_name, .{});
}

fn cleanupMarkerWith(
    allocator: std.mem.Allocator,
    parent: []const u8,
    marker_name: []const u8,
    delete_api: DeleteApi,
) !Outcome {
    const marker_path = try std.fs.path.join(allocator, &.{ parent, marker_name });
    defer allocator.free(marker_path);
    const lease = openExclusive(allocator, marker_path, false) catch |err| return switch (err) {
        error.FileNotFound => .skipped,
        error.SharingViolation, error.LockViolation => .locked,
        else => .failed,
    };
    var lease_open = true;
    defer {
        if (lease_open) _ = c.CloseHandle(lease);
    }

    const rollback_name = marker_name[0 .. marker_name.len - marker_suffix.len];
    const rollback_path = try std.fs.path.join(allocator, &.{ parent, rollback_name });
    defer allocator.free(rollback_path);
    {
        var rollback = std.fs.openDirAbsolute(rollback_path, .{ .iterate = true, .no_follow = true }) catch |err| switch (err) {
            error.FileNotFound => {
                _ = c.CloseHandle(lease);
                lease_open = false;
                return removeMarker(marker_path, .orphan_marker);
            },
            else => return .failed,
        };
        defer rollback.close();

        var walker = rollback.walk(allocator) catch return .failed;
        defer walker.deinit();
        while (walker.next() catch return .failed) |entry| {
            switch (entry.kind) {
                .file => {
                    const file_path = try std.fs.path.join(allocator, &.{ rollback_path, entry.path });
                    defer allocator.free(file_path);
                    const handle = openExclusive(allocator, file_path, true) catch |err| return switch (err) {
                        error.SharingViolation, error.LockViolation => .locked,
                        else => .failed,
                    };
                    _ = c.CloseHandle(handle);
                },
                .directory => {},
                else => return .failed,
            }
        }
    }
    delete_api.deleteTree(delete_api.context, rollback_path) catch |err| switch (err) {
        error.FileNotFound => {},
        error.AccessDenied, error.FileBusy => return .locked,
        else => return .failed,
    };
    _ = c.CloseHandle(lease);
    lease_open = false;
    return removeMarker(marker_path, .deleted);
}

fn removeMarker(marker_path: []const u8, outcome: Outcome) Outcome {
    std.fs.deleteFileAbsolute(marker_path) catch |err| switch (err) {
        error.FileNotFound => return outcome,
        else => return .failed,
    };
    return outcome;
}

fn openExclusive(allocator: std.mem.Allocator, path: []const u8, writable: bool) !c.HANDLE {
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(allocator, path);
    defer allocator.free(wide);
    const attributes = c.GetFileAttributesW(wide.ptr);
    if (attributes == c.INVALID_FILE_ATTRIBUTES) return lastFileError();
    const access: c.DWORD = if (writable and attributes & c.FILE_ATTRIBUTE_READONLY == 0)
        c.GENERIC_READ | c.GENERIC_WRITE
    else
        c.GENERIC_READ;
    const handle = c.CreateFileW(
        wide.ptr,
        access,
        0,
        null,
        c.OPEN_EXISTING,
        c.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (handle == c.INVALID_HANDLE_VALUE) return lastFileError();
    return handle;
}

fn lastFileError() anyerror {
    return switch (c.GetLastError()) {
        c.ERROR_FILE_NOT_FOUND, c.ERROR_PATH_NOT_FOUND => error.FileNotFound,
        c.ERROR_SHARING_VIOLATION => error.SharingViolation,
        c.ERROR_LOCK_VIOLATION => error.LockViolation,
        c.ERROR_ACCESS_DENIED => error.AccessDenied,
        else => error.UnexpectedFileError,
    };
}

fn writeFixture(dir: std.fs.Dir, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try dir.makePath(parent);
    try dir.writeFile(.{ .sub_path = path, .data = data });
}

test "successful update rollback cleanup deletes only committed backups" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const parent = try temporary.dir.realpathAlloc(allocator, ".");
    defer allocator.free(parent);
    const committed = rollback_prefix ++ "11111111-1111-1111-1111-111111111111";
    const recovery = rollback_prefix ++ "22222222-2222-2222-2222-222222222222";
    try writeFixture(temporary.dir, committed ++ "\\bin\\graphcode-windows.exe", "old committed shell");
    try writeFixture(temporary.dir, committed ++ marker_suffix, "committed\n");
    try writeFixture(temporary.dir, recovery ++ "\\sentinel.txt", "required recovery");

    const result = try cleanupParent(allocator, parent);
    try std.testing.expectEqual(@as(usize, 1), result.deleted);
    try std.testing.expectError(error.FileNotFound, temporary.dir.access(committed, .{}));
    try std.testing.expectError(error.FileNotFound, temporary.dir.access(committed ++ marker_suffix, .{}));
    try temporary.dir.access(recovery, .{});
    const sentinel = try temporary.dir.readFileAlloc(allocator, recovery ++ "\\sentinel.txt", 64);
    defer allocator.free(sentinel);
    try std.testing.expectEqualStrings("required recovery", sentinel);
}

test "successful update rollback cleanup retains locked backups for retry" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const parent = try temporary.dir.realpathAlloc(allocator, ".");
    defer allocator.free(parent);
    const committed = rollback_prefix ++ "33333333-3333-3333-3333-333333333333";
    const relative_executable = committed ++ "\\bin\\graphcode-windows.exe";
    try writeFixture(temporary.dir, relative_executable, "locked committed shell");
    try writeFixture(temporary.dir, committed ++ marker_suffix, "committed\n");
    const executable = try temporary.dir.realpathAlloc(allocator, relative_executable);
    defer allocator.free(executable);
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(allocator, executable);
    defer allocator.free(wide);
    const lock = c.CreateFileW(
        wide.ptr,
        c.GENERIC_READ,
        c.FILE_SHARE_READ,
        null,
        c.OPEN_EXISTING,
        c.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    try std.testing.expect(lock != c.INVALID_HANDLE_VALUE);

    const blocked = try cleanupParent(allocator, parent);
    try std.testing.expectEqual(@as(usize, 1), blocked.locked);
    try temporary.dir.access(committed, .{});
    try temporary.dir.access(committed ++ marker_suffix, .{});

    _ = c.CloseHandle(lock);
    const retried = try cleanupParent(allocator, parent);
    try std.testing.expectEqual(@as(usize, 1), retried.deleted);
    try std.testing.expectError(error.FileNotFound, temporary.dir.access(committed, .{}));
    try std.testing.expectError(error.FileNotFound, temporary.dir.access(committed ++ marker_suffix, .{}));
}

test "successful update rollback cleanup leases markers and rejects malformed names" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const parent = try temporary.dir.realpathAlloc(allocator, ".");
    defer allocator.free(parent);
    const committed = rollback_prefix ++ "44444444-4444-4444-4444-444444444444";
    try writeFixture(temporary.dir, committed ++ "\\payload.txt", "stale");
    try writeFixture(temporary.dir, committed ++ marker_suffix, "committed\n");
    try writeFixture(temporary.dir, rollback_prefix ++ "not-a-guid" ++ marker_suffix, "ignore\n");
    try writeFixture(
        temporary.dir,
        rollback_prefix ++ "55555555-5555-5555-5555-555555555555" ++ marker_suffix,
        "orphan\n",
    );
    const marker = try temporary.dir.realpathAlloc(allocator, committed ++ marker_suffix);
    defer allocator.free(marker);
    const lease = try openExclusive(allocator, marker, false);

    const blocked = try cleanupParent(allocator, parent);
    try std.testing.expectEqual(@as(usize, 1), blocked.locked);
    try std.testing.expectEqual(@as(usize, 1), blocked.orphan_markers);
    try temporary.dir.access(committed, .{});
    try temporary.dir.access(rollback_prefix ++ "not-a-guid" ++ marker_suffix, .{});

    _ = c.CloseHandle(lease);
    const retried = try cleanupParent(allocator, parent);
    try std.testing.expectEqual(@as(usize, 1), retried.deleted);
}

test "successful update rollback cleanup holds its marker lease through deletion" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const parent = try temporary.dir.realpathAlloc(allocator, ".");
    defer allocator.free(parent);
    const committed = rollback_prefix ++ "66666666-6666-6666-6666-666666666666";
    const marker_name = committed ++ marker_suffix;
    try writeFixture(temporary.dir, committed ++ "\\payload.txt", "stale");
    try writeFixture(temporary.dir, marker_name, "committed\n");
    const entered = c.CreateEventW(null, 1, 0, null);
    try std.testing.expect(entered != null);
    defer _ = c.CloseHandle(entered);
    const release = c.CreateEventW(null, 1, 0, null);
    try std.testing.expect(release != null);
    defer _ = c.CloseHandle(release);

    const DeleteContext = struct {
        entered: c.HANDLE,
        release: c.HANDLE,

        fn run(raw: ?*anyopaque, path: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (c.SetEvent(self.entered) == 0) return error.TestEventFailed;
            if (c.WaitForSingleObject(self.release, 5_000) != c.WAIT_OBJECT_0) return error.TestEventFailed;
            try std.fs.deleteTreeAbsolute(path);
        }
    };
    const CleanupContext = struct {
        parent: []const u8,
        outcome: Outcome = .failed,
        delete_context: *DeleteContext,

        fn run(self: *@This()) void {
            self.outcome = cleanupMarkerWith(
                std.heap.c_allocator,
                self.parent,
                marker_name,
                .{ .context = self.delete_context, .deleteTree = DeleteContext.run },
            ) catch .failed;
        }
    };
    var delete_context = DeleteContext{ .entered = entered, .release = release };
    var cleanup_context = CleanupContext{ .parent = parent, .delete_context = &delete_context };
    const thread = try std.Thread.spawn(.{}, CleanupContext.run, .{&cleanup_context});
    var joined = false;
    errdefer {
        if (!joined) {
            _ = c.SetEvent(release);
            thread.join();
        }
    }
    try std.testing.expectEqual(c.WAIT_OBJECT_0, c.WaitForSingleObject(entered, 5_000));

    const competing = try cleanupParent(allocator, parent);
    try std.testing.expectEqual(@as(usize, 1), competing.locked);
    try temporary.dir.access(committed, .{});
    if (c.SetEvent(release) == 0) return error.TestEventFailed;
    thread.join();
    joined = true;
    try std.testing.expectEqual(Outcome.deleted, cleanup_context.outcome);
    try std.testing.expectError(error.FileNotFound, temporary.dir.access(committed, .{}));
    try std.testing.expectError(error.FileNotFound, temporary.dir.access(marker_name, .{}));
}
