const std = @import("std");
const c = @import("Win32.zig").c;

extern fn graphcode_pick_folder(owner: c.HWND, buffer: [*]u16, capacity: c.DWORD) callconv(.c) c_int;

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
};

var repository_dialog_active = false;
var repository_dialog_state: RepositoryDialogState = undefined;

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

    const title = if (kind == .clone) clone_title else remote_title;
    const wide_title = try wideZ(allocator, title);
    defer allocator.free(wide_title);
    const client_width: i32 = 640;
    const client_height: i32 = if (kind == .clone) 500 else 478;
    const style = c.WS_OVERLAPPED | c.WS_CAPTION | c.WS_SYSMENU;
    const ex_style = c.WS_EX_DLGMODALFRAME | c.WS_EX_CONTROLPARENT;
    var frame = c.RECT{ .left = 0, .top = 0, .right = client_width, .bottom = client_height };
    _ = c.AdjustWindowRectEx(&frame, style, 0, ex_style);
    const width = frame.right - frame.left;
    const height = frame.bottom - frame.top;
    var owner: c.RECT = undefined;
    _ = c.GetWindowRect(parent, &owner);
    const x = owner.left + @divTrunc((owner.right - owner.left) - width, 2);
    const y = owner.top + @divTrunc((owner.bottom - owner.top) - height, 2);
    const hwnd = c.CreateWindowExW(
        ex_style,
        repository_dialog_class.ptr,
        wide_title.ptr,
        style,
        x,
        y,
        width,
        height,
        parent,
        null,
        c.GetModuleHandleW(null),
        null,
    ) orelse {
        repository_dialog_active = false;
        return error.RepositoryDialogCreationFailed;
    };
    _ = c.EnableWindow(parent, 0);
    _ = c.ShowWindow(hwnd, c.SW_SHOW);
    _ = c.SetForegroundWindow(hwnd);
    _ = c.SetFocus(repository_dialog_state.edits[0]);

    var message: c.MSG = undefined;
    while (!repository_dialog_state.closed) {
        const code = c.GetMessageW(&message, null, 0, 0);
        if (code <= 0) {
            repository_dialog_state.closed = true;
            break;
        }
        if (c.IsDialogMessageW(hwnd, &message) != 0) continue;
        _ = c.TranslateMessage(&message);
        _ = c.DispatchMessageW(&message);
    }
    _ = c.DestroyWindow(hwnd);
    _ = c.EnableWindow(parent, 1);
    _ = c.SetActiveWindow(parent);
    if (repository_dialog_state.clone_parent) |path| allocator.free(path);
    repository_dialog_active = false;
    if (!repository_dialog_state.accepted) return null;
    return repository_dialog_state.accepted_values;
}

fn registerRepositoryDialogClass() !void {
    var klass: c.WNDCLASSW = std.mem.zeroes(c.WNDCLASSW);
    klass.lpfnWndProc = @ptrCast(&repositoryDialogProc);
    klass.hInstance = c.GetModuleHandleW(null);
    klass.lpszClassName = repository_dialog_class.ptr;
    klass.hCursor = c.LoadCursorW(null, @ptrFromInt(32512));
    klass.hbrBackground = c.GetSysColorBrush(c.COLOR_WINDOW);
    if (c.RegisterClassW(&klass) == 0 and c.GetLastError() != c.ERROR_CLASS_ALREADY_EXISTS)
        return error.RepositoryDialogClassRegistrationFailed;
}

fn repositoryDialogProc(hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    if (!repository_dialog_active) return c.DefWindowProcW(hwnd, message, wparam, lparam);
    switch (message) {
        c.WM_CREATE => {
            createRepositoryDialogControls(hwnd);
            return 0;
        },
        c.WM_COMMAND => {
            const command: u16 = @truncate(wparam);
            const notification: u16 = @truncate(wparam >> 16);
            if (command == id_accept) {
                acceptRepositoryDialog();
                return 0;
            }
            if (command == id_cancel) {
                repository_dialog_state.closed = true;
                return 0;
            }
            if (command == id_browse) {
                browseCloneDestination(hwnd);
                return 0;
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
        },
        c.WM_CLOSE => {
            repository_dialog_state.closed = true;
            return 0;
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, message, wparam, lparam);
}

fn createRepositoryDialogControls(hwnd: c.HWND) void {
    const state = &repository_dialog_state;
    const intro = if (state.kind == .clone) clone_intro else remote_intro;
    _ = createStatic(hwnd, intro, 24, 20, 592, 42);
    if (state.kind == .clone) {
        createLabeledEdit(hwnd, 0, "Repository URL", "https://github.com/owner/repository.git", 78);
        createLabeledEdit(hwnd, 1, "Destination folder", "C:\\Users\\you\\Source\\repository", 154);
        _ = createButton(hwnd, "Browse…", id_browse, 508, 180, 108, 28, false);
        state.destination_hint = createStatic(hwnd, "", 24, 214, 592, 20);
        createLabeledEdit(hwnd, 2, "Branch (optional)", "Leave empty to use the repository default", 246);
        createLabeledEdit(hwnd, 3, "Depth (optional)", "Leave empty for full history", 322);
    } else {
        createLabeledEdit(hwnd, 0, "Host", "git.example.com", 78);
        createLabeledEdit(hwnd, 1, "User", "git", 154);
        createLabeledEdit(hwnd, 2, "Port", "22", 230);
        createLabeledEdit(hwnd, 3, "Absolute repository path", "/srv/git/repository.git", 306);
    }
    const button_y: i32 = if (state.kind == .clone) 446 else 424;
    state.error_label = createStatic(hwnd, "", 24, button_y - 40, 392, 34);
    _ = createButton(hwnd, "Cancel", id_cancel, 430, button_y, 88, 30, false);
    _ = createButton(hwnd, if (state.kind == .clone) "Clone" else "Connect", id_accept, 528, button_y, 88, 30, true);
    updateCloneDestinationPresentation();
}

fn createLabeledEdit(hwnd: c.HWND, index: usize, label: []const u8, cue: []const u8, y: i32) void {
    _ = createStatic(hwnd, label, 24, y, 592, 20);
    const width: i32 = if (repository_dialog_state.kind == .clone and index == 1) 472 else 592;
    const edit = createControl(
        hwnd,
        c.WS_EX_CLIENTEDGE,
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
        x,
        y,
        width,
        height,
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
    if (c.GetStockObject(c.DEFAULT_GUI_FONT)) |font|
        _ = c.SendMessageW(control, c.WM_SETFONT, @intFromPtr(font), 1);
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
    repository_dialog_state.closed = true;
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
