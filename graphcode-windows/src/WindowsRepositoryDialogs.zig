const std = @import("std");
const builtin = @import("builtin");
const Win32 = @import("Win32.zig");
const c = Win32.c;
const Tokens = @import("DesignTokens.zig");
const AppFont = @import("AppFont.zig");
const Dpi = @import("Dpi.zig");
const SheetFramework = @import("SheetFramework.zig");

extern fn graphcode_pick_folder(owner: c.HWND, buffer: [*]u16, capacity: c.DWORD) callconv(.c) c_int;

fn darkDialogEraseBackground(hwnd: c.HWND, wparam: c.WPARAM) c.LRESULT {
    const hdc = deviceContextFrom(wparam);
    var client: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &client);
    const brush = if (repository_dialog_active and repository_dialog_state.host != null)
        repository_dialog_state.host.?.brushes.panel
    else if (operation_dialog_active and operation_dialog_state.host != null)
        operation_dialog_state.host.?.brushes.panel
    else
        darkFieldBrush();
    _ = c.FillRect(hdc, &client, brush);
    return 1;
}

fn darkDialogCtlColorStatic(hwnd: c.HWND, wparam: c.WPARAM, error_label: c.HWND) c.LRESULT {
    const hdc = deviceContextFrom(wparam);
    _ = c.SetTextColor(hdc, if (hwnd == error_label) Tokens.dialog_error_text else Tokens.dialog_body_text);
    _ = c.SetBkColor(hdc, Tokens.dialog_panel);
    _ = c.SetBkMode(hdc, c.OPAQUE);
    const brush = if (repository_dialog_active and repository_dialog_state.host != null)
        repository_dialog_state.host.?.brushes.panel
    else if (operation_dialog_active and operation_dialog_state.host != null)
        operation_dialog_state.host.?.brushes.panel
    else
        darkFieldBrush();
    return @intCast(@intFromPtr(brush));
}

fn darkDialogCtlColorEdit(wparam: c.WPARAM) c.LRESULT {
    const hdc = deviceContextFrom(wparam);
    _ = c.SetTextColor(hdc, Tokens.dialog_title_text);
    _ = c.SetBkColor(hdc, Tokens.dialog_field_background);
    _ = c.SetBkMode(hdc, c.OPAQUE);
    return @intCast(@intFromPtr(darkFieldBrush()));
}

var dark_field_brush: c.HBRUSH = null;

fn darkFieldBrush() c.HBRUSH {
    if (dark_field_brush == null) dark_field_brush = c.CreateSolidBrush(Tokens.dialog_field_background);
    return dark_field_brush;
}

fn deviceContextFrom(wparam: c.WPARAM) c.HDC {
    @setRuntimeSafety(false);
    return @ptrFromInt(wparam);
}

fn controlHandleFrom(lparam: c.LPARAM) c.HWND {
    @setRuntimeSafety(false);
    return @ptrFromInt(@as(usize, @bitCast(lparam)));
}

pub const CloneFields = struct {
    url: []const u8 = "",
    destination: []const u8 = "",
    branch: []const u8 = "",
    depth: []const u8 = "",

    fn values(self: CloneFields) [4][]const u8 {
        return .{ self.url, self.destination, self.branch, self.depth };
    }
};

pub const RemoteFields = struct {
    host: []const u8 = "",
    user: []const u8 = "",
    port: []const u8 = "22",
    path: []const u8 = "",

    fn values(self: RemoteFields) [4][]const u8 {
        return .{ self.host, self.user, self.port, self.path };
    }
};

pub const CloneStatus = enum { ready, cloning, cancelled, finished, failed };
pub const OutputSnapshot = struct { progress_len: usize, stderr_len: usize };

pub const CloneProcess = struct {
    allocator: std.mem.Allocator,
    child: std.process.Child,
    args: []const []u8,
    destination: []u8,
    staging: []u8,
    recent_stderr: [4096]u8 = undefined,
    recent_stderr_len: usize = 0,
    progress: [256]u8 = undefined,
    progress_len: usize = 0,
    redaction_pending_stdout: [1024 * 1024]u8 = undefined,
    redaction_pending_stdout_len: usize = 0,
    redaction_pending_stderr: [1024 * 1024]u8 = undefined,
    redaction_pending_stderr_len: usize = 0,
    output_lock: std.Thread.Mutex = .{},
    finished: bool = false,
    cancelled: bool = false,

    pub fn start(allocator: std.mem.Allocator, fields: CloneFields) !CloneProcess {
        if (try inspectDestination(fields.destination)) return error.DestinationAlreadyExists;
        const staging = try makeStagingPath(allocator, fields.destination);
        errdefer allocator.free(staging);
        const staged_fields = CloneFields{ .url = fields.url, .destination = staging, .branch = fields.branch, .depth = fields.depth };
        const args = try cloneCommand(allocator, staged_fields);
        var child = std.process.Child.init(args, allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        try child.spawn();
        const destination = allocator.dupe(u8, fields.destination) catch |err| {
            _ = std.os.windows.kernel32.TerminateProcess(child.id, 1);
            _ = child.wait() catch {};
            for (args) |arg| allocator.free(arg);
            allocator.free(args);
            return err;
        };

        return .{ .allocator = allocator, .child = child, .args = args, .destination = destination, .staging = staging };
    }

    fn terminate(self: *CloneProcess) void {
        self.cancelled = true;
        if (comptime @import("builtin").os.tag == .windows) {
            _ = std.os.windows.kernel32.TerminateProcess(self.child.id, 1);
        }
    }

    pub fn finish(self: *CloneProcess) !CloneStatus {
        if (self.finished) return if (self.cancelled) .cancelled else .finished;
        const term = try self.child.wait();
        self.finished = true;
        const status: CloneStatus = if (self.cancelled) .cancelled else switch (term) {
            .Exited => |code| if (code == 0) .finished else .failed,
            else => .failed,
        };

        self.releaseArgs();
        if (status == .finished) {
            std.fs.cwd().rename(self.staging, self.destination) catch {
                std.fs.cwd().deleteTree(self.staging) catch {};
                return error.DestinationCommitFailed;
            };
        } else {
            std.fs.cwd().deleteTree(self.staging) catch {};
        }
        return status;
    }

    pub fn deinit(self: *CloneProcess) void {
        if (!self.finished) {
            self.terminate();
            _ = self.finish() catch {};
        }
        self.allocator.free(self.destination);
        self.allocator.free(self.staging);
        self.* = undefined;
    }

    fn releaseArgs(self: *CloneProcess) void {
        if (self.args.len == 0) return;
        for (self.args) |arg| self.allocator.free(arg);
        self.allocator.free(self.args);
        self.args = &.{};
    }

    pub fn snapshot(self: *CloneProcess, progress: []u8, stderr: []u8) OutputSnapshot {
        self.output_lock.lock();
        defer self.output_lock.unlock();
        const progress_len = @min(progress.len, self.progress_len);
        const stderr_len = @min(stderr.len, self.recent_stderr_len);
        @memcpy(progress[0..progress_len], self.progress[0..progress_len]);
        @memcpy(stderr[0..stderr_len], self.recent_stderr[0..stderr_len]);
        return .{ .progress_len = progress_len, .stderr_len = stderr_len };
    }

    fn recordOutput(self: *CloneProcess, bytes: []const u8, is_stderr: bool, flush: bool) void {
        self.output_lock.lock();
        defer self.output_lock.unlock();
        const pending = if (is_stderr) self.redaction_pending_stderr[0..self.redaction_pending_stderr_len] else self.redaction_pending_stdout[0..self.redaction_pending_stdout_len];
        const combined_len = pending.len + bytes.len;
        const combined = self.allocator.alloc(u8, combined_len) catch return;
        defer self.allocator.free(combined);
        @memcpy(combined[0..pending.len], pending);
        @memcpy(combined[pending.len..combined_len], bytes);
        var safe_end = if (flush) combined_len else combined_len - @min(combined_len, 128);
        if (!flush) {
            if (findUnterminatedSecret(combined)) |start_pos| safe_end = @min(safe_end, start_pos);
        }
        const safe = redactSecrets(self.allocator, combined[0..safe_end]) catch return;
        defer self.allocator.free(safe);
        const target = if (is_stderr) &self.recent_stderr else &self.progress;
        const len = if (is_stderr) &self.recent_stderr_len else &self.progress_len;
        const capacity = target.len;
        const copy_len = @min(capacity, safe.len);
        if (copy_len < capacity) {
            @memcpy(target[0..copy_len], safe[safe.len - copy_len ..]);
        } else {
            @memcpy(target[0..capacity], safe[safe.len - capacity ..]);
        }
        len.* = copy_len;
        if (is_stderr) {
            const retained = combined[safe_end..combined_len];
            @memcpy(self.redaction_pending_stderr[0..retained.len], retained);
            self.redaction_pending_stderr_len = retained.len;
        } else {
            const retained = combined[safe_end..combined_len];
            @memcpy(self.redaction_pending_stdout[0..retained.len], retained);
            self.redaction_pending_stdout_len = retained.len;
        }
    }
};

fn findUnterminatedSecret(input: []const u8) ?usize {
    var index: usize = 0;
    while (index < input.len) : (index += 1) {
        const is_url = std.mem.startsWith(u8, input[index..], "https://");
        const is_token = std.mem.startsWith(u8, input[index..], "token=") or
            std.mem.startsWith(u8, input[index..], "access_token=");
        if (!is_url and !is_token) continue;
        const rest = input[index..];
        const terminators = if (is_token) "& \t\r\n" else " \t\r\n";
        if (std.mem.indexOfAny(u8, rest, terminators) == null) return index;
    }
    return null;
}

fn redactSecrets(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var output = std.array_list.Managed(u8).init(allocator);
    var index: usize = 0;
    while (index < input.len) {
        if (std.mem.startsWith(u8, input[index..], "https://")) {
            const rest = input[index + 8 ..];
            if (std.mem.lastIndexOfScalar(u8, rest, '@')) |at| {
                const end = std.mem.indexOfAny(u8, rest[0..at], " \t\r\n") == null;
                if (end) {
                    try output.appendSlice("https://<redacted>@");
                    index += 8 + at + 1;
                    continue;
                }
            }
        }
        if (std.mem.startsWith(u8, input[index..], "token=") or
            std.mem.startsWith(u8, input[index..], "access_token="))
        {
            const equals = std.mem.indexOfScalar(u8, input[index..], '=').?;
            try output.appendSlice(input[index .. index + equals + 1]);
            index += equals + 1;
            try output.appendSlice("<redacted>");
            while (index < input.len and std.mem.indexOfScalar(u8, "& \t\r\n", input[index]) == null) index += 1;
            continue;
        }
        try output.append(input[index]);
        index += 1;
    }
    return output.toOwnedSlice();
}

fn inspectDestination(path: []const u8) !bool {
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return false,
        error.NotDir => return error.DestinationNotDirectory,
        else => return err,
    };
    dir.close();
    return true;
}

