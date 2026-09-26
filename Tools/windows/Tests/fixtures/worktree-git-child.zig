const std = @import("std");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len >= 4 and std.mem.eql(u8, args[1], "-C")) return fakeGit(args);
    if (args.len != 3) return error.InvalidArguments;
    const pid_path = try std.fs.path.join(allocator, &.{ args[2], "child.pid" });
    defer allocator.free(pid_path);
    const pid = try std.fmt.allocPrint(allocator, "{d}", .{std.os.windows.GetCurrentProcessId()});
    defer allocator.free(pid);
    try std.fs.cwd().writeFile(.{ .sub_path = pid_path, .data = pid });
    const mode = args[1];
    if (std.mem.eql(u8, mode, "environment")) {
        for ([_][]const u8{ "GIT_ASKPASS", "GIT_SSH", "GIT_SSH_COMMAND", "GIT_CONFIG_SYSTEM", "GIT_EXEC_PATH", "SSH_AUTH_SOCK", "GRAPHCODE_SYNTHETIC_TOKEN" }) |key| {
            const value = try std.process.getEnvVarOwned(allocator, key);
            defer allocator.free(value);
            if (!std.mem.eql(u8, value, "synthetic-preserved")) return error.EnvironmentNotPreserved;
        }
        for ([_][2][]const u8{ .{ "GIT_TERMINAL_PROMPT", "0" }, .{ "GIT_CONFIG_NOSYSTEM", "1" }, .{ "GIT_OPTIONAL_LOCKS", "0" }, .{ "GIT_SSH_VARIANT", "ssh" } }) |pair| {
            const value = try std.process.getEnvVarOwned(allocator, pair[0]);
            defer allocator.free(value);
            if (!std.mem.eql(u8, value, pair[1])) return error.EnvironmentNotPreserved;
        }
        const path = try std.process.getEnvVarOwned(allocator, "PATH");
        defer allocator.free(path);
        if (path.len == 0) return error.PathNotPreserved;
        try std.fs.File.stdout().writeAll("preserved\n");
        return;
    }
    if (std.mem.eql(u8, mode, "empty")) return;
    const over_stdout = std.mem.eql(u8, mode, "stdout-cap");
    const over_stderr = std.mem.eql(u8, mode, "stderr-cap");
    const boundary = std.mem.eql(u8, mode, "boundary");
    const count: usize = if (over_stdout or over_stderr) 1025 else if (boundary) 1024 else 256;
    const out = [_]u8{'o'} ** 1024;
    const err = [_]u8{'e'} ** 1024;
    for (0..count) |_| {
        if (!over_stderr and !std.mem.eql(u8, mode, "stderr")) try std.fs.File.stdout().writeAll(&out);
        if (!over_stdout) try std.fs.File.stderr().writeAll(&err);
    }
    if (over_stdout or over_stderr) std.Thread.sleep(60 * std.time.ns_per_s);
    if (std.mem.eql(u8, mode, "nonzero")) std.process.exit(7);
}

// Only installed as git.exe for the explicitly synthetic result-ownership cases.
fn fakeGit(args: []const []const u8) !void {
    const allocator = std.heap.page_allocator;
    const root = try std.process.getEnvVarOwned(allocator, "GRAPHCODE_WORKTREE_TEST_ROOT");
    defer allocator.free(root);
    const scenario = try std.process.getEnvVarOwned(allocator, "GRAPHCODE_WORKTREE_TEST_CASE");
    defer allocator.free(scenario);
    const output = std.fs.File.stdout();
    const command = args[3];
    if (std.mem.eql(u8, command, "worktree")) {
        if (args.len < 5) return error.InvalidArguments;
        if (std.mem.eql(u8, args[4], "remove")) {
            try output.writeAll("synthetic removal output\n");
        } else if (std.mem.eql(u8, args[4], "list")) {
            const porcelain = try std.fmt.allocPrint(allocator, "worktree {s}/target\nbranch refs/heads/main\n\nworktree {s}/selected\nbranch refs/heads/feature\n\n", .{ root, root });
            defer allocator.free(porcelain);
            std.mem.replaceScalar(u8, porcelain, '\\', '/');
            try output.writeAll(porcelain);
        } else return error.UnexpectedGitCommand;
    } else if (std.mem.eql(u8, command, "symbolic-ref")) {
        try output.writeAll("origin/main\n");
    } else if (std.mem.eql(u8, command, "status")) {
        if (std.mem.eql(u8, scenario, "removal-output-forced")) try output.writeAll("?? untracked.txt\n");
    } else if (std.mem.eql(u8, command, "rev-parse")) {
        try output.writeAll("main\n");
    } else if (std.mem.eql(u8, command, "rev-list")) {
        try output.writeAll("0\n");
    } else if (!std.mem.eql(u8, command, "merge-base")) return error.UnexpectedGitCommand;
}
