const std = @import("std");

pub const prefix = "graphcode-";

pub fn nameBuffer(session: []const u8, buffer: []u8) ![]const u8 {
    if (std.mem.startsWith(u8, session, prefix)) return session;
    return std.fmt.bufPrint(buffer, prefix ++ "{s}", .{session});
}

pub fn allocName(allocator: std.mem.Allocator, session: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, session, prefix)) return allocator.dupe(u8, session);
    return std.fmt.allocPrint(allocator, prefix ++ "{s}", .{session});
}

/// The uuid this shell mints for a tab or split's session (`WorkspaceLayout.newSurfaceID`):
/// lowercase 8-4-4-4-12 hex. The daemon names its agent sessions after the node's uuid in
/// uppercase, so the two namespaces never overlap and a case-sensitive test tells them apart.
pub fn isShellUuid(text: []const u8) bool {
    if (text.len != 36) return false;
    for (text, 0..) |byte, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (byte != '-') return false;
        } else if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    }
    return true;
}

/// The session name of a pane id when the pane can only be one of this shell's own plain
/// shells: `graphcode-` plus a lowercase uuid, exactly. Null for anything else (an agent's
/// uppercase uuid, a foreign or unprefixed name), which this shell must never end. A gate
/// harness that sets `GRAPHCODE_SHELL_SESSION_PREFIX` makes the shell mint `<prefix>-<uuid>`
/// ids (see `WorkspaceLayout.newSurfaceID`), which are accepted under that exact prefix only.
pub fn shellSessionName(allocator: std.mem.Allocator, pane_id: []const u8) !?[]u8 {
    const harness = std.process.getEnvVarOwned(allocator, "GRAPHCODE_SHELL_SESSION_PREFIX") catch "";
    defer if (harness.len != 0) allocator.free(harness);
    return shellSessionNameWith(allocator, pane_id, harness);
}

fn shellSessionNameWith(allocator: std.mem.Allocator, pane_id: []const u8, harness_prefix: []const u8) !?[]u8 {
    const unprefixed = if (std.mem.startsWith(u8, pane_id, prefix)) pane_id[prefix.len..] else pane_id;
    var uuid = unprefixed;
    if (harness_prefix.len != 0 and std.mem.startsWith(u8, unprefixed, harness_prefix) and
        unprefixed.len > harness_prefix.len and unprefixed[harness_prefix.len] == '-')
    {
        uuid = unprefixed[harness_prefix.len + 1 ..];
    }
    if (!isShellUuid(uuid)) return null;
    return try std.fmt.allocPrint(allocator, prefix ++ "{s}", .{unprefixed});
}

pub const ChildStdio = enum {
    /// `zmx attach`: the shell writes terminal input and reads terminal output.
    attach,
    /// One-shot control commands such as `resize` and `kill`.
    control,
    /// One-shot listings whose output is inspected before attaching.
    capture,
};

/// zmx.exe is a console-subsystem program. Spawned from the GUI shell without
/// CREATE_NO_WINDOW, Windows allocates it a new console, which the default
/// terminal host shows as a visible window that steals foreground.
pub fn child(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: ?[]const u8,
    stdio: ChildStdio,
) std.process.Child {
    var result = std.process.Child.init(argv, allocator);
    result.cwd = cwd;
    result.stdin_behavior = if (stdio == .attach) .Pipe else .Ignore;
    result.stdout_behavior = if (stdio == .attach or stdio == .capture) .Pipe else .Ignore;
    result.stderr_behavior = .Ignore;
    result.create_no_window = true;
    return result;
}