fn makeStagingPath(allocator: std.mem.Allocator, destination: []const u8) ![]u8 {
    const parent = std.fs.path.dirname(destination) orelse ".";
    const base = std.fs.path.basename(destination);
    var attempt: usize = 0;
    while (attempt < 32) : (attempt += 1) {
        const candidate = try std.fmt.allocPrint(allocator, "{s}{c}{s}.graphcode-clone-{d}-{d}", .{
            parent, std.fs.path.sep, base, std.time.nanoTimestamp(), attempt,
        });
        if (!try inspectDestination(candidate)) return candidate;
        allocator.free(candidate);
    }
    return error.StagingPathUnavailable;
}

pub const CloneOperation = struct {
    allocator: std.mem.Allocator,
    process: *CloneProcess,
    thread: std.Thread,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    status: CloneStatus = .cloning,
    cancel_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    stdout_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    stderr_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn start(allocator: std.mem.Allocator, fields: CloneFields) !*CloneOperation {
        const operation = try allocator.create(CloneOperation);
        errdefer allocator.destroy(operation);
        const process = try allocator.create(CloneProcess);
        errdefer allocator.destroy(process);
        process.* = try CloneProcess.start(allocator, fields);
        operation.* = .{ .allocator = allocator, .process = process, .thread = undefined };
        operation.thread = std.Thread.spawn(.{}, worker, .{operation}) catch |err| {
            process.deinit();
            allocator.destroy(process);
            return err;
        };

        return operation;
    }

    pub fn cancel(self: *CloneOperation) void {
        self.cancel_requested.store(true, .release);
    }

    pub fn poll(self: *CloneOperation) ?CloneStatus {
        if (!self.done.load(.acquire)) return null;
        return self.status;
    }

    pub fn snapshot(self: *CloneOperation, progress: []u8, stderr: []u8) OutputSnapshot {
        return self.process.snapshot(progress, stderr);
    }

    pub fn deinit(self: *CloneOperation) void {
        if (!self.done.load(.acquire)) self.cancel();
        self.thread.join();
        self.process.deinit();
        self.allocator.destroy(self.process);
        self.allocator.destroy(self);
    }

    fn worker(self: *CloneOperation) void {
        var stdout_thread = std.Thread.spawn(.{}, drainPipe, .{ self.process, &self.process.child.stdout.?, false, &self.stdout_done }) catch {
            self.process.terminate();
            _ = self.process.finish() catch {};
            self.status = .failed;
            self.done.store(true, .release);
            return;
        };

        var stderr_thread = std.Thread.spawn(.{}, drainPipe, .{ self.process, &self.process.child.stderr.?, true, &self.stderr_done }) catch {
            self.process.terminate();
            stdout_thread.join();
            _ = self.process.finish() catch {};
            self.status = .failed;
            self.done.store(true, .release);
            return;
        };
        while (!self.stdout_done.load(.acquire) or !self.stderr_done.load(.acquire)) {
            if (self.cancel_requested.load(.acquire)) self.process.terminate();
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
        stdout_thread.join();
        stderr_thread.join();
        self.status = self.process.finish() catch .failed;
        self.done.store(true, .release);
    }
};

pub const RemoteValidationStatus = enum { validating, succeeded, failed };

pub const RemoteValidationOperation = struct {
    allocator: std.mem.Allocator,
    fields: RemoteFields,
    thread: std.Thread,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    status: RemoteValidationStatus = .validating,

    pub fn start(allocator: std.mem.Allocator, fields: RemoteFields) !*RemoteValidationOperation {
        const operation = try allocator.create(RemoteValidationOperation);
        errdefer allocator.destroy(operation);
        operation.* = .{ .allocator = allocator, .fields = fields, .thread = undefined };
        operation.thread = try std.Thread.spawn(.{}, worker, .{operation});
        return operation;
    }

    pub fn poll(self: *RemoteValidationOperation) ?RemoteValidationStatus {
        if (!self.done.load(.acquire)) return null;
        return self.status;
    }

    pub fn deinit(self: *RemoteValidationOperation) void {
        self.thread.join();
        self.allocator.destroy(self);
    }

    fn worker(self: *RemoteValidationOperation) void {
        validateRemoteConnection(self.allocator, self.fields) catch {
            self.status = .failed;
            self.done.store(true, .release);
            return;
        };
        self.status = .succeeded;
        self.done.store(true, .release);
    }
};

pub fn validateClone(fields: CloneFields) !void {
    if (std.mem.trim(u8, fields.url, " \t\r\n").len == 0) return error.MissingRepositoryURL;
    if (!std.mem.startsWith(u8, fields.url, "https://")) return error.HTTPSRequired;
    if (std.mem.trim(u8, fields.destination, " \t\r\n").len == 0) return error.MissingDestination;
    if (std.mem.indexOfScalar(u8, fields.destination, 0) != null) return error.InvalidDestination;
    if (fields.depth.len != 0 and std.fmt.parseInt(u32, fields.depth, 10) catch 0 == 0)
        return error.InvalidDepth;
}

pub fn validateRemote(fields: RemoteFields) !void {
    if (fields.host.len == 0 or fields.user.len == 0 or fields.path.len == 0)
        return error.MissingRemoteField;
    if (!std.mem.startsWith(u8, fields.path, "/")) return error.AbsolutePathRequired;
    const port = std.fmt.parseInt(u16, fields.port, 10) catch return error.InvalidPort;
    if (port == 0) return error.InvalidPort;
    if (std.mem.startsWith(u8, fields.host, "-") or std.mem.startsWith(u8, fields.user, "-"))
        return error.InvalidSSHComponent;
    for ([_][]const u8{ fields.host, fields.user, fields.path }) |value| {
        if (std.mem.indexOfAny(u8, value, "\x00\r\n") != null) return error.InvalidSSHComponent;
    }
}

pub fn sshDestination(allocator: std.mem.Allocator, fields: RemoteFields) ![]u8 {
    try validateRemote(fields);
    return std.fmt.allocPrint(allocator, "{s}@{s}", .{ fields.user, fields.host });
}

pub fn remoteProjectURI(allocator: std.mem.Allocator, fields: RemoteFields) ![]u8 {
    try validateRemote(fields);
    var encoded = std.array_list.Managed(u8).init(allocator);
    defer encoded.deinit();
    try encoded.appendSlice("ssh://");
    for (fields.user) |byte| try appendURIByte(&encoded, byte, true);
    try encoded.append('@');
    if (std.mem.indexOfScalar(u8, fields.host, ':') != null) try encoded.append('[');
    for (fields.host) |byte| try appendURIByte(&encoded, byte, false);
    if (std.mem.indexOfScalar(u8, fields.host, ':') != null) try encoded.append(']');
    if (!std.mem.eql(u8, fields.port, "22")) {
        try encoded.append(':');
        try encoded.appendSlice(fields.port);
    }
    for (fields.path) |byte| try appendURIByte(&encoded, byte, byte != '/');
    return encoded.toOwnedSlice();
}

fn appendURIByte(list: *std.array_list.Managed(u8), byte: u8, encode: bool) !void {
    const safe = std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "-._~", byte) != null;
    if (safe or (!encode and (byte == '/' or byte == ':'))) return list.append(byte);
    const hex = "0123456789ABCDEF";
    try list.append('%');
    try list.append(hex[byte >> 4]);
    try list.append(hex[byte & 15]);
}

pub fn reconnectCommand(allocator: std.mem.Allocator, fields: RemoteFields) ![]u8 {
    const destination = try sshDestination(allocator, fields);
    defer allocator.free(destination);
    const quoted_destination = try shellQuote(allocator, destination);
    defer allocator.free(quoted_destination);
    const quoted_path = try shellQuote(allocator, fields.path);
    defer allocator.free(quoted_path);
    return std.fmt.allocPrint(
        allocator,
        "ssh -o BatchMode=yes -o ConnectTimeout=10 -p {s} {s} -- zmx attach -- {s}",
        .{ fields.port, quoted_destination, quoted_path },
    );
}

