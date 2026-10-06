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

pub const ChildStdio = enum {
    /// `zmx attach`: the shell writes terminal input and reads terminal output.
    attach,
    /// One-shot control commands such as `resize` and `kill`.
    control,
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
    result.stdout_behavior = if (stdio == .attach) .Pipe else .Ignore;
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