test "zmx children keep their stdio contract and never open a console window" {
    const attach_argv = [_][]const u8{ "zmx.exe", "attach", "graphcode-alpha", "--size", "80x24" };
    const attach = child(std.testing.allocator, &attach_argv, "C:\\GraphCode\\bin", .attach);
    try std.testing.expectEqual(std.process.Child.StdIo.Pipe, attach.stdin_behavior);
    try std.testing.expectEqual(std.process.Child.StdIo.Pipe, attach.stdout_behavior);
    try std.testing.expectEqual(std.process.Child.StdIo.Ignore, attach.stderr_behavior);
    try std.testing.expectEqualStrings("C:\\GraphCode\\bin", attach.cwd.?);
    try std.testing.expectEqual(attach_argv.len, attach.argv.len);
    try std.testing.expectEqual(true, attach.create_no_window);

    const kill_argv = [_][]const u8{ "zmx.exe", "kill", "graphcode-alpha" };
    const control = child(std.testing.allocator, &kill_argv, null, .control);
    try std.testing.expectEqual(std.process.Child.StdIo.Ignore, control.stdin_behavior);
    try std.testing.expectEqual(std.process.Child.StdIo.Ignore, control.stdout_behavior);
    try std.testing.expectEqual(std.process.Child.StdIo.Ignore, control.stderr_behavior);
    try std.testing.expect(control.cwd == null);
    try std.testing.expectEqual(true, control.create_no_window);
}

test "canonical zmx session names add the ownership prefix exactly once" {
    var storage: [64]u8 = undefined;
    try std.testing.expectEqualStrings("graphcode-alpha", try nameBuffer("alpha", &storage));
    try std.testing.expectEqualStrings(
        "graphcode-alpha",
        try nameBuffer("graphcode-alpha", &storage),
    );
}

test "only a lowercase uuid under the graphcode prefix names a shell session this shell may end" {
    const allocator = std.testing.allocator;
    const uuid = "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d";
    const bare = (try shellSessionName(allocator, uuid)).?;
    defer allocator.free(bare);
    try std.testing.expectEqualStrings("graphcode-" ++ uuid, bare);
    const prefixed = (try shellSessionName(allocator, "graphcode-" ++ uuid)).?;
    defer allocator.free(prefixed);
    try std.testing.expectEqualStrings("graphcode-" ++ uuid, prefixed);

    for ([_][]const u8{
        "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D",
        "graphcode-0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D",
        "0a1b2c3d-4e5f-4a6b-8c7d-9E0F1A2B3C4D",
        "other-" ++ uuid,
        "Graphcode-" ++ uuid,
        "graphcode-graphcode-" ++ uuid,
        "alpha",
        "graphcode-alpha",
        "graphcode-",
        "",
        uuid ++ "0",
        "0a1b2c3d4e5f4a6b8c7d9e0f1a2b3c4d",
        "0g1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d",
    }) |not_ours| {
        try std.testing.expect((try shellSessionName(allocator, not_ours)) == null);
    }
}

test "a gate harness's session prefix is accepted only as exactly that prefix before a lowercase uuid" {
    const allocator = std.testing.allocator;
    const uuid = "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d";
    const ok = (try shellSessionNameWith(allocator, "gs-abc-" ++ uuid, "gs-abc")).?;
    defer allocator.free(ok);
    try std.testing.expectEqualStrings("graphcode-gs-abc-" ++ uuid, ok);
    const prefixed = (try shellSessionNameWith(allocator, "graphcode-gs-abc-" ++ uuid, "gs-abc")).?;
    defer allocator.free(prefixed);
    try std.testing.expectEqualStrings("graphcode-gs-abc-" ++ uuid, prefixed);
    for ([_][]const u8{
        "other-" ++ uuid,
        "gs-abc-gs-abc-" ++ uuid,
        "gs-abc-0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D",
        "gs-abc" ++ uuid,
        "gs-abc-alpha",
        "gs-abc-",
    }) |not_ours| {
        try std.testing.expect((try shellSessionNameWith(allocator, not_ours, "gs-abc")) == null);
    }
    try std.testing.expect((try shellSessionNameWith(allocator, "gs-abc-" ++ uuid, "")) == null);
}

test "zmx listing capture has readable output without stdin or a console" {
    const listing = child(std.testing.allocator, &.{ "zmx.exe", "ls" }, null, .capture);
    try std.testing.expectEqual(std.process.Child.StdIo.Ignore, listing.stdin_behavior);
    try std.testing.expectEqual(std.process.Child.StdIo.Pipe, listing.stdout_behavior);
    try std.testing.expect(listing.create_no_window);
}