fn shellQuote(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
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

pub fn sshValidationArgs(allocator: std.mem.Allocator, fields: RemoteFields) ![][]u8 {
    try validateRemote(fields);
    var args = std.array_list.Managed([]u8).init(allocator);
    try args.append(try allocator.dupe(u8, "ssh"));
    try args.append(try allocator.dupe(u8, "-o"));
    try args.append(try allocator.dupe(u8, "BatchMode=yes"));
    try args.append(try allocator.dupe(u8, "-o"));
    try args.append(try allocator.dupe(u8, "ConnectTimeout=10"));
    try args.append(try allocator.dupe(u8, "-p"));
    try args.append(try allocator.dupe(u8, fields.port));
    const destination = try sshDestination(allocator, fields);
    defer allocator.free(destination);
    try args.append(try allocator.dupe(u8, destination));
    const quoted_path = try shellQuote(allocator, fields.path);
    defer allocator.free(quoted_path);
    const remote_command = try std.fmt.allocPrint(allocator, "git -C {s} rev-parse --show-toplevel", .{quoted_path});
    try args.append(remote_command);
    return args.toOwnedSlice();
}

pub fn validateRemoteConnection(allocator: std.mem.Allocator, fields: RemoteFields) !void {
    const args = try sshValidationArgs(allocator, fields);
    defer {
        for (args) |arg| allocator.free(arg);
        allocator.free(args);
    }
    var child = std.process.Child.init(args, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    var out_thread = try std.Thread.spawn(.{}, drainPipeDiscard, .{&child.stdout.?});
    var err_thread = try std.Thread.spawn(.{}, drainPipeDiscard, .{&child.stderr.?});
    out_thread.join();
    err_thread.join();
    switch (try child.wait()) {
        .Exited => |code| if (code != 0) return error.SSHValidationFailed,
        else => return error.SSHValidationFailed,
    }
}

pub fn saveRemoteConfig(allocator: std.mem.Allocator, fields: RemoteFields) !void {
    try validateRemote(fields);
    const base = std.process.getEnvVarOwned(allocator, "LOCALAPPDATA") catch
        try std.process.getEnvVarOwned(allocator, "USERPROFILE");
    defer allocator.free(base);
    const dir = try std.fs.path.join(allocator, &.{ base, "GraphCode" });
    defer allocator.free(dir);
    try std.fs.cwd().makePath(dir);
    const path = try std.fs.path.join(allocator, &.{ dir, "remote.ini" });
    defer allocator.free(path);
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    const data = try std.fmt.allocPrint(allocator, "host={s}\nuser={s}\nport={s}\npath={s}\n", .{
        fields.host, fields.user, fields.port, fields.path,
    });
    defer allocator.free(data);
    try file.writeAll(data);
}

pub fn cloneCommand(allocator: std.mem.Allocator, fields: CloneFields) ![]const []u8 {
    try validateClone(fields);
    var args = std.array_list.Managed([]u8).init(allocator);
    try args.append(try allocator.dupe(u8, "git"));
    try args.append(try allocator.dupe(u8, "clone"));
    try args.append(try allocator.dupe(u8, "--progress"));
    if (fields.branch.len != 0) {
        try args.append(try allocator.dupe(u8, "--branch"));
        try args.append(try allocator.dupe(u8, fields.branch));
    }
    if (fields.depth.len != 0) {
        try args.append(try allocator.dupe(u8, "--depth"));
        try args.append(try allocator.dupe(u8, fields.depth));
    }
    try args.append(try allocator.dupe(u8, "--"));
    try args.append(try allocator.dupe(u8, fields.url));
    try args.append(try allocator.dupe(u8, fields.destination));
    return args.toOwnedSlice();
}

pub fn openClone(parent: c.HWND, allocator: std.mem.Allocator, initial: CloneFields) !?CloneFields {
    const result = try openRepositoryDialog(parent, allocator, .clone, initial.values());
    const fields = result orelse return null;
    return .{
        .url = fields[0],
        .destination = fields[1],
        .branch = fields[2],
        .depth = fields[3],
    };
}

pub fn openRemote(parent: c.HWND, allocator: std.mem.Allocator, initial: RemoteFields) !?RemoteFields {
    const result = try openRepositoryDialog(parent, allocator, .remote, initial.values());
    const fields = result orelse return null;
    return .{
        .host = fields[0],
        .user = fields[1],
        .port = fields[2],
        .path = fields[3],
    };
}

const DialogKind = enum { clone, remote };
const repository_dialog_class = std.unicode.utf8ToUtf16LeStringLiteral("GraphCodeRepositoryIngressDialog");
const clone_title = "Clone Repository";
const clone_intro = "Enter an HTTPS repository URL and choose where GraphCode should create the local repository folder.";
const remote_title = "Add SSH Repository";
const remote_intro = "Connect to an existing Git repository over SSH. GraphCode validates the connection before saving it.";
const id_url_or_host = 4101;
const id_destination_or_user = 4102;
const id_branch_or_port = 4103;
const id_depth_or_path = 4104;
const id_browse = 4110;
const id_accept = 1;
const id_cancel = 2;
const em_setcuebanner = 0x1501;

const RepositoryDialogState = struct {
    allocator: std.mem.Allocator,
    parent: c.HWND,
    kind: DialogKind,
    initial: [4][]const u8,
    edits: [4]c.HWND = [_]c.HWND{null} ** 4,
    error_label: c.HWND = null,
    destination_hint: c.HWND = null,
    accepted_values: [4][]u8 = [_][]u8{&.{}} ** 4,
    clone_parent: ?[]u8 = null,
    updating_destination: bool = false,
    accepted: bool = false,
    closed: bool = false,
    host: ?*SheetFramework.Host = null,
    content_root: c.HWND = null,
    labels: [5]c.HWND = .{ null, null, null, null, null },
    browse: c.HWND = null,
    dpi: u32 = Dpi.base_dpi,
};

var repository_dialog_active = false;
var repository_dialog_state: RepositoryDialogState = undefined;

fn repositoryHeading(kind: DialogKind) []const u8 {
    return switch (kind) {
        .clone => clone_title ++ "\r\n" ++ clone_intro,
        .remote => remote_title ++ "\r\n" ++ remote_intro,
    };
}

fn openRepositoryDialog(
    parent: c.HWND,
    allocator: std.mem.Allocator,
    kind: DialogKind,
    initial: [4][]const u8,
) !?[4][]u8 {
    if (repository_dialog_active) return error.RepositoryDialogAlreadyOpen;
    try registerRepositoryDialogClass();
    repository_dialog_state = .{
        .allocator = allocator,
        .parent = parent,
        .kind = kind,
        .initial = initial,
    };
    repository_dialog_active = true;
    errdefer repository_dialog_active = false;
    errdefer if (repository_dialog_state.clone_parent) |path| allocator.free(path);

    repository_dialog_state.dpi = Dpi.normalize(Win32.dpiForWindow(parent));
    var host: SheetFramework.Host = .{};
    defer host.deinit();
    try createRepositorySheet(&host, parent);
    _ = c.SetFocus(repository_dialog_state.edits[0]);
    try host.runModal();
    if (repository_dialog_state.clone_parent) |path| allocator.free(path);
    repository_dialog_active = false;
    if (!repository_dialog_state.accepted) return null;
    return repository_dialog_state.accepted_values;
}

fn registerRepositoryDialogClass() !void {
    var klass: c.WNDCLASSW = std.mem.zeroes(c.WNDCLASSW);
    klass.lpfnWndProc = @ptrCast(&repositoryContentProc);
    klass.hInstance = c.GetModuleHandleW(null);
    klass.lpszClassName = repository_dialog_class.ptr;
    klass.hCursor = c.LoadCursorW(null, Win32.resourceIdentifier(32512));
    klass.hbrBackground = null;
    if (c.RegisterClassW(&klass) == 0 and c.GetLastError() != c.ERROR_CLASS_ALREADY_EXISTS)
        return error.RepositoryDialogClassRegistrationFailed;
}

fn createRepositorySheet(host: *SheetFramework.Host, parent: c.HWND) !void {
    const extent: i32 = if (repository_dialog_state.kind == .clone) 422 else 400;
    try host.init(parent, .{
        .layout_input = .{
            .owner = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
            .dpi = repository_dialog_state.dpi,
            .desired_width = 640,
            .minimum_width = 480,
            .heights = .{ .minimum = 390, .ideal = extent + 64, .maximum = 680 },
            .content_extent = extent,
        },
        .context = &repository_dialog_state,
        .on_layout = &layoutRepositorySheet,
        .on_message = &repositorySheetMessage,
    });
    const title = if (repository_dialog_state.kind == .clone) clone_title else remote_title;
    const wide_title = try wideZ(repository_dialog_state.allocator, title);
    defer repository_dialog_state.allocator.free(wide_title);
    if (c.SetWindowTextW(host.hwnd, wide_title.ptr) == 0) return error.RepositoryDialogCreationFailed;
    repository_dialog_state.host = host;
    repository_dialog_state.content_root = c.CreateWindowExW(c.WS_EX_CONTROLPARENT, repository_dialog_class.ptr, null, c.WS_CHILD | c.WS_VISIBLE | c.WS_CLIPCHILDREN, 0, 0, 0, 0, host.viewport, null, c.GetModuleHandleW(null), null) orelse
        return error.RepositoryDialogCreationFailed;
    createRepositoryDialogControls(repository_dialog_state.content_root);
    const actions = repositoryFooterActions(host.hwnd, repository_dialog_state.dpi, repository_dialog_state.kind);
    try host.configureFooter(&actions);
    _ = try host.createFooterButton(id_cancel, std.unicode.utf8ToUtf16LeStringLiteral("Cancel").ptr);
    _ = try host.createFooterButton(id_accept, if (repository_dialog_state.kind == .clone)
        std.unicode.utf8ToUtf16LeStringLiteral("Clone").ptr
    else
        std.unicode.utf8ToUtf16LeStringLiteral("Connect").ptr);
    AppFont.apply(c.GetDlgItem(host.hwnd, id_cancel), AppFont.control_size, false);
    AppFont.apply(c.GetDlgItem(host.hwnd, id_accept), AppFont.control_size, false);
    try host.relayout();
}

fn applyControlFontForDpi(control: c.HWND, font: c.HFONT) void {
    if (control != null) _ = c.SendMessageW(control, c.WM_SETFONT, @intFromPtr(font), 1);
}

fn applyRepositoryControlFontsForDpi(state: *RepositoryDialogState, dpi: u32) !void {
    const font = AppFont.getForDpi(AppFont.control_size, false, dpi) orelse return error.RepositoryDialogFontCreationFailed;
    for (state.labels) |label| applyControlFontForDpi(label, font);
    for (state.edits) |edit| applyControlFontForDpi(edit, font);
    applyControlFontForDpi(state.destination_hint, font);
    applyControlFontForDpi(state.error_label, font);
    applyControlFontForDpi(state.browse, font);
    applyControlFontForDpi(c.GetDlgItem(state.host.?.hwnd, id_cancel), font);
    applyControlFontForDpi(c.GetDlgItem(state.host.?.hwnd, id_accept), font);
}

fn layoutRepositorySheet(context: ?*anyopaque, layout: SheetFramework.Layout) !void {
    const state: *RepositoryDialogState = @ptrCast(@alignCast(context.?));
    if (state.content_root == null) return;
    state.dpi = state.host.?.options.layout_input.dpi;
    try applyRepositoryControlFontsForDpi(state, state.dpi);
    const scrollbar = if (layout.scroll.visible) SheetFramework.Metrics.forDpi(state.dpi).scrollbar_width else 0;
    const content_width = @max(0, layout.viewport.width - scrollbar);
    if (c.MoveWindow(state.content_root, 0, -layout.scroll.offset, content_width, @max(layout.scroll.extent, layout.viewport.height), 1) == 0)
        return error.RepositoryDialogLayoutFailed;
    const width = @max(0, content_width - Dpi.scale(48, state.dpi));
    const clone_y = [_]i32{ 78, 154, 246, 322 };
    const remote_y = [_]i32{ 78, 154, 230, 306 };
    if (state.labels[0] != null and c.MoveWindow(state.labels[0], Dpi.scale(24, state.dpi), Dpi.scale(20, state.dpi), width, Dpi.scale(42, state.dpi), 1) == 0)
        return error.RepositoryDialogLayoutFailed;
    for (state.edits, 0..) |edit, index| if (edit != null) {
        const label_y = if (state.kind == .clone) clone_y[index] else remote_y[index];
        const edit_width = if (state.kind == .clone and index == 1) @max(0, width - Dpi.scale(120, state.dpi)) else width;
        if (c.MoveWindow(edit, Dpi.scale(24, state.dpi), Dpi.scale(label_y + 24, state.dpi), edit_width, Dpi.scale(28, state.dpi), 1) == 0)
            return error.RepositoryDialogLayoutFailed;
        if (state.labels[index + 1] != null and c.MoveWindow(state.labels[index + 1], Dpi.scale(24, state.dpi), Dpi.scale(label_y, state.dpi), width, Dpi.scale(20, state.dpi), 1) == 0)
            return error.RepositoryDialogLayoutFailed;
    };
    if (state.kind == .clone) {
        if (state.browse != null and c.MoveWindow(state.browse, @max(Dpi.scale(24, state.dpi), content_width - Dpi.scale(132, state.dpi)), Dpi.scale(178, state.dpi), Dpi.scale(108, state.dpi), Dpi.scale(30, state.dpi), 1) == 0)
            return error.RepositoryDialogLayoutFailed;
        if (state.destination_hint != null and c.MoveWindow(state.destination_hint, Dpi.scale(24, state.dpi), Dpi.scale(214, state.dpi), width, Dpi.scale(20, state.dpi), 1) == 0)
            return error.RepositoryDialogLayoutFailed;
    }

    const error_y: i32 = if (state.kind == .clone) 388 else 366;
    if (state.error_label != null and c.MoveWindow(state.error_label, Dpi.scale(24, state.dpi), Dpi.scale(error_y, state.dpi), width, Dpi.scale(34, state.dpi), 1) == 0)
        return error.RepositoryDialogLayoutFailed;
}

fn footerTextWidth(hwnd: c.HWND, dpi: u32, text: []const u16, fallback: i32) i32 {
    const hdc = c.GetDC(hwnd);
    if (hdc == null) return Dpi.scale(fallback, dpi);
    defer _ = c.ReleaseDC(hwnd, hdc);
    const old_font = AppFont.selectForDpi(hdc, AppFont.control_size, false);
    defer _ = c.SelectObject(hdc, old_font);
    var size: c.SIZE = undefined;
    if (c.GetTextExtentPoint32W(hdc, text.ptr, @intCast(text.len), &size) == 0)
        return Dpi.scale(fallback, dpi);
    return size.cx;
}

fn repositoryFooterActions(hwnd: c.HWND, dpi: u32, kind: DialogKind) [2]SheetFramework.FooterAction {
    const primary_width = if (kind == .clone)
        footerTextWidth(hwnd, dpi, std.unicode.utf8ToUtf16LeStringLiteral("Clone"), 42)
    else
        footerTextWidth(hwnd, dpi, std.unicode.utf8ToUtf16LeStringLiteral("Connect"), 58);
    return .{
        .{ .id = id_cancel, .role = .cancel, .measured_text_width = footerTextWidth(hwnd, dpi, std.unicode.utf8ToUtf16LeStringLiteral("Cancel"), 48) },
        .{ .id = id_accept, .role = .primary, .measured_text_width = primary_width, .return_hint = true },
    };
}

fn operationFooterActions(hwnd: c.HWND, dpi: u32) [1]SheetFramework.FooterAction {
    return .{
        .{ .id = operation_cancel_id, .role = .cancel, .measured_text_width = footerTextWidth(hwnd, dpi, std.unicode.utf8ToUtf16LeStringLiteral("Cancel"), 48) },
    };
}

fn closeRepositoryDialog() void {
    repository_dialog_state.closed = true;
    if (repository_dialog_state.host) |host| host.requestClose();
}

fn handleRepositoryMessage(hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM) bool {
    switch (message) {
        c.WM_COMMAND => {
            const command: u16 = @truncate(wparam);
            const notification: u16 = @truncate(wparam >> 16);
            if (command == id_accept) {
                acceptRepositoryDialog();
                return true;
            }
            if (command == id_cancel) {
                closeRepositoryDialog();
                return true;
            }
            if (command == id_browse) {
                browseCloneDestination(hwnd);
                return true;
            }
            if (repository_dialog_state.kind == .clone and notification == c.EN_CHANGE) {
                if (command == id_url_or_host) updateCloneDestinationPresentation();
                if (command == id_destination_or_user and !repository_dialog_state.updating_destination) {
                    if (repository_dialog_state.clone_parent) |path| {
                        repository_dialog_state.allocator.free(path);
                        repository_dialog_state.clone_parent = null;
                    }
                }
            }
            if (notification == c.EN_SETFOCUS and command >= id_url_or_host and command <= id_depth_or_path) {
                const index = command - id_url_or_host;
                const clone_y = [_]i32{ 78, 154, 246, 322 };
                const remote_y = [_]i32{ 78, 154, 230, 306 };
                const top = if (repository_dialog_state.kind == .clone) clone_y[index] else remote_y[index];
                repository_dialog_state.host.?.reveal(Dpi.scale(top, repository_dialog_state.dpi), Dpi.scale(top + 58, repository_dialog_state.dpi)) catch {};
            }
            return true;
        },
        c.WM_CLOSE => {
            closeRepositoryDialog();
            return true;
        },
        else => return false,
    }
    return false;
}

fn repositorySheetMessage(context: ?*anyopaque, hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM, result: *c.LRESULT) bool {
    _ = context;
    if (message == c.WM_DRAWITEM) {
        result.* = drawFooterItem(repository_dialog_state.host.?, lparam);
        return true;
    }
    if (message == c.DM_GETDEFID) {
        result.* = (c.DC_HASDEFID << 16) | id_accept;
        return true;
    }
    if (handleRepositoryMessage(hwnd, message, wparam)) {
        result.* = 0;
        return true;
    }
    return false;
}

fn repositoryContentProc(hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    if (!repository_dialog_active or repository_dialog_state.host == null) return c.DefWindowProcW(hwnd, message, wparam, lparam);
    if (handleRepositoryMessage(repository_dialog_state.host.?.hwnd, message, wparam)) return 0;
    switch (message) {
        c.WM_ERASEBKGND => return darkDialogEraseBackground(hwnd, wparam),
        c.WM_CTLCOLORSTATIC => return darkDialogCtlColorStatic(controlHandleFrom(lparam), wparam, repository_dialog_state.error_label),
        c.WM_CTLCOLOREDIT => return darkDialogCtlColorEdit(wparam),
        c.WM_PAINT => {
            var paint: c.PAINTSTRUCT = undefined;
            const hdc = c.BeginPaint(hwnd, &paint);
            if (hdc != null) {
                const focus = c.GetFocus();
                for (repository_dialog_state.edits) |edit| if (edit != null) drawRepositoryField(hwnd, hdc, edit, focus == edit);
                _ = c.EndPaint(hwnd, &paint);
            }
            return 0;
        },
        else => return c.DefWindowProcW(hwnd, message, wparam, lparam),
    }
}

fn createRepositoryDialogControls(hwnd: c.HWND) void {
    const state = &repository_dialog_state;
    state.labels[0] = createStatic(hwnd, repositoryHeading(state.kind), 24, 20, 592, 42);
    if (state.kind == .clone) {
        createLabeledEdit(hwnd, 0, "Repository URL", "https://github.com/owner/repository.git", 78);
        createLabeledEdit(hwnd, 1, "Destination folder", "C:\\Users\\you\\Source\\repository", 154);
        state.browse = createButton(hwnd, "Browse…", id_browse, 508, 180, 108, 28, false);
        state.destination_hint = createStatic(hwnd, "", 24, 214, 592, 20);
        createLabeledEdit(hwnd, 2, "Branch (optional)", "Leave empty to use the repository default", 246);
        createLabeledEdit(hwnd, 3, "Depth (optional)", "Leave empty for full history", 322);
    } else {
        createLabeledEdit(hwnd, 0, "Host", "git.example.com", 78);
        createLabeledEdit(hwnd, 1, "User", "git", 154);
        createLabeledEdit(hwnd, 2, "Port", "22", 230);
        createLabeledEdit(hwnd, 3, "Absolute repository path", "/srv/git/repository.git", 306);
    }
    const error_y: i32 = if (state.kind == .clone) 388 else 366;
    state.error_label = createStatic(hwnd, "", 24, error_y, 592, 34);
    updateCloneDestinationPresentation();
}

fn createLabeledEdit(hwnd: c.HWND, index: usize, label: []const u8, cue: []const u8, y: i32) void {
    repository_dialog_state.labels[index + 1] = createStatic(hwnd, label, 24, y, 592, 20);
    const width: i32 = if (repository_dialog_state.kind == .clone and index == 1) 472 else 592;
    const edit = createControl(
        hwnd,
        0,
        "EDIT",
        repository_dialog_state.initial[index],
        c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.ES_AUTOHSCROLL,
        24,
        y + 24,
        width,
        28,
        id_url_or_host + index,
    );
    repository_dialog_state.edits[index] = edit;
    const wide_cue = wideZ(repository_dialog_state.allocator, cue) catch return;
    defer repository_dialog_state.allocator.free(wide_cue);
    _ = c.SendMessageW(edit, em_setcuebanner, 1, @bitCast(@intFromPtr(wide_cue.ptr)));
}

fn createStatic(hwnd: c.HWND, text: []const u8, x: i32, y: i32, width: i32, height: i32) c.HWND {
    return createControl(hwnd, 0, "STATIC", text, c.WS_CHILD | c.WS_VISIBLE | c.SS_LEFT, x, y, width, height, 0);
}

fn createButton(hwnd: c.HWND, text: []const u8, id: usize, x: i32, y: i32, width: i32, height: i32, default: bool) c.HWND {
    return createControl(
        hwnd,
        0,
        "BUTTON",
        text,
        c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | @as(c.LONG, if (default) 1 else 0),
        Dpi.scale(x, repository_dialog_state.dpi),
        Dpi.scale(y, repository_dialog_state.dpi),
        Dpi.scale(width, repository_dialog_state.dpi),
        Dpi.scale(height, repository_dialog_state.dpi),
        id,
    );
}

fn createControl(
    hwnd: c.HWND,
    ex_style: c.DWORD,
    class: []const u8,
    text: []const u8,
    style: c.LONG,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    id: usize,
) c.HWND {
    const allocator = repository_dialog_state.allocator;
    const wide_class = wideZ(allocator, class) catch return null;
    defer allocator.free(wide_class);
    const wide_text = wideZ(allocator, text) catch return null;
    defer allocator.free(wide_text);
    const control = c.CreateWindowExW(
        ex_style,
        wide_class.ptr,
        wide_text.ptr,
        @bitCast(style),
        x,
        y,
        width,
        height,
        hwnd,
        controlId(id),
        c.GetModuleHandleW(null),
        null,
    ) orelse return null;
    AppFont.apply(control, AppFont.control_size, false);
    return control;
}

fn controlId(id: usize) c.HMENU {
    if (id == 0) return null;
    @setRuntimeSafety(false);
    return @ptrFromInt(id);
}

fn acceptRepositoryDialog() void {
    const allocator = repository_dialog_state.allocator;
    const values = readRepositoryDialogValues(allocator) catch {
        showRepositoryDialogError("Unable to read the dialog fields.");
        return;
    };
    var owned_values = values;
    if (repository_dialog_state.kind == .clone) {
        validateClone(.{
            .url = owned_values[0],
            .destination = owned_values[1],
            .branch = owned_values[2],
            .depth = owned_values[3],
        }) catch |err| {
            showRepositoryDialogError(validationMessage(err));
            freeDialogValues(allocator, &owned_values);
            return;
        };
        const destination_exists = inspectDestination(owned_values[1]) catch {
            showRepositoryDialogError("The destination folder cannot be used.");
            freeDialogValues(allocator, &owned_values);
            return;
        };
        if (destination_exists) {
            showRepositoryDialogError("Choose a destination folder that does not already exist.");
            freeDialogValues(allocator, &owned_values);
            return;
        }
        const parent_path = std.fs.path.dirname(owned_values[1]) orelse ".";
        var parent_dir = std.fs.cwd().openDir(parent_path, .{}) catch {
            showRepositoryDialogError("The destination's parent folder does not exist.");
            freeDialogValues(allocator, &owned_values);
            return;
        };
        parent_dir.close();
    } else {
        validateRemote(.{
            .host = owned_values[0],
            .user = owned_values[1],
            .port = owned_values[2],
            .path = owned_values[3],
        }) catch |err| {
            showRepositoryDialogError(validationMessage(err));
            freeDialogValues(allocator, &owned_values);
            return;
        };
    }
    repository_dialog_state.accepted_values = owned_values;
    repository_dialog_state.accepted = true;
    closeRepositoryDialog();
}

fn drawRepositoryField(parent: c.HWND, hdc: c.HDC, edit: c.HWND, focused: bool) void {
    var bounds: c.RECT = undefined;
    if (c.GetWindowRect(edit, &bounds) == 0) return;
    var origin = c.POINT{ .x = bounds.left, .y = bounds.top };
    _ = c.ScreenToClient(parent, &origin);
    SheetFramework.drawField(hdc, .{
        .x = origin.x - Dpi.scale(4, repository_dialog_state.dpi),
        .y = origin.y - Dpi.scale(4, repository_dialog_state.dpi),
        .width = bounds.right - bounds.left + Dpi.scale(8, repository_dialog_state.dpi),
        .height = bounds.bottom - bounds.top + Dpi.scale(8, repository_dialog_state.dpi),
    }, repository_dialog_state.dpi, focused) catch {};
}

fn readRepositoryDialogValues(allocator: std.mem.Allocator) ![4][]u8 {
    var values: [4][]u8 = undefined;
    var count: usize = 0;
    errdefer for (values[0..count]) |value| allocator.free(value);
    for (repository_dialog_state.edits, 0..) |edit, index| {
        const raw = try readControlText(allocator, edit);
        defer allocator.free(raw);
        values[index] = try allocator.dupe(u8, std.mem.trim(u8, raw, " \t\r\n"));
        count += 1;
    }
    return values;
}

fn freeDialogValues(allocator: std.mem.Allocator, values: *[4][]u8) void {
    for (values) |value| allocator.free(value);
}

fn showRepositoryDialogError(message: []const u8) void {
    setControlText(repository_dialog_state.error_label, message);
    _ = c.ShowWindow(repository_dialog_state.error_label, c.SW_SHOW);
}

fn validationMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingRepositoryURL => "Enter the HTTPS repository URL.",
        error.HTTPSRequired => "Repository URL must begin with https://.",
        error.MissingDestination => "Choose or enter a destination folder.",
        error.InvalidDestination => "The destination folder contains invalid characters.",
        error.InvalidDepth => "Depth must be a whole number greater than zero.",
        error.MissingRemoteField => "Enter the host, user, port, and repository path.",
        error.AbsolutePathRequired => "Repository path must be absolute and begin with /.",
        error.InvalidPort => "Port must be a number from 1 through 65535.",
        error.InvalidSSHComponent => "Host, user, or path contains an invalid value.",
        else => "Check the highlighted repository details and try again.",
    };
}

