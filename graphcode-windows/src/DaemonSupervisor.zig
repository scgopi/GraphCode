const std = @import("std");
const c = @import("Win32.zig").c;

pub const Supervisor = struct {
    allocator: std.mem.Allocator,
    process: c.HANDLE = null,
    owned: bool = false,
    failure: []u8 = &.{},

    pub fn start(self: *Supervisor, endpoint: []const u8) void {
        if (endpointAvailable(endpoint)) return;
        const exe = siblingDaemon(self.allocator) catch {
            self.setFailure("Unable to locate packaged graphcoded.exe");
            return;
        };
        defer self.allocator.free(exe);
        self.spawn(exe) catch {
            self.setFailure("Unable to start graphcoded.exe");
        };
    }

    pub fn stop(self: *Supervisor) void {
        if (!self.owned or self.process == null) return;
        if (c.WaitForSingleObject(self.process, 2000) == c.WAIT_TIMEOUT) {
            _ = c.TerminateProcess(self.process, 0);
            _ = c.WaitForSingleObject(self.process, 2000);
        }
        _ = c.CloseHandle(self.process);
        self.process = null;
        self.owned = false;
    }

    pub fn forceStop(self: *Supervisor) void {
        if (!self.owned or self.process == null) return;
        self.stop();
    }

    pub fn status(self: *const Supervisor) []const u8 {
        return self.failure;
    }

    fn spawn(self: *Supervisor, exe: []const u8) !void {
        const wide_exe = try utf16(self.allocator, exe);
        defer self.allocator.free(wide_exe);
        const command = try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{exe});
        defer self.allocator.free(command);
        const wide_command = try utf16(self.allocator, command);
        defer self.allocator.free(wide_command);
        var startup: c.STARTUPINFOW = std.mem.zeroes(c.STARTUPINFOW);
        startup.cb = @sizeOf(c.STARTUPINFOW);
        var info: c.PROCESS_INFORMATION = undefined;
        if (c.CreateProcessW(
            wide_exe.ptr,
            wide_command.ptr,
            null,
            null,
            0,
            c.CREATE_NO_WINDOW,
            null,
            null,
            &startup,
            &info,
        ) == 0) return error.CreateProcessFailed;
        _ = c.CloseHandle(info.hThread);
        self.process = info.hProcess;
        self.owned = true;
    }

    fn setFailure(self: *Supervisor, message: []const u8) void {
        self.failure = self.allocator.dupe(u8, message) catch &.{};
    }
};

fn endpointAvailable(endpoint: []const u8) bool {
    const wide = utf16(std.heap.page_allocator, endpoint) catch return false;
    defer std.heap.page_allocator.free(wide);
    return c.WaitNamedPipeW(wide.ptr, 0) != 0;
}

fn siblingDaemon(allocator: std.mem.Allocator) ![]u8 {
    const self_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(self_path);
    return std.fs.path.join(allocator, &.{ std.fs.path.dirname(self_path) orelse ".", "graphcoded.exe" });
}

fn utf16(allocator: std.mem.Allocator, value: []const u8) ![:0]u16 {
    const raw = try std.unicode.utf8ToUtf16LeAlloc(allocator, value);
    defer allocator.free(raw);
    const result = try allocator.alloc(u16, raw.len + 1);
    @memcpy(result[0..raw.len], raw);
    result[raw.len] = 0;
    return result[0..raw.len :0];
}

test "daemon supervisor preserves Unicode sibling paths" {
    const path = try siblingDaemon(std.testing.allocator);
    defer std.testing.allocator.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, "graphcoded.exe"));
}
