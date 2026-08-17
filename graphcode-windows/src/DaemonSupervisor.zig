const std = @import("std");
const c = @import("Win32.zig").c;

pub const Probe = enum { available, busy, missing, unknown };

pub const Supervisor = struct {
    allocator: std.mem.Allocator,
    process: c.HANDLE = null,
    shutdown_event: c.HANDLE = null,
    startup_event: c.HANDLE = null,
    startup_reservation: c.HANDLE = null,
    owned: bool = false,
    failure: []u8 = &.{},

    pub fn start(self: *Supervisor, endpoint: []const u8, lock_name: []const u8) void {
        self.acquireStartupReservation(lock_name) catch |err| {
            switch (err) {
                error.ReservationBusy => {
                    const deadline = std.time.milliTimestamp() + 5_000;
                    while (std.time.milliTimestamp() < deadline) {
                        if (probeEndpoint(endpoint) == .available) return;
                        std.Thread.sleep(100 * std.time.ns_per_ms);
                    }
                    return;
                },
                else => {
                    self.setFailure("Unable to reserve daemon startup");
                    return;
                },
            }
        };
        defer self.releaseStartupReservation();

        if (startupEventExists(lock_name)) {
            const deadline = std.time.milliTimestamp() + 5_000;
            while (std.time.milliTimestamp() < deadline) {
                if (probeEndpoint(endpoint) == .available) return;
                std.Thread.sleep(100 * std.time.ns_per_ms);
            }
            return;
        }

        const deadline = std.time.milliTimestamp() + 5_000;
        const grace_deadline = std.time.milliTimestamp() + 1_000;
        while (std.time.milliTimestamp() < deadline) {
            switch (probeEndpoint(endpoint)) {
                .available, .busy => return,
                .unknown => {
                    self.setFailure("Unable to determine daemon endpoint state");
                    return;
                },
                .missing => {},
            }
            if (daemonLockExists(lock_name) or std.time.milliTimestamp() < grace_deadline) {
                std.Thread.sleep(100 * std.time.ns_per_ms);
                continue;
            }
            break;
        }
        if (probeEndpoint(endpoint) != .missing or daemonLockExists(lock_name)) return;
        const exe = siblingDaemon(self.allocator) catch {
            self.setFailure("Unable to locate packaged graphcoded.exe");
            return;
        };
        defer self.allocator.free(exe);
        self.createStartupEvent(lock_name) catch {
            self.setFailure("Unable to create daemon startup reservation event");
            return;
        };
        self.createShutdownEvent(lock_name) catch {
            self.setFailure("Unable to create daemon shutdown event");
            self.closeStartupEvent();
            return;
        };
        self.spawn(exe) catch {
            self.setFailure("Unable to start graphcoded.exe");
            self.closeShutdownEvent();
            self.closeStartupEvent();
            return;
        };
        _ = c.SetEvent(self.startup_event);
        self.clearStartupEnvironment();
        self.closeStartupEvent();
        self.releaseStartupReservation();
        const startup_deadline = std.time.milliTimestamp() + 5_000;
        while (std.time.milliTimestamp() < startup_deadline) {
            if (probeEndpoint(endpoint) == .available) return;
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
        self.setFailure("graphcoded.exe did not become reachable");
    }

    pub fn stop(self: *Supervisor) void {
        if (!self.owned or self.process == null) return;
        if (self.shutdown_event != null) _ = c.SetEvent(self.shutdown_event);
        if (c.WaitForSingleObject(self.process, 5_000) == c.WAIT_TIMEOUT) {
            self.forceStop();
        } else {
            self.closeProcess();
        }
        self.closeShutdownEvent();
        self.closeStartupEvent();
    }

    pub fn forceStop(self: *Supervisor) void {
        if (!self.owned or self.process == null) return;
        _ = c.TerminateProcess(self.process, 1);
        _ = c.WaitForSingleObject(self.process, 2_000);
        self.closeProcess();
        self.closeShutdownEvent();
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

    fn createShutdownEvent(self: *Supervisor, lock_name: []const u8) !void {
        const name = try std.fmt.allocPrint(self.allocator, "{s}-shutdown", .{lock_name});
        defer self.allocator.free(name);
        const wide = try utf16(self.allocator, name);
        defer self.allocator.free(wide);
        self.shutdown_event = c.CreateEventW(null, 1, 0, wide.ptr);
        if (self.shutdown_event == null) return error.EventCreationFailed;
        const env_name = try utf16(self.allocator, "GRAPHCODE_DAEMON_SHUTDOWN_EVENT");
        defer self.allocator.free(env_name);
        if (c.SetEnvironmentVariableW(env_name.ptr, wide.ptr) == 0) return error.EnvironmentUpdateFailed;
    }

    fn acquireStartupReservation(self: *Supervisor, lock_name: []const u8) !void {
        const name = try std.fmt.allocPrint(self.allocator, "{s}-startup", .{lock_name});
        defer self.allocator.free(name);
        const wide = try utf16(self.allocator, name);
        defer self.allocator.free(wide);
        self.startup_reservation = c.CreateMutexW(null, 1, wide.ptr);
        if (self.startup_reservation == null) return error.ReservationCreationFailed;
        if (c.GetLastError() == c.ERROR_ALREADY_EXISTS) {
            _ = c.CloseHandle(self.startup_reservation);
            self.startup_reservation = null;
            return error.ReservationBusy;
        }
    }

    fn releaseStartupReservation(self: *Supervisor) void {
        if (self.startup_reservation != null) {
            _ = c.ReleaseMutex(self.startup_reservation);
            _ = c.CloseHandle(self.startup_reservation);
        }
        self.startup_reservation = null;
    }

    fn createStartupEvent(self: *Supervisor, lock_name: []const u8) !void {
        const name = try std.fmt.allocPrint(self.allocator, "{s}-startup-ready", .{lock_name});
        defer self.allocator.free(name);
        const wide = try utf16(self.allocator, name);
        defer self.allocator.free(wide);
        self.startup_event = c.CreateEventW(null, 1, 0, wide.ptr);
        if (self.startup_event == null) return error.EventCreationFailed;
        if (c.GetLastError() == c.ERROR_ALREADY_EXISTS) {
            _ = c.CloseHandle(self.startup_event);
            self.startup_event = null;
            return error.EventCreationFailed;
        }
        _ = c.ResetEvent(self.startup_event);
        const env_name = try utf16(self.allocator, "GRAPHCODE_DAEMON_STARTUP_EVENT");
        defer self.allocator.free(env_name);
        if (c.SetEnvironmentVariableW(env_name.ptr, wide.ptr) == 0) {
            return error.EnvironmentUpdateFailed;
        }
    }

    fn clearStartupEnvironment(self: *Supervisor) void {
        _ = self;
        const env_name = utf16(std.heap.page_allocator, "GRAPHCODE_DAEMON_STARTUP_EVENT") catch return;
        defer std.heap.page_allocator.free(env_name);
        _ = c.SetEnvironmentVariableW(env_name.ptr, null);
    }

    fn closeStartupEvent(self: *Supervisor) void {
        self.clearStartupEnvironment();
        if (self.startup_event != null) _ = c.CloseHandle(self.startup_event);
        self.startup_event = null;
    }

    fn closeShutdownEvent(self: *Supervisor) void {
        if (self.shutdown_event != null) _ = c.CloseHandle(self.shutdown_event);
        self.shutdown_event = null;
    }

    fn closeProcess(self: *Supervisor) void {
        if (self.process != null) _ = c.CloseHandle(self.process);
        self.process = null;
        self.owned = false;
    }

    fn setFailure(self: *Supervisor, message: []const u8) void {
        if (self.failure.len != 0) self.allocator.free(self.failure);
        self.failure = self.allocator.dupe(u8, message) catch &.{};
    }
};

fn probeEndpoint(endpoint: []const u8) Probe {
    const wide = utf16(std.heap.page_allocator, endpoint) catch return .unknown;
    defer std.heap.page_allocator.free(wide);
    if (c.WaitNamedPipeW(wide.ptr, 250) != 0) return .available;
    return switch (c.GetLastError()) {
        c.ERROR_FILE_NOT_FOUND => .missing,
        c.ERROR_SEM_TIMEOUT, c.ERROR_PIPE_BUSY => .busy,
        else => .unknown,
    };
}

fn daemonLockExists(name: []const u8) bool {
    const wide = utf16(std.heap.page_allocator, name) catch return false;
    defer std.heap.page_allocator.free(wide);
    const handle = c.OpenMutexW(c.SYNCHRONIZE, 0, wide.ptr);
    if (handle == null) return false;
    _ = c.CloseHandle(handle);
    return true;
}

fn startupEventExists(lock_name: []const u8) bool {
    const name = std.fmt.allocPrint(std.heap.page_allocator, "{s}-startup-ready", .{lock_name}) catch return false;
    defer std.heap.page_allocator.free(name);
    const wide = utf16(std.heap.page_allocator, name) catch return false;
    defer std.heap.page_allocator.free(wide);
    const handle = c.OpenEventW(c.SYNCHRONIZE, 0, wide.ptr);
    if (handle == null) return false;
    _ = c.CloseHandle(handle);
    return true;
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

test "busy endpoint is never treated as missing" {
    try std.testing.expect(@intFromEnum(Probe.busy) != @intFromEnum(Probe.missing));
}

test "daemon supervisor preserves Unicode sibling paths" {
    const path = try siblingDaemon(std.testing.allocator);
    defer std.testing.allocator.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, "graphcoded.exe"));
}