fn browseCloneDestination(hwnd: c.HWND) void {
    if (builtin.is_test) {
        showRepositoryDialogError("The Windows folder picker is unavailable in hidden tests.");
        return;
    }
    var wide_path: [32768]u16 = [_]u16{0} ** 32768;
    const picked = graphcode_pick_folder(hwnd, &wide_path, wide_path.len);
    if (picked <= 0) {
        if (picked < 0) showRepositoryDialogError("The Windows folder picker could not be opened.");
        return;
    }
    const end = std.mem.indexOfScalar(u16, &wide_path, 0) orelse wide_path.len;
    const parent = std.unicode.utf16LeToUtf8Alloc(repository_dialog_state.allocator, wide_path[0..end]) catch {
        showRepositoryDialogError("The selected folder name could not be read.");
        return;
    };
    if (repository_dialog_state.clone_parent) |old| repository_dialog_state.allocator.free(old);
    repository_dialog_state.clone_parent = parent;
    updateCloneDestinationPresentation();
}

fn updateCloneDestinationPresentation() void {
    if (repository_dialog_state.kind != .clone or repository_dialog_state.edits[0] == null) return;
    const allocator = repository_dialog_state.allocator;
    const url = readControlText(allocator, repository_dialog_state.edits[0]) catch return;
    defer allocator.free(url);
    const folder = deriveRepositoryFolderName(allocator, url) catch return;
    defer allocator.free(folder);
    const hint = std.fmt.allocPrint(allocator, "Repository folder: {s}", .{folder}) catch return;
    defer allocator.free(hint);
    setControlText(repository_dialog_state.destination_hint, hint);
    if (repository_dialog_state.clone_parent) |parent| {
        const destination = std.fs.path.join(allocator, &.{ parent, folder }) catch return;
        defer allocator.free(destination);
        repository_dialog_state.updating_destination = true;
        setControlText(repository_dialog_state.edits[1], destination);
        repository_dialog_state.updating_destination = false;
    }
}

fn deriveRepositoryFolderName(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, url, " \t\r\n");
    const suffix_end = std.mem.indexOfAny(u8, trimmed, "?#") orelse trimmed.len;
    const without_suffix = std.mem.trimRight(u8, trimmed[0..suffix_end], "/");
    const scheme = std.mem.indexOf(u8, without_suffix, "://") orelse return allocator.dupe(u8, "repository");
    const slash = std.mem.lastIndexOfScalar(u8, without_suffix, '/') orelse return allocator.dupe(u8, "repository");
    if (slash < scheme + 3) return allocator.dupe(u8, "repository");
    var segment = without_suffix[slash + 1 ..];
    if (std.mem.endsWith(u8, segment, ".git")) segment = segment[0 .. segment.len - 4];
    var result = std.array_list.Managed(u8).init(allocator);
    defer result.deinit();
    for (segment) |byte| {
        if (byte < 32 or std.mem.indexOfScalar(u8, "<>:\"/\\|?*", byte) != null)
            try result.append('-')
        else
            try result.append(byte);
    }
    while (result.items.len != 0 and
        (result.items[result.items.len - 1] == '.' or result.items[result.items.len - 1] == ' '))
    {
        _ = result.pop();
    }
    if (result.items.len == 0) return allocator.dupe(u8, "repository");
    return result.toOwnedSlice();
}

fn readControlText(allocator: std.mem.Allocator, control: c.HWND) ![]u8 {
    const length: usize = @intCast(c.GetWindowTextLengthW(control));
    const wide = try allocator.alloc(u16, length + 1);
    defer allocator.free(wide);
    const copied = c.GetWindowTextW(control, wide.ptr, @intCast(wide.len));
    return std.unicode.utf16LeToUtf8Alloc(allocator, wide[0..@intCast(copied)]);
}

fn setControlText(control: c.HWND, value: []const u8) void {
    if (control == null) return;
    const wide = wideZ(repository_dialog_state.allocator, value) catch return;
    defer repository_dialog_state.allocator.free(wide);
    _ = c.SetWindowTextW(control, wide.ptr);
}

fn wideZ(allocator: std.mem.Allocator, value: []const u8) ![]u16 {
    const raw = try std.unicode.utf8ToUtf16LeAlloc(allocator, value);
    defer allocator.free(raw);
    const result = try allocator.alloc(u16, raw.len + 1);
    @memcpy(result[0..raw.len], raw);
    result[raw.len] = 0;
    return result;
}

pub fn runClone(allocator: std.mem.Allocator, fields: CloneFields) !CloneStatus {
    var process = try CloneProcess.start(allocator, fields);
    defer process.deinit();
    var stdout_done = std.atomic.Value(bool).init(false);
    var stderr_done = std.atomic.Value(bool).init(false);
    var stdout_thread = try std.Thread.spawn(.{}, drainPipe, .{ &process, &process.child.stdout.?, false, &stdout_done });
    var stderr_thread = try std.Thread.spawn(.{}, drainPipe, .{ &process, &process.child.stderr.?, true, &stderr_done });
    stdout_thread.join();
    stderr_thread.join();
    return process.finish();
}

const operation_dialog_class = std.unicode.utf8ToUtf16LeStringLiteral("GraphCodeRepositoryOperationDialog");
const operation_timer_id = 7;
const operation_cancel_id = 3;

const OperationDialogState = struct {
    allocator: std.mem.Allocator,
    parent: c.HWND,
    clone: ?*CloneOperation = null,
    remote: ?*RemoteValidationOperation = null,
    label: c.HWND = null,
    cancel: c.HWND = null,
    closed: bool = false,
    cancelled: bool = false,
    host: ?*SheetFramework.Host = null,
    content_root: c.HWND = null,
    dpi: u32 = Dpi.base_dpi,
};

var operation_dialog_active = false;
var operation_dialog_state: OperationDialogState = undefined;

fn acquireOperationDialog() !void {
    if (operation_dialog_active) return error.OperationDialogAlreadyOpen;
    operation_dialog_active = true;
}

fn releaseOperationDialog() void {
    operation_dialog_active = false;
}

pub fn showCloneProgress(parent: c.HWND, allocator: std.mem.Allocator, operation: *CloneOperation) !CloneStatus {
    try acquireOperationDialog();
    defer releaseOperationDialog();
    operation_dialog_state = .{ .allocator = allocator, .parent = parent, .clone = operation };
    const status = try showOperationDialog("Cloning repository", "Starting clone…");
    return switch (status) {
        .finished => .finished,
        .cancelled => .cancelled,
        .failed => .failed,
    };
}

pub fn showRemoteValidation(parent: c.HWND, allocator: std.mem.Allocator, fields: RemoteFields) !bool {
    try acquireOperationDialog();
    defer releaseOperationDialog();
    var operation = try RemoteValidationOperation.start(allocator, fields);
    defer operation.deinit();
    operation_dialog_state = .{ .allocator = allocator, .parent = parent, .remote = operation };
    return try showOperationDialog("Validating SSH connection", "Checking host, repository path, and SSH access…") == .finished;
}

const OperationResult = enum { finished, cancelled, failed };

fn showOperationDialog(title: []const u8, initial: []const u8) !OperationResult {
    try registerOperationDialogClass();
    operation_dialog_state.closed = false;
    operation_dialog_state.cancelled = false;
    operation_dialog_state.dpi = Dpi.normalize(Win32.dpiForWindow(operation_dialog_state.parent));
    var host: SheetFramework.Host = .{};
    defer host.deinit();
    try createOperationSheet(&host, operation_dialog_state.parent, title, initial);
    const hwnd = host.hwnd;
    if (c.SetTimer(hwnd, operation_timer_id, 100, null) == 0) return error.OperationDialogTimerFailed;
    try host.runModal();
    _ = c.KillTimer(hwnd, operation_timer_id);
    if (operation_dialog_state.cancelled) return .cancelled;
    if (operation_dialog_state.clone) |operation| {
        return switch (operation.poll() orelse .failed) {
            .finished => .finished,
            .cancelled => .cancelled,
            .failed => .failed,
            .ready, .cloning => .failed,
        };
    }
    if (operation_dialog_state.remote) |operation| {
        return switch (operation.poll() orelse .failed) {
            .succeeded => .finished,
            else => .failed,
        };
    }
    return .failed;
}

fn registerOperationDialogClass() !void {
    var klass: c.WNDCLASSW = std.mem.zeroes(c.WNDCLASSW);
    klass.lpfnWndProc = @ptrCast(&operationContentProc);
    klass.hInstance = c.GetModuleHandleW(null);
    klass.lpszClassName = operation_dialog_class.ptr;
    klass.hCursor = c.LoadCursorW(null, Win32.resourceIdentifier(32512));
    klass.hbrBackground = null;
    if (c.RegisterClassW(&klass) == 0 and c.GetLastError() != c.ERROR_CLASS_ALREADY_EXISTS)
        return error.OperationDialogClassRegistrationFailed;
}

fn createOperationSheet(host: *SheetFramework.Host, parent: c.HWND, title: []const u8, initial: []const u8) !void {
    try host.init(parent, .{
        .layout_input = .{
            .owner = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
            .dpi = operation_dialog_state.dpi,
            .desired_width = 560,
            .minimum_width = 360,
            .heights = .{ .minimum = 170, .ideal = 210, .maximum = 360 },
            .content_extent = 88,
        },
        .context = &operation_dialog_state,
        .on_layout = &layoutOperationSheet,
        .on_message = &operationSheetMessage,
    });
    const wide_title = try wideZ(operation_dialog_state.allocator, title);
    defer operation_dialog_state.allocator.free(wide_title);
    if (c.SetWindowTextW(host.hwnd, wide_title.ptr) == 0) return error.OperationDialogCreationFailed;
    operation_dialog_state.host = host;
    operation_dialog_state.content_root = c.CreateWindowExW(c.WS_EX_CONTROLPARENT, operation_dialog_class.ptr, null, c.WS_CHILD | c.WS_VISIBLE, 0, 0, 0, 0, host.viewport, null, c.GetModuleHandleW(null), null) orelse
        return error.OperationDialogCreationFailed;
    operation_dialog_state.label = createOperationControl(operation_dialog_state.content_root, "STATIC", initial, 24, 24, 512, 48, 0);
    const actions = operationFooterActions(host.hwnd, operation_dialog_state.dpi);
    try host.configureFooter(&actions);
    operation_dialog_state.cancel = try host.createFooterButton(operation_cancel_id, std.unicode.utf8ToUtf16LeStringLiteral("Cancel").ptr);
    AppFont.apply(operation_dialog_state.cancel, AppFont.control_size, false);
    try host.relayout();
}

fn applyOperationControlFontsForDpi(state: *OperationDialogState, dpi: u32) !void {
    const font = AppFont.getForDpi(AppFont.control_size, false, dpi) orelse return error.OperationDialogFontCreationFailed;
    applyControlFontForDpi(state.label, font);
    applyControlFontForDpi(state.cancel, font);
}

fn layoutOperationSheet(context: ?*anyopaque, layout: SheetFramework.Layout) !void {
    const state: *OperationDialogState = @ptrCast(@alignCast(context.?));
    if (state.content_root == null) return;
    state.dpi = state.host.?.options.layout_input.dpi;
    try applyOperationControlFontsForDpi(state, state.dpi);
    const scrollbar = if (layout.scroll.visible) SheetFramework.Metrics.forDpi(state.dpi).scrollbar_width else 0;
    const content_width = @max(0, layout.viewport.width - scrollbar);
    if (c.MoveWindow(state.content_root, 0, -layout.scroll.offset, content_width, @max(layout.scroll.extent, layout.viewport.height), 1) == 0)
        return error.OperationDialogLayoutFailed;
    if (state.label != null and c.MoveWindow(state.label, Dpi.scale(24, state.dpi), Dpi.scale(24, state.dpi), @max(0, content_width - Dpi.scale(48, state.dpi)), Dpi.scale(48, state.dpi), 1) == 0)
        return error.OperationDialogLayoutFailed;
}

fn closeOperationDialog() void {
    operation_dialog_state.closed = true;
    if (operation_dialog_state.host) |host| host.requestClose();
}

fn handleOperationMessage(message: c.UINT, wparam: c.WPARAM) bool {
    switch (message) {
        c.WM_TIMER => {
            if (wparam != operation_timer_id) return false;
            if (operation_dialog_state.clone) |operation| {
                var progress: [256]u8 = undefined;
                var stderr: [256]u8 = undefined;
                const snapshot = operation.snapshot(&progress, &stderr);
                if (snapshot.progress_len != 0) setOperationText(operation_dialog_state.label, progress[0..snapshot.progress_len]);
                if (snapshot.stderr_len != 0) setOperationText(operation_dialog_state.label, stderr[0..snapshot.stderr_len]);
                if (operation.poll()) |status| {
                    if (status != .cloning) closeOperationDialog();
                }
            } else if (operation_dialog_state.remote) |operation| {
                if (operation.poll()) |status| {
                    if (status != .validating) closeOperationDialog();
                }
            }
            return true;
        },
        c.WM_COMMAND => {
            if (@as(u16, @truncate(wparam)) == operation_cancel_id) {
                operation_dialog_state.cancelled = true;
                if (operation_dialog_state.clone) |operation| operation.cancel();
                setOperationText(operation_dialog_state.label, "Cancelling…");
                if (operation_dialog_state.remote != null) setOperationText(operation_dialog_state.label, "Waiting for SSH validation to finish…");
                return true;
            }
        },
        c.WM_CLOSE => {
            operation_dialog_state.cancelled = true;
            if (operation_dialog_state.clone) |operation| operation.cancel();
            setOperationText(operation_dialog_state.label, "Cancelling…");
            return true;
        },
        else => return false,
    }
    return false;
}

fn operationSheetMessage(context: ?*anyopaque, hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM, result: *c.LRESULT) bool {
    _ = context;
    _ = hwnd;
    if (message == c.WM_DRAWITEM) {
        result.* = drawFooterItem(operation_dialog_state.host.?, lparam);
        return true;
    }
    if (handleOperationMessage(message, wparam)) {
        result.* = 0;
        return true;
    }

    return false;
}

fn drawFooterItem(host: *SheetFramework.Host, lparam: c.LPARAM) c.LRESULT {
    const item = Win32.messagePointer(*const c.DRAWITEMSTRUCT, lparam);
    var role = SheetFramework.ActionRole.secondary;
    var return_hint = false;
    for (host.footer_actions[0..host.footer_action_count]) |action| {
        if (action.id != item.CtlID) continue;
        role = action.role;
        return_hint = action.return_hint and action.role.isPrimary();
        break;
    }
    SheetFramework.drawButton(item.hDC, .{ .x = item.rcItem.left, .y = item.rcItem.top, .width = item.rcItem.right - item.rcItem.left, .height = item.rcItem.bottom - item.rcItem.top }, host.options.layout_input.dpi, role, item.itemState & c.ODS_DISABLED == 0, item.itemState & c.ODS_SELECTED != 0) catch return 0;
    var text: [128]u16 = [_]u16{0} ** 128;
    const count = c.GetWindowTextW(item.hwndItem, &text, text.len);
    const old_font = AppFont.selectForDpi(item.hDC, AppFont.control_size, false);
    defer _ = c.SelectObject(item.hDC, old_font);
    _ = c.SetBkMode(item.hDC, c.TRANSPARENT);
    _ = c.SetTextColor(item.hDC, SheetFramework.controlPaintStyle(.button, item.itemState & c.ODS_DISABLED == 0).foreground);
    var bounds = item.rcItem;
    if (return_hint) bounds.right -= SheetFramework.Metrics.forDpi(host.options.layout_input.dpi).return_hint_width;
    _ = c.DrawTextW(item.hDC, &text, count, &bounds, c.DT_CENTER | c.DT_VCENTER | c.DT_SINGLELINE);
    if (return_hint) {
        var hint_bounds = item.rcItem;
        hint_bounds.left = bounds.right;
        _ = c.DrawTextW(item.hDC, std.unicode.utf8ToUtf16LeStringLiteral("\u{21b5}").ptr, 1, &hint_bounds, c.DT_CENTER | c.DT_VCENTER | c.DT_SINGLELINE);
    }
    return 1;
}

fn operationContentProc(hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    if (!operation_dialog_active or operation_dialog_state.host == null) return c.DefWindowProcW(hwnd, message, wparam, lparam);
    switch (message) {
        c.WM_ERASEBKGND => return darkDialogEraseBackground(hwnd, wparam),
        c.WM_CTLCOLORSTATIC => return darkDialogCtlColorStatic(controlHandleFrom(lparam), wparam, null),
        else => return c.DefWindowProcW(hwnd, message, wparam, lparam),
    }
}

fn createOperationControl(hwnd: c.HWND, class: []const u8, text: []const u8, x: i32, y: i32, width: i32, height: i32, id: usize) c.HWND {
    const allocator = operation_dialog_state.allocator;
    const wide_class = wideZ(allocator, class) catch return null;
    defer allocator.free(wide_class);
    const wide_text = wideZ(allocator, text) catch return null;
    defer allocator.free(wide_text);
    const style: c.DWORD = @as(c.DWORD, @intCast(c.WS_CHILD)) |
        @as(c.DWORD, @intCast(c.WS_VISIBLE)) |
        (if (std.mem.eql(u8, class, "BUTTON")) @as(c.DWORD, @intCast(c.WS_TABSTOP)) else 0);
    const control = c.CreateWindowExW(0, wide_class.ptr, wide_text.ptr, style, Dpi.scale(x, operation_dialog_state.dpi), Dpi.scale(y, operation_dialog_state.dpi), Dpi.scale(width, operation_dialog_state.dpi), Dpi.scale(height, operation_dialog_state.dpi), hwnd, controlId(id), c.GetModuleHandleW(null), null) orelse return null;
    AppFont.apply(control, AppFont.control_size, false);
    return control;
}

fn setOperationText(control: c.HWND, text: []const u8) void {
    if (control == null) return;
    const wide = wideZ(operation_dialog_state.allocator, text) catch return;
    defer operation_dialog_state.allocator.free(wide);
    _ = c.SetWindowTextW(control, wide.ptr);
}

fn drainPipe(process: *CloneProcess, file: *std.fs.File, is_stderr: bool, done: *std.atomic.Value(bool)) void {
    defer done.store(true, .release);
    var buffer: [4096]u8 = undefined;
    while (true) {
        const count = file.read(&buffer) catch return;
        if (count == 0) {
            process.recordOutput(&.{}, is_stderr, true);
            return;
        }
        process.recordOutput(buffer[0..count], is_stderr, false);
    }
}

fn drainPipeDiscard(file: *std.fs.File) void {
    var buffer: [4096]u8 = undefined;
    while ((file.read(&buffer) catch 0) != 0) {}
}

test "operation dialogs reject reentrant acquisition and allow sequential dialogs" {
    operation_dialog_active = false;
    defer operation_dialog_active = false;

    try acquireOperationDialog();
    try std.testing.expect(operation_dialog_active);
    try std.testing.expectError(error.OperationDialogAlreadyOpen, acquireOperationDialog());

    releaseOperationDialog();
    try std.testing.expect(!operation_dialog_active);
    try acquireOperationDialog();
    try std.testing.expect(operation_dialog_active);
    releaseOperationDialog();
}

test "clone dialog derives safe destination folder names" {
    const standard = try deriveRepositoryFolderName(std.testing.allocator, "https://example.test/org/GraphCode.git");
    defer std.testing.allocator.free(standard);
    try std.testing.expectEqualStrings("GraphCode", standard);

    const sanitized = try deriveRepositoryFolderName(std.testing.allocator, "https://example.test/org/repo%20name.git?ref=main");
    defer std.testing.allocator.free(sanitized);
    try std.testing.expectEqualStrings("repo%20name", sanitized);

    const fallback = try deriveRepositoryFolderName(std.testing.allocator, "https://example.test/");
    defer std.testing.allocator.free(fallback);
    try std.testing.expectEqualStrings("repository", fallback);
}

test "repository dialogs expose purpose-built copy and actionable validation" {
    try std.testing.expect(std.mem.indexOf(u8, clone_intro, "HTTPS repository URL") != null);
    try std.testing.expect(std.mem.indexOf(u8, remote_intro, "validates the connection") != null);
    try std.testing.expectEqualStrings(
        "Depth must be a whole number greater than zero.",
        validationMessage(error.InvalidDepth),
    );
    try std.testing.expectEqualStrings(
        "Repository path must be absolute and begin with /.",
        validationMessage(error.AbsolutePathRequired),
    );
}

test "clone validation and argv preserve HTTPS, Unicode, and option boundaries" {
    const fields = CloneFields{
        .url = "https://example.test/repo.git",
        .destination = "C:\\Users\\dev\\Проекты\\repo",
        .branch = "main",
        .depth = "1",
    };
    const args = try cloneCommand(std.testing.allocator, fields);
    defer {
        for (args) |arg| std.testing.allocator.free(arg);
        std.testing.allocator.free(args);
    }
    try std.testing.expectEqualStrings("--", args[7]);
    try std.testing.expectEqualStrings(fields.destination, args[9]);
}

test "SSH validation and reconnect command reject injection-shaped identities" {
    try std.testing.expectError(error.InvalidSSHComponent, validateRemote(.{ .host = "-oProxyCommand=x", .user = "dev", .path = "/repo" }));
    const command = try reconnectCommand(std.testing.allocator, .{ .host = "build-box", .user = "dev", .path = "/srv/граф" });
    defer std.testing.allocator.free(command);
    try std.testing.expect(std.mem.indexOf(u8, command, "BatchMode=yes") != null);
    try std.testing.expect(std.mem.indexOf(u8, command, "/srv/граф") != null);
}

test "SSH validation argv uses one quoted remote command" {
    const args = try sshValidationArgs(std.testing.allocator, .{
        .host = "build-box",
        .user = "dev",
        .port = "2222",
        .path = "/srv/граф",
    });
    defer {
        for (args) |arg| std.testing.allocator.free(arg);
        std.testing.allocator.free(args);
    }
    try std.testing.expectEqualStrings("BatchMode=yes", args[2]);
    try std.testing.expectEqualStrings("dev@build-box", args[7]);
    try std.testing.expectEqualStrings("git -C '/srv/граф' rev-parse --show-toplevel", args[8]);
}

test "SSH reconnect command quotes shell metacharacters and rejects newlines" {
    const command = try reconnectCommand(std.testing.allocator, .{
        .host = "build-box",
        .user = "dev",
        .path = "/srv/a;$(touch p)'q",
    });
    defer std.testing.allocator.free(command);
    try std.testing.expect(std.mem.indexOf(u8, command, "'/srv/a;$(touch p)'\\''q'") != null);
    try std.testing.expectError(error.InvalidSSHComponent, validateRemote(.{
        .host = "build-box",
        .user = "dev\nwhoami",
        .path = "/repo",
    }));
}

test "remote URI percent-encodes path and brackets IPv6" {
    const uri = try remoteProjectURI(std.testing.allocator, .{
        .host = "2001:db8::1",
        .user = "dev",
        .port = "2200",
        .path = "/repo name/#q?x%雪",
    });
    defer std.testing.allocator.free(uri);
    try std.testing.expectEqualStrings("ssh://dev@[2001:db8::1]:2200/repo%20name/%23q%3Fx%25%E9%9B%AA", uri);
}

test "redaction handles output larger than four kilobytes" {
    var input = std.array_list.Managed(u8).init(std.testing.allocator);
    defer input.deinit();
    try input.appendNTimes('x', 8192);
    try input.appendSlice(" https://user:very-long-secret@example.test/repo.git ");
    const safe = try redactSecrets(std.testing.allocator, input.items);
    defer std.testing.allocator.free(safe);
    try std.testing.expect(std.mem.indexOf(u8, safe, "very-long-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, safe, "<redacted>@example.test") != null);
}

test "redaction holds and removes an eight kilobyte split credential" {
    var secret = std.array_list.Managed(u8).init(std.testing.allocator);
    defer secret.deinit();
    try secret.appendNTimes('s', 9000);
    var process = CloneProcess{
        .allocator = std.testing.allocator,
        .child = undefined,
        .args = &.{},
        .destination = &.{},
        .staging = &.{},
    };
    var first = std.array_list.Managed(u8).init(std.testing.allocator);
    defer first.deinit();
    try first.appendSlice("fatal: https://user:");
    try first.appendSlice(secret.items);
    process.recordOutput(first.items, true, false);
    var second = std.array_list.Managed(u8).init(std.testing.allocator);
    defer second.deinit();
    try second.appendSlice("@example.test/repo.git");
    process.recordOutput(second.items, true, true);
    var progress: [256]u8 = undefined;
    var stderr: [4096]u8 = undefined;
    const snapshot = process.snapshot(&progress, &stderr);
    try std.testing.expect(std.mem.indexOf(u8, stderr[0..snapshot.stderr_len], secret.items) == null);
    try std.testing.expect(std.mem.indexOf(u8, stderr[0..snapshot.stderr_len], "<redacted>@example.test") != null);
}

test "clone output redacts hostile HTTPS credentials" {
    const safe = try redactSecrets(std.testing.allocator, "fatal: https://user:p@ss;token@example.test/repo.git?access_token=secret");
    defer std.testing.allocator.free(safe);
    try std.testing.expect(std.mem.indexOf(u8, safe, "user:p@ss") == null);
    try std.testing.expect(std.mem.indexOf(u8, safe, "<redacted>@example.test") != null);
    try std.testing.expect(std.mem.indexOf(u8, safe, "secret") == null);
}

test "clone redaction survives split credential boundaries" {
    var process = CloneProcess{
        .allocator = std.testing.allocator,
        .child = undefined,
        .args = &.{},
        .destination = &.{},
        .staging = &.{},
    };
    process.recordOutput("fatal https://user:secret@", true, false);
    process.recordOutput("example.test/repo.git", true, true);
    var progress: [256]u8 = undefined;
    var stderr: [256]u8 = undefined;
    const snapshot = process.snapshot(&progress, &stderr);
    try std.testing.expect(std.mem.indexOf(u8, stderr[0..snapshot.stderr_len], "secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, stderr[0..snapshot.stderr_len], "<redacted>@example.test") != null);
}

test "clone cancellation only signals worker ownership" {
    var operation = CloneOperation{
        .allocator = std.testing.allocator,
        .process = undefined,
        .thread = undefined,
    };
    operation.cancel();
    try std.testing.expect(operation.cancel_requested.load(.acquire));
}

test "clone refuses non-empty destinations without deleting sentinels" {
    const path = "graphcode-clone-sentinel-regression";
    std.fs.cwd().deleteTree(path) catch {};
    try std.fs.cwd().makePath(path);
    defer std.fs.cwd().deleteTree(path) catch {};
    var sentinel = try std.fs.cwd().createFile("graphcode-clone-sentinel-regression\\keep.txt", .{});
    try sentinel.writeAll("keep");
    sentinel.close();
    try std.testing.expectError(error.DestinationAlreadyExists, CloneProcess.start(std.testing.allocator, .{
        .url = "https://example.test/repo.git",
        .destination = path,
    }));
    var kept = try std.fs.cwd().openFile("graphcode-clone-sentinel-regression\\keep.txt", .{});
    defer kept.close();
    var bytes: [4]u8 = undefined;
    var reader = kept.reader(&.{});
    try reader.interface.readSliceAll(&bytes);
    try std.testing.expectEqualStrings("keep", &bytes);
}

fn hiddenRepositoryOwner() !c.HWND {
    return c.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC").ptr, null, c.WS_POPUP, 20, 20, 920, 700, null, null, c.GetModuleHandleW(null), null) orelse error.RepositoryDialogCreationFailed;
}

fn controlFont(control: c.HWND) c.HFONT {
    return Win32.opaquePointerFromInt(c.HFONT, @bitCast(c.SendMessageW(control, c.WM_GETFONT, 0, 0)));
}

fn expectControlFontForDpi(control: c.HWND, dpi: u32) !void {
    const font = controlFont(control);
    try std.testing.expectEqual(AppFont.getForDpi(AppFont.control_size, false, dpi), font);
    var info = std.mem.zeroes(c.LOGFONTW);
    try std.testing.expect(c.GetObjectW(font, @sizeOf(c.LOGFONTW), &info) != 0);
    try std.testing.expectEqual(-Dpi.scale(AppFont.control_size, dpi), info.lfHeight);
}

test "hidden repository and operation dialogs refresh every control font across DPI transitions" {
    try registerRepositoryDialogClass();
    try registerOperationDialogClass();
    const owner = try hiddenRepositoryOwner();
    defer _ = c.DestroyWindow(owner);

    repository_dialog_state = .{
        .allocator = std.testing.allocator,
        .parent = owner,
        .kind = .clone,
        .initial = .{ "https://example.test/org/repository.git", "C:\\src\\repository", "", "" },
    };
    repository_dialog_active = true;
    var repository_host: SheetFramework.Host = .{};
    try createRepositorySheet(&repository_host, owner);
    try std.testing.expect(c.IsWindowVisible(repository_host.hwnd) == 0);
    var repository_font_96: c.HFONT = null;
    for ([_]u32{ 96, 192, 96 }) |dpi| {
        try repository_host.refreshForDpi(dpi);
        for (repository_dialog_state.labels) |label| try expectControlFontForDpi(label, dpi);
        for (repository_dialog_state.edits) |edit| try expectControlFontForDpi(edit, dpi);
        try expectControlFontForDpi(repository_dialog_state.destination_hint, dpi);
        try expectControlFontForDpi(repository_dialog_state.error_label, dpi);
        try expectControlFontForDpi(repository_dialog_state.browse, dpi);
        try expectControlFontForDpi(c.GetDlgItem(repository_host.hwnd, id_cancel), dpi);
        try expectControlFontForDpi(c.GetDlgItem(repository_host.hwnd, id_accept), dpi);
        const current = controlFont(repository_dialog_state.edits[0]);
        if (repository_font_96 == null) {
            repository_font_96 = current;
        } else if (dpi == 192) {
            try std.testing.expect(current != repository_font_96);
        } else {
            try std.testing.expectEqual(repository_font_96, current);
        }
    }
    repository_host.deinit();
    repository_dialog_active = false;

    operation_dialog_state = .{ .allocator = std.testing.allocator, .parent = owner };
    operation_dialog_active = true;
    defer operation_dialog_active = false;
    var operation_host: SheetFramework.Host = .{};
    defer operation_host.deinit();
    try createOperationSheet(&operation_host, owner, "Cloning repository", "Starting clone…");
    try std.testing.expect(c.IsWindowVisible(operation_host.hwnd) == 0);
    var operation_font_96: c.HFONT = null;
    for ([_]u32{ 96, 192, 96 }) |dpi| {
        try operation_host.refreshForDpi(dpi);
        try expectControlFontForDpi(operation_dialog_state.label, dpi);
        try expectControlFontForDpi(operation_dialog_state.cancel, dpi);
        const current = controlFont(operation_dialog_state.label);
        if (operation_font_96 == null) {
            operation_font_96 = current;
        } else if (dpi == 192) {
            try std.testing.expect(current != operation_font_96);
        } else {
            try std.testing.expectEqual(operation_font_96, current);
        }
    }
}

test "dialog framework: repository ingress and operation dialogs use hidden sheets" {
    try registerRepositoryDialogClass();
    try registerOperationDialogClass();
    const owner = try hiddenRepositoryOwner();
    defer _ = c.DestroyWindow(owner);

    repository_dialog_state = .{
        .allocator = std.testing.allocator,
        .parent = owner,
        .kind = .remote,
        .initial = .{ "example.com", "git", "22", "/srv/repo.git" },
        .dpi = 144,
    };
    repository_dialog_active = true;
    var repository_host: SheetFramework.Host = .{};
    try createRepositorySheet(&repository_host, owner);
    try std.testing.expect(c.IsWindowVisible(repository_host.hwnd) == 0);
    try std.testing.expect(c.GetWindowLongPtrW(repository_host.hwnd, c.GWL_STYLE) & c.WS_CAPTION == 0);
    var repository_title: [64]u16 = [_]u16{0} ** 64;
    const repository_title_length = c.GetWindowTextW(repository_host.hwnd, &repository_title, repository_title.len);
    const expected_repository_title = std.unicode.utf8ToUtf16LeStringLiteral(remote_title);
    try std.testing.expectEqualSlices(u16, expected_repository_title[0..expected_repository_title.len], repository_title[0..@intCast(repository_title_length)]);
    const heading = try readControlText(std.testing.allocator, repository_dialog_state.labels[0]);
    defer std.testing.allocator.free(heading);
    try std.testing.expectEqualStrings(repositoryHeading(.remote), heading);
    try std.testing.expect(std.mem.startsWith(u8, repositoryHeading(.clone), clone_title));
    try std.testing.expect(c.GetParent(repository_dialog_state.content_root) == repository_host.viewport);
    try std.testing.expect(c.GetWindowLongPtrW(repository_dialog_state.content_root, c.GWL_EXSTYLE) & c.WS_EX_CONTROLPARENT != 0);
    try std.testing.expect(c.GetWindowLongPtrW(repository_dialog_state.edits[0], c.GWL_EXSTYLE) & c.WS_EX_CLIENTEDGE == 0);
    try std.testing.expect(repository_host.footer_layout.?.slotFor(id_accept).?.role == .primary);
    repository_host.options.layout_input.content_extent = Dpi.unscale(repository_host.current_layout.viewport.height, repository_dialog_state.dpi) + 100;
    try repository_host.relayout();
    var repository_viewport: c.RECT = undefined;
    var repository_content: c.RECT = undefined;
    try std.testing.expect(c.GetClientRect(repository_host.viewport, &repository_viewport) != 0);
    try std.testing.expect(c.GetClientRect(repository_dialog_state.content_root, &repository_content) != 0);
    try std.testing.expectEqual(
        SheetFramework.Metrics.forDpi(repository_dialog_state.dpi).scrollbar_width,
        (repository_viewport.right - repository_viewport.left) - (repository_content.right - repository_content.left),
    );
    for ([_]u32{ 96, 144, 192 }) |dpi| {
        const actions = repositoryFooterActions(repository_host.hwnd, dpi, .remote);
        const width = Dpi.scale(640, dpi);
        const footer = try SheetFramework.measureFooter(width, Dpi.scale(64, dpi), dpi, &actions);
        try std.testing.expect(footer.measured_minimum_width <= width);
        for (footer.slice()) |slot| try std.testing.expect(slot.bounds.x >= 0 and slot.bounds.right() <= width);
        try std.testing.expect(actions[1].return_hint);
        try std.testing.expect(footer.slotFor(id_accept).?.bounds.width >=
            actions[1].measured_text_width + SheetFramework.Metrics.forDpi(dpi).return_hint_width);
    }
    repository_host.deinit();
    repository_dialog_active = false;

    operation_dialog_state = .{ .allocator = std.testing.allocator, .parent = owner, .dpi = 192 };
    operation_dialog_active = true;
    defer operation_dialog_active = false;
    var operation_host: SheetFramework.Host = .{};
    defer operation_host.deinit();
    try createOperationSheet(&operation_host, owner, "Validating SSH connection", "Checking repository access…");
    try std.testing.expect(c.IsWindowVisible(operation_host.hwnd) == 0);
    var operation_title: [64]u16 = [_]u16{0} ** 64;
    const operation_title_length = c.GetWindowTextW(operation_host.hwnd, &operation_title, operation_title.len);
    const expected_operation_title = std.unicode.utf8ToUtf16LeStringLiteral("Validating SSH connection");
    try std.testing.expectEqualSlices(u16, expected_operation_title[0..expected_operation_title.len], operation_title[0..@intCast(operation_title_length)]);
    try std.testing.expect(c.GetParent(operation_dialog_state.content_root) == operation_host.viewport);
    try std.testing.expect(c.GetWindowLongPtrW(operation_dialog_state.content_root, c.GWL_EXSTYLE) & c.WS_EX_CONTROLPARENT != 0);
    try std.testing.expect(operation_host.footer_layout.?.slotFor(operation_cancel_id).?.role == .cancel);
}
