const std = @import("std");
const GraphModel = @import("GraphModel.zig");
const Forms = @import("Forms.zig");

pub const Origin = enum { canvas, sidebar };
pub const Operation = enum {
    export_loop,
    import_loops,

    pub fn wireName(self: Operation) []const u8 {
        return if (self == .export_loop) "export" else "import";
    }
};

pub const Status = enum {
    succeeded,
    rejected,
    oversized,
    unavailable,
    failed,
    outcome_unknown,

    fn exitCode(self: Status) u32 {
        return switch (self) {
            .succeeded => 0,
            .rejected, .oversized, .failed => 1,
            .unavailable => 69,
            .outcome_unknown => 75,
        };
    }
};

pub const FailureVerdict = struct {
    status: Status,
    summary: []const u8,
    warning: []const u8,
    fallback_message: []const u8,
};

pub fn fallbackVerdict(operation: Operation, dispatched: bool) FailureVerdict {
    if (!dispatched) return .{
        .status = .failed,
        .summary = "was not dispatched",
        .warning = "No CLI dispatch was confirmed.",
        .fallback_message = "Loop transfer was not dispatched; no CLI dispatch was confirmed.",
    };
    const export_warning = "Partial output or staging files may remain; inspect the destination and do not retry automatically.";
    const import_warning = "Graph changes or restored session files may already exist; do not retry automatically.";
    return if (operation == .export_loop) .{
        .status = .failed,
        .summary = "failed",
        .warning = export_warning,
        .fallback_message = "Loop export failed. " ++ export_warning,
    } else .{
        .status = .outcome_unknown,
        .summary = "outcome is unknown",
        .warning = import_warning,
        .fallback_message = "Loop import outcome is unknown. " ++ import_warning,
    };
}

pub const Context = struct {
    origin: Origin = .canvas,
    project_path: []const u8 = "",
    composite_id: []const u8 = "",
    node_id: []const u8 = "",
    title: []const u8 = "",
    loop_type: []const u8 = "",
    origin_project_path: []const u8 = "",
    origin_composite_id: []const u8 = "",
    origin_node_id: []const u8 = "",

    pub fn deinit(self: *Context, allocator: std.mem.Allocator) void {
        inline for (std.meta.fields(Context)) |field| {
            if (field.type == []const u8) allocator.free(@field(self, field.name));
        }
        self.* = .{};
    }

    pub fn containingComposite(self: Context) []const u8 {
        return if (self.composite_id.len == 0) "root" else self.composite_id;
    }

    pub fn capture(
        allocator: std.mem.Allocator,
        model: *const GraphModel.Model,
        origin: Origin,
        project_path: []const u8,
        composite_id: []const u8,
        node_id: []const u8,
    ) !Context {
        if (!Forms.isUuid(node_id) or (composite_id.len != 0 and !Forms.isUuid(composite_id)))
            return error.InvalidTransferArguments;
        if (origin == .sidebar and composite_id.len != 0) return error.TransferContextChanged;
        const graph = model.graph;
        var captured = Context{
            .origin = origin,
            .project_path = project_path,
            .composite_id = composite_id,
            .node_id = node_id,
            .origin_project_path = if (graph) |value| value.project.path else "",
            .origin_composite_id = model.open_composite_id orelse "",
            .origin_node_id = model.selectedNodeID() orelse "",
        };
        if (origin == .canvas and
            (!std.mem.eql(u8, project_path, captured.origin_project_path) or
                !sameOptionalUuid(composite_id, captured.origin_composite_id)))
            return error.TransferContextChanged;
        const node = try captured.targetNode(model);
        captured.title = node.title;
        captured.loop_type = node.loop_type;
        var result = Context{ .origin = origin };
        errdefer result.deinit(allocator);
        inline for (std.meta.fields(Context)) |field| {
            if (field.type == []const u8)
                @field(result, field.name) = try allocator.dupe(u8, @field(captured, field.name));
        }
        return result;
    }

    pub fn validate(self: Context, model: *const GraphModel.Model, client_composite: []const u8) !void {
        const graph = model.graph orelse return error.TransferContextChanged;
        if (!std.mem.eql(u8, graph.project.path, self.origin_project_path) or
            !std.mem.eql(u8, model.selected_project_path orelse graph.project.path, self.origin_project_path) or
            !sameOptionalUuid(model.open_composite_id orelse "", self.origin_composite_id) or
            !sameOptionalUuid(client_composite, self.origin_composite_id) or
            !sameOptionalUuid(model.selectedNodeID() orelse "", self.origin_node_id))
            return error.TransferContextChanged;
        const node = try self.targetNode(model);
        if (!std.mem.eql(u8, node.loop_type, self.loop_type)) return error.TransferTargetChanged;
    }

    fn targetNode(self: Context, model: *const GraphModel.Model) !GraphModel.Node {
        const summary = model.graphFor(self.project_path) orelse return error.TransferContextChanged;
        if (!summary.project.isLocalFilesystem()) return error.TransferLocalOnly;
        const nodes = if (self.composite_id.len == 0)
            summary.nodes.items
        else blk: {
            const graph = model.graph orelse return error.TransferContextChanged;
            if (self.origin != .canvas or
                !std.mem.eql(u8, graph.project.path, self.project_path) or
                !sameOptionalUuid(model.open_composite_id orelse "", self.composite_id))
                return error.TransferContextChanged;
            break :blk graph.nodes.items;
        };
        var found: ?GraphModel.Node = null;
        for (nodes) |node| {
            if (!std.ascii.eqlIgnoreCase(node.id, self.node_id)) continue;
            if (found != null) return error.TransferTargetChanged;
            found = node;
        }
        return found orelse error.TransferTargetMissing;
    }
};

pub const Binding = struct {
    operation: Operation,
    invocation: []const u8,
    containing_composite: []const u8,
    zip_path: []const u8,
};

pub const Arguments = struct {
    values: [14][]const u8 = undefined,
    len: usize = 0,
    operation: Operation,

    pub fn init(
        allocator: std.mem.Allocator,
        executable: []const u8,
        context: *const Context,
        operation: Operation,
        invocation: []const u8,
        zip_path: []const u8,
        replacement_approved: bool,
    ) !Arguments {
        if (!Forms.isUuid(invocation) or !Forms.isUuid(context.node_id) or
            (context.composite_id.len != 0 and !Forms.isUuid(context.composite_id)) or
            !validAbsolutePath(executable) or !validAbsolutePath(context.project_path) or
            !validAbsolutePath(zip_path) or (replacement_approved and operation != .export_loop))
            return error.InvalidTransferArguments;
        const values = [_][]const u8{
            executable, "--windows-card-transfer", operation.wireName(),
            "--invocation", invocation, "--project", context.project_path,
            "--node", context.node_id, "--containing-composite", context.containingComposite(),
            if (operation == .export_loop) "--output" else "--input", zip_path,
        };
        var result = Arguments{ .operation = operation };
        errdefer result.deinit(allocator);
        for (values) |value| {
            result.values[result.len] = try allocator.dupe(u8, value);
            result.len += 1;
        }
        if (replacement_approved) {
            result.values[result.len] = try allocator.dupe(u8, "--replace-existing");
            result.len += 1;
        }
        return result;
    }

    pub fn deinit(self: *Arguments, allocator: std.mem.Allocator) void {
        for (self.slice()) |value| allocator.free(value);
        self.len = 0;
    }

    pub fn slice(self: *const Arguments) []const []const u8 {
        return self.values[0..self.len];
    }

    pub fn binding(self: *const Arguments) Binding {
        return .{
            .operation = self.operation,
            .invocation = self.values[4],
            .containing_composite = self.values[10],
            .zip_path = self.values[12],
        };
    }
};

fn validAbsolutePath(path: []const u8) bool {
    return path.len != 0 and std.mem.indexOfScalar(u8, path, 0) == null and
        std.unicode.utf8ValidateSlice(path) and std.fs.path.isAbsoluteWindows(path);
}

pub fn windowsCommandLine(allocator: std.mem.Allocator, arguments: []const []const u8) ![:0]u16 {
    if (arguments.len == 0 or arguments[0].len == 0) return error.InvalidTransferArguments;
    var quoted = std.array_list.Managed(u8).init(allocator);
    defer quoted.deinit();
    for (arguments, 0..) |argument, index| {
        if (std.mem.indexOfScalar(u8, argument, 0) != null or !std.unicode.utf8ValidateSlice(argument))
            return error.InvalidTransferArguments;
        if (index != 0) try quoted.append(' ');
        try quoted.append('"');
        var slashes: usize = 0;
        for (argument) |character| {
            if (character == '\\') {
                slashes += 1;
                continue;
            }
            try quoted.appendNTimes('\\', if (character == '"') slashes * 2 + 1 else slashes);
            try quoted.append(character);
            slashes = 0;
        }
        try quoted.appendNTimes('\\', slashes * 2);
        try quoted.append('"');
    }
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(allocator, quoted.items);
    errdefer allocator.free(wide);
    if (wide.len >= 32767) return error.TransferCommandLineTooLong;
    return wide;
}

pub const stdout_limit = 256 * 1024;
pub const stderr_limit = 64 * 1024;
pub const result_prefix = "GRAPHCODE_CARD_TRANSFER_RESULT ";

pub const Timing = struct {
    pub const operation_ns: u64 = 120 * std.time.ns_per_s;
    pub const stop_ns: u64 = 5 * std.time.ns_per_s;
    pub const Decision = enum { running, cancel_requested, timed_out, clock_invalid };
    pub const StopDecision = enum { waiting, expired, clock_invalid };
    pub const ShutdownDecision = union(enum) { wait: u64, drained, retain_unknown };

    pub fn decide(start: u64, now: u64, cancelled: bool) Decision {
        if (cancelled) return .cancel_requested;
        if (now < start) return .clock_invalid;
        return if (now - start >= operation_ns) .timed_out else .running;
    }

    pub fn stopDecision(start: u64, now: u64) StopDecision {
        if (now < start) return .clock_invalid;
        return if (now - start >= stop_ns) .expired else .waiting;
    }

    pub fn shutdownDecision(start: u64, now: u64, phase: Lifecycle.Phase) ShutdownDecision {
        if (phase == .complete) return .drained;
        if (phase == .blocked or stopDecision(start, now) != .waiting) return .retain_unknown;
        return .{ .wait = @min(20 * std.time.ns_per_ms, stop_ns - (now - start)) };
    }

    pub fn taskDecision(phase: Lifecycle.Phase, stop_started: *?u64, now: u64) struct { phase: Lifecycle.Phase, cancel: bool = false } {
        if (phase == .complete) return .{ .phase = .complete };
        var cancel = false;
        if (stop_started.* == null and decide(0, now, false) != .running) {
            stop_started.* = now;
            cancel = true;
        }
        if (stop_started.*) |start| {
            return .{
                .phase = if (phase == .blocked or stopDecision(start, now) != .waiting) .blocked else .stopping,
                .cancel = cancel,
            };
        }
        return .{ .phase = phase };
    }
};

pub fn resumeOwned(api: anytype) !void {
    try api.assign();
    try api.verify();
    try api.resumeThread();
}

pub fn authorizeDispatch(start: u64, now: u64, cancelled: bool) !void {
    switch (Timing.decide(start, now, cancelled)) {
        .running => {},
        .cancel_requested => return error.TransferCancelledBeforeDispatch,
        .timed_out => return error.TransferTimedOutBeforeDispatch,
        .clock_invalid => return error.TransferClockInvalidBeforeDispatch,
    }
}

pub const Lifecycle = struct {
    pub const Step = enum { wait, terminate_job, complete, blocked };
    pub const Phase = enum(u8) { running, stopping, complete, blocked };
    pub const Failure = enum { cancelled, timed_out, clock_invalid, capture_failed, job_inspection_failed, launch_failed, process_inspection_failed };
    pub const Snapshot = struct {
        root_exited: bool = false,
        job_active: ?u32 = null,
        stdout_eof: bool = false,
        stderr_eof: bool = false,

        fn drained(self: Snapshot) bool {
            return self.root_exited and self.job_active != null and self.job_active.? == 0 and
                self.stdout_eof and self.stderr_eof;
        }
    };

    started_ns: u64,
    stop_started_ns: ?u64 = null,
    phase: Phase = .running,
    failure: ?Failure = null,

    pub fn canPublishSuccess(self: Lifecycle) bool {
        return self.phase == .complete and self.failure == null;
    }

    pub fn fail(self: *Lifecycle, reason: Failure, now: u64) Step {
        if (self.failure == null) self.failure = reason;
        if (self.stop_started_ns == null) {
            self.stop_started_ns = now;
            self.phase = .stopping;
            return .terminate_job;
        }
        return if (self.phase == .blocked) .blocked else .wait;
    }

    pub fn observe(self: *Lifecycle, now: u64, cancelled: bool, snapshot: Snapshot) Step {
        if (self.phase == .complete) return .complete;
        if (self.stop_started_ns == null) {
            const reason: ?Failure = switch (Timing.decide(self.started_ns, now, cancelled)) {
                .running => null,
                .cancel_requested => .cancelled,
                .timed_out => .timed_out,
                .clock_invalid => .clock_invalid,
            };
            if (self.failure == null) self.failure = reason;
            if (self.failure == null and snapshot.job_active == null)
                self.failure = .job_inspection_failed;
        }
        if (snapshot.drained()) {
            self.phase = .complete;
            return .complete;
        }
        if (self.failure) |reason| {
            if (self.stop_started_ns == null) return self.fail(reason, now);
        }
        if (self.stop_started_ns) |start| {
            switch (Timing.stopDecision(start, now)) {
                .waiting => {},
                .expired, .clock_invalid => {
                    self.phase = .blocked;
                    return .blocked;
                },
            }
        }
        return .wait;
    }
};

pub const Output = struct {
    bytes: std.array_list.Managed(u8),
    limit: usize,

    pub fn init(allocator: std.mem.Allocator, limit: usize) Output {
        return .{ .bytes = std.array_list.Managed(u8).init(allocator), .limit = limit };
    }

    pub fn deinit(self: *Output) void {
        self.bytes.deinit();
    }

    pub fn append(self: *Output, bytes: []const u8) !void {
        if (bytes.len > self.limit - self.bytes.items.len) return error.TransferOutputTooLarge;
        try self.bytes.appendSlice(bytes);
    }
};

pub const Result = struct {
    status: Status,
    message: []const u8,
    session_preparation_started: bool,
    output_path: ?[]const u8,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        if (self.output_path) |path| allocator.free(path);
    }
};

pub fn parseResult(allocator: std.mem.Allocator, binding: Binding, stdout: []const u8, exit_code: u32) !Result {
    if (stdout.len > stdout_limit) return error.TransferOutputTooLarge;
    var record: ?[]const u8 = null;
    var position: usize = 0;
    while (position < stdout.len) {
        const end = std.mem.indexOfScalarPos(u8, stdout, position, '\n') orelse stdout.len;
        const line = std.mem.trimEnd(u8, stdout[position..end], "\r");
        if (std.mem.startsWith(u8, line, result_prefix)) {
            if (record != null) return error.TransferResultDuplicate;
            if (end == stdout.len) return error.TransferResultTruncated;
            record = line[result_prefix.len..];
        }
        position = if (end == stdout.len) end else end + 1;
    }
    const json = record orelse return error.TransferResultMissing;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{
        .duplicate_field_behavior = .@"error",
        .max_value_len = stdout_limit,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidTransferResult,
    };
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidTransferResult,
    };
    const version = switch (object.get("version") orelse return error.InvalidTransferResult) {
        .integer => |value| value,
        else => return error.InvalidTransferResult,
    };
    const invocation = try resultString(parsed.value, "invocation");
    const scope = try resultString(parsed.value, "containingComposite");
    if (version != 1 or !Forms.isUuid(invocation) or !Forms.isUuid(binding.invocation) or
        !std.ascii.eqlIgnoreCase(invocation, binding.invocation) or
        !std.mem.eql(u8, try resultString(parsed.value, "operation"), binding.operation.wireName()) or
        !sameComposite(scope, binding.containing_composite))
        return error.TransferBindingMismatch;
    const status = std.meta.stringToEnum(Status, try resultString(parsed.value, "status")) orelse
        return error.InvalidTransferResult;
    if (status.exitCode() != exit_code) return error.TransferExitMismatch;
    const message = try resultString(parsed.value, "message");
    if (message.len == 0 or (std.unicode.utf8CountCodepoints(message) catch return error.InvalidTransferResult) > 2048)
        return error.InvalidTransferResult;
    const preparation = switch (object.get("sessionPreparationStarted") orelse return error.InvalidTransferResult) {
        .bool => |value| value,
        else => return error.InvalidTransferResult,
    };
    const needs_destination = binding.operation == .export_loop and status == .succeeded;
    const destination: ?[]const u8 = if (needs_destination) blk: {
        const path = resultString(parsed.value, "outputPath") catch return error.TransferDestinationMismatch;
        if (path.len == 0 or !std.mem.eql(u8, path, binding.zip_path)) return error.TransferDestinationMismatch;
        break :blk path;
    } else blk: {
        if (object.contains("outputPath")) return error.TransferDestinationMismatch;
        break :blk null;
    };
    if (object.count() != @as(usize, if (needs_destination) 8 else 7)) return error.InvalidTransferResult;
    const owned_message = try allocator.dupe(u8, message);
    errdefer allocator.free(owned_message);
    return .{
        .status = status,
        .message = owned_message,
        .session_preparation_started = preparation,
        .output_path = if (destination) |path| try allocator.dupe(u8, path) else null,
    };
}

pub const Worker = struct {
    const c = @import("Win32.zig").c;

    allocator: std.mem.Allocator,
    arguments: Arguments,
    stdout: Output,
    stderr: Output,
    lifecycle: Lifecycle = .{ .started_ns = 0 },
    timer: ?std.time.Timer = null,
    process: c.HANDLE = null,
    thread: c.HANDLE = null,
    job: c.HANDLE = null,
    output_read: c.HANDLE = null,
    output_write: c.HANDLE = null,
    error_read: c.HANDLE = null,
    error_write: c.HANDLE = null,
    input: c.HANDLE = null,
    process_id: c.DWORD = 0,
    thread_id: c.DWORD = 0,
    creation_time: c.FILETIME = std.mem.zeroes(c.FILETIME),
    started: bool = false,
    assigned: bool = false,
    dispatched: bool = false,
    cancelled: std.atomic.Value(bool) = .init(false),
    stdout_eof: bool = false,
    stderr_eof: bool = false,
    exit_code: ?u32 = null,
    native_error: ?u32 = null,
    stop_error: ?u32 = null,
    capture_error: ?anyerror = null,
    launch_error: ?anyerror = null,

    pub fn init(allocator: std.mem.Allocator, arguments: Arguments) Worker {
        return .{
            .allocator = allocator,
            .arguments = arguments,
            .stdout = Output.init(allocator, stdout_limit),
            .stderr = Output.init(allocator, stderr_limit),
        };
    }

    fn nativeFailure(self: *Worker) error{TransferNativeFailure}!noreturn {
        if (self.native_error == null) self.native_error = c.GetLastError();
        return error.TransferNativeFailure;
    }

    fn close(self: *Worker, handle: *c.HANDLE) !void {
        if (handle.*) |value| {
            if (c.CloseHandle(value) == 0) return try self.nativeFailure();
            handle.* = null;
        }
    }

    fn closeParentPipeEnds(self: *Worker) !void {
        try self.close(&self.output_write);
        try self.close(&self.error_write);
        try self.close(&self.input);
    }

    fn now(self: *Worker) u64 {
        return if (self.timer) |*timer| timer.read() else 0;
    }

    fn terminate(self: *Worker) void {
        if (self.assigned) {
            if (c.TerminateJobObject(self.job, 75) == 0) self.stop_error = c.GetLastError();
        } else if (self.process != null) {
            // Assignment failure never releases the primary thread or any child.
            if (self.dispatched) {
                self.stop_error = c.ERROR_INVALID_STATE;
            } else if (c.TerminateProcess(self.process, 75) == 0) {
                self.stop_error = c.GetLastError();
            }
        }
    }

    fn stopFor(self: *Worker, reason: Lifecycle.Failure) void {
        if (self.lifecycle.fail(reason, self.now()) == .terminate_job) self.terminate();
    }

    fn launchFailed(self: *Worker, err: anyerror) void {
        self.launch_error = err;
        self.closeParentPipeEnds() catch |cleanup_error| {
            if (self.capture_error == null) self.capture_error = cleanup_error;
        };
        self.stopFor(switch (err) {
            error.TransferCancelledBeforeDispatch => .cancelled,
            error.TransferTimedOutBeforeDispatch => .timed_out,
            error.TransferClockInvalidBeforeDispatch => .clock_invalid,
            else => .launch_failed,
        });
    }

    pub fn start(self: *Worker) !void {
        if (self.started) return error.TransferAlreadyStarted;
        self.started = true;
        errdefer |err| self.launchFailed(err);
        if (self.timer == null) self.timer = try std.time.Timer.start();
        const command = try windowsCommandLine(self.allocator, self.arguments.slice());
        defer self.allocator.free(command);
        const executable = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, self.arguments.values[0]);
        defer self.allocator.free(executable);
        const directory = std.fs.path.dirnameWindows(self.arguments.values[0]) orelse
            return error.InvalidTransferArguments;
        const wide_directory = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, directory);
        defer self.allocator.free(wide_directory);

        self.job = c.CreateJobObjectW(null, null);
        if (self.job == null) return try self.nativeFailure();
        if (c.SetHandleInformation(self.job, c.HANDLE_FLAG_INHERIT, 0) == 0) return try self.nativeFailure();
        var limits = std.mem.zeroes(c.JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
        limits.BasicLimitInformation.LimitFlags = c.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if (c.SetInformationJobObject(self.job, c.JobObjectExtendedLimitInformation, &limits, @sizeOf(@TypeOf(limits))) == 0)
            return try self.nativeFailure();

        var security = c.SECURITY_ATTRIBUTES{
            .nLength = @sizeOf(c.SECURITY_ATTRIBUTES),
            .lpSecurityDescriptor = null,
            .bInheritHandle = 1,
        };
        if (c.CreatePipe(&self.output_read, &self.output_write, &security, 0) == 0 or
            c.CreatePipe(&self.error_read, &self.error_write, &security, 0) == 0 or
            c.SetHandleInformation(self.output_read, c.HANDLE_FLAG_INHERIT, 0) == 0 or
            c.SetHandleInformation(self.error_read, c.HANDLE_FLAG_INHERIT, 0) == 0)
            return try self.nativeFailure();
        self.input = c.CreateFileW(std.unicode.utf8ToUtf16LeStringLiteral("NUL"), c.GENERIC_READ, c.FILE_SHARE_READ | c.FILE_SHARE_WRITE, &security, c.OPEN_EXISTING, c.FILE_ATTRIBUTE_NORMAL, null);
        if (self.input == c.INVALID_HANDLE_VALUE) {
            self.input = null;
            return try self.nativeFailure();
        }

        var attribute_size: c.SIZE_T = 0;
        const sizing_result = c.InitializeProcThreadAttributeList(null, 1, 0, &attribute_size);
        const sizing_error = c.GetLastError();
        if (sizing_result != 0 or sizing_error != c.ERROR_INSUFFICIENT_BUFFER or attribute_size == 0)
            return error.TransferAttributeListUnavailable;
        const storage = try self.allocator.alignedAlloc(u8, .@"16", attribute_size);
        defer self.allocator.free(storage);
        const attributes: c.LPPROC_THREAD_ATTRIBUTE_LIST = @ptrCast(storage.ptr);
        if (c.InitializeProcThreadAttributeList(attributes, 1, 0, &attribute_size) == 0) return try self.nativeFailure();
        defer c.DeleteProcThreadAttributeList(attributes);
        var inherited = [_]c.HANDLE{ self.input, self.output_write, self.error_write };
        if (c.UpdateProcThreadAttribute(attributes, 0, 0x20002, @ptrCast(&inherited), @sizeOf(@TypeOf(inherited)), null, null) == 0)
            return try self.nativeFailure();
        var startup = std.mem.zeroes(c.STARTUPINFOEXW);
        startup.StartupInfo.cb = @sizeOf(c.STARTUPINFOEXW);
        startup.StartupInfo.dwFlags = c.STARTF_USESTDHANDLES | c.STARTF_USESHOWWINDOW;
        startup.StartupInfo.wShowWindow = c.SW_HIDE;
        startup.StartupInfo.hStdInput = self.input;
        startup.StartupInfo.hStdOutput = self.output_write;
        startup.StartupInfo.hStdError = self.error_write;
        startup.lpAttributeList = attributes;
        var created = std.mem.zeroes(c.PROCESS_INFORMATION);
        if (c.CreateProcessW(executable.ptr, command.ptr, null, null, 1, c.CREATE_SUSPENDED | c.CREATE_NO_WINDOW | c.EXTENDED_STARTUPINFO_PRESENT, null, wide_directory.ptr, &startup.StartupInfo, &created) == 0)
            return try self.nativeFailure();
        self.process = created.hProcess;
        self.thread = created.hThread;
        self.process_id = created.dwProcessId;
        self.thread_id = created.dwThreadId;
        try self.closeParentPipeEnds();
        var ignored_exit: c.FILETIME = undefined;
        var ignored_kernel: c.FILETIME = undefined;
        var ignored_user: c.FILETIME = undefined;
        if (c.GetProcessTimes(self.process, &self.creation_time, &ignored_exit, &ignored_kernel, &ignored_user) == 0)
            return try self.nativeFailure();
        try authorizeDispatch(0, self.now(), self.cancelled.load(.acquire));
        try resumeOwned(self);
    }

    fn assign(self: *Worker) !void {
        if (c.AssignProcessToJobObject(self.job, self.process) == 0) return try self.nativeFailure();
        self.assigned = true;
    }

    fn verify(self: *Worker) !void {
        var member: c.BOOL = 0;
        if (c.IsProcessInJob(self.process, self.job, &member) == 0) return try self.nativeFailure();
        if (member == 0 or c.GetProcessId(self.process) != self.process_id or
            c.GetThreadId(self.thread) != self.thread_id)
            return error.TransferLaunchIdentityMismatch;
        var created: c.FILETIME = undefined;
        var exited: c.FILETIME = undefined;
        var kernel: c.FILETIME = undefined;
        var user: c.FILETIME = undefined;
        if (c.GetProcessTimes(self.process, &created, &exited, &kernel, &user) == 0)
            return try self.nativeFailure();
        if (created.dwLowDateTime != self.creation_time.dwLowDateTime or
            created.dwHighDateTime != self.creation_time.dwHighDateTime or
            try self.activeProcesses() != 1)
            return error.TransferLaunchIdentityMismatch;
        for ([_]c.HANDLE{ self.job, self.process, self.thread, self.output_read, self.error_read }) |handle| {
            var flags: c.DWORD = 0;
            if (c.GetHandleInformation(handle, &flags) == 0) return try self.nativeFailure();
            if (flags & c.HANDLE_FLAG_INHERIT != 0) return error.TransferLaunchIdentityMismatch;
        }
    }

    fn resumeThread(self: *Worker) !void {
        try authorizeDispatch(0, self.now(), self.cancelled.load(.acquire));
        self.dispatched = true;
        const previous = c.ResumeThread(self.thread);
        if (previous == std.math.maxInt(c.DWORD)) return try self.nativeFailure();
        if (previous != 1) return error.TransferLaunchIdentityMismatch;
    }

    fn activeProcesses(self: *Worker) !u32 {
        if (self.job == null) {
            if (self.process != null) return error.TransferJobAccountingUnavailable;
            return 0;
        }
        var accounting = std.mem.zeroes(c.JOBOBJECT_BASIC_ACCOUNTING_INFORMATION);
        if (c.QueryInformationJobObject(self.job, c.JobObjectBasicAccountingInformation, &accounting, @sizeOf(@TypeOf(accounting)), null) == 0)
            return try self.nativeFailure();
        if (self.assigned and accounting.TotalProcesses == 0) return error.TransferJobAccountingUnavailable;
        return accounting.ActiveProcesses;
    }

    fn rootExited(self: *Worker) !bool {
        if (self.process == null) return true;
        switch (c.WaitForSingleObject(self.process, 0)) {
            c.WAIT_OBJECT_0 => {
                var code: c.DWORD = 0;
                if (c.GetExitCodeProcess(self.process, &code) == 0) return try self.nativeFailure();
                self.exit_code = code;
                return true;
            },
            c.WAIT_TIMEOUT => return false,
            else => return try self.nativeFailure(),
        }
    }

    fn pump(self: *Worker, handle: c.HANDLE, output: *Output, eof: *bool) !void {
        if (eof.*) return;
        if (handle == null) {
            eof.* = true;
            return;
        }
        var budget: usize = 32 * 1024;
        var buffer: [4096]u8 = undefined;
        while (budget != 0) {
            var available: c.DWORD = 0;
            if (c.PeekNamedPipe(handle, null, 0, null, &available, null) == 0) {
                if (c.GetLastError() == c.ERROR_BROKEN_PIPE) {
                    eof.* = true;
                    return;
                }
                return try self.nativeFailure();
            }
            if (available == 0) return;
            const amount = @min(@as(usize, available), @min(budget, buffer.len));
            var read: c.DWORD = 0;
            if (c.ReadFile(handle, &buffer, @intCast(amount), &read, null) == 0) {
                if (c.GetLastError() == c.ERROR_BROKEN_PIPE) {
                    eof.* = true;
                    return;
                }
                return try self.nativeFailure();
            }
            if (read == 0) {
                eof.* = true;
                return;
            }
            budget -= read;
            if (self.capture_error == null) try output.append(buffer[0..read]);
        }
    }

    pub fn cancel(self: *Worker) void {
        self.cancelled.store(true, .release);
    }

    pub fn poll(self: *Worker) Lifecycle.Step {
        self.pump(self.output_read, &self.stdout, &self.stdout_eof) catch |err| {
            if (self.capture_error == null) self.capture_error = err;
            self.stopFor(.capture_failed);
        };
        self.pump(self.error_read, &self.stderr, &self.stderr_eof) catch |err| {
            if (self.capture_error == null) self.capture_error = err;
            self.stopFor(.capture_failed);
        };
        const active: ?u32 = self.activeProcesses() catch blk: {
            self.stopFor(.job_inspection_failed);
            break :blk null;
        };
        const exited = self.rootExited() catch blk: {
            self.stopFor(.process_inspection_failed);
            break :blk false;
        };
        const step = self.lifecycle.observe(self.now(), self.cancelled.load(.acquire), .{
            .root_exited = exited,
            .job_active = active,
            .stdout_eof = self.stdout_eof,
            .stderr_eof = self.stderr_eof,
        });
        if (step == .terminate_job) self.terminate();
        return step;
    }

    pub fn result(self: *Worker) !Result {
        if (self.lifecycle.phase != .complete) return error.TransferStillRunning;
        if (self.lifecycle.failure != null) return error.TransferOutcomeUnconfirmed;
        return parseResult(self.allocator, self.arguments.binding(), self.stdout.bytes.items, self.exit_code orelse
            return error.TransferExitUnavailable);
    }

    pub fn deinit(self: *Worker) !void {
        if (self.lifecycle.phase != .complete) return error.TransferStillRunning;
        try self.closeParentPipeEnds();
        try self.close(&self.output_read);
        try self.close(&self.error_read);
        try self.close(&self.thread);
        try self.close(&self.process);
        try self.close(&self.job);
        self.stdout.deinit();
        self.stderr.deinit();
        self.arguments.deinit(self.allocator);
    }
};

pub const Task = struct {
    pub const allocator = std.heap.page_allocator;

    worker: Worker,
    thread: ?std.Thread = null,
    phase: std.atomic.Value(Lifecycle.Phase) = .init(.running),
    clock: std.time.Timer,
    stop_started_ns: ?u64 = null,
    observed_native_error: std.atomic.Value(u32) = .init(0),

    pub fn create(
        executable: []const u8,
        context: *const Context,
        operation: Operation,
        invocation: []const u8,
        zip_path: []const u8,
        replacement_approved: bool,
    ) !*Task {
        const clock = try std.time.Timer.start();
        var arguments = try Arguments.init(allocator, executable, context, operation, invocation, zip_path, replacement_approved);
        errdefer arguments.deinit(allocator);
        const self = try allocator.create(Task);
        errdefer allocator.destroy(self);
        self.* = .{ .worker = Worker.init(allocator, arguments), .clock = clock };
        self.worker.timer = clock;
        errdefer {
            self.worker.stdout.deinit();
            self.worker.stderr.deinit();
        }
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    fn run(self: *Task) void {
        self.worker.start() catch |err| {
            self.worker.launch_error = err;
        };
        while (true) {
            const step = self.worker.poll();
            if (self.worker.native_error) |code| self.observed_native_error.store(code, .release);
            if (self.worker.stop_error) |code| self.observed_native_error.store(code, .release);
            self.phase.store(self.worker.lifecycle.phase, .release);
            if (step == .complete) return;
            std.Thread.sleep(20 * std.time.ns_per_ms);
        }
    }

    pub fn cancel(self: *Task) void {
        self.worker.cancel();
        if (self.stop_started_ns == null) self.stop_started_ns = self.clock.read();
    }

    pub fn poll(self: *Task) Lifecycle.Phase {
        const phase = self.phase.load(.acquire);
        if (phase == .complete) return .complete;
        const decision = Timing.taskDecision(phase, &self.stop_started_ns, self.clock.read());
        if (decision.cancel) self.worker.cancel();
        return decision.phase;
    }

    fn joinCompleted(self: *Task) !void {
        if (self.phase.load(.acquire) != .complete) return error.TransferStillRunning;
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    pub fn result(self: *Task) !Result {
        try self.joinCompleted();
        if (self.worker.cancelled.load(.acquire)) return error.TransferOutcomeUnconfirmed;
        return self.worker.result();
    }

    pub fn deinit(self: *Task) !void {
        try self.joinCompleted();
        try self.worker.deinit();
        allocator.destroy(self);
    }
};

fn resultString(value: std.json.Value, key: []const u8) ![]const u8 {
    return switch (value.object.get(key) orelse return error.InvalidTransferResult) {
        .string => |text| text,
        else => error.InvalidTransferResult,
    };
}

fn sameComposite(actual: []const u8, expected: []const u8) bool {
    if (std.mem.eql(u8, expected, "root")) return std.mem.eql(u8, actual, "root");
    return Forms.isUuid(actual) and Forms.isUuid(expected) and std.ascii.eqlIgnoreCase(actual, expected);
}

fn sameOptionalUuid(actual: []const u8, expected: []const u8) bool {
    if (actual.len == 0 or expected.len == 0) return actual.len == expected.len;
    return Forms.isUuid(actual) and Forms.isUuid(expected) and std.ascii.eqlIgnoreCase(actual, expected);
}

const test_node = "11111111-1111-4111-8111-111111111111";
const test_group = "22222222-2222-4222-8222-222222222222";
const test_child = "33333333-3333-4333-8333-333333333333";
const test_other = "44444444-4444-4444-8444-444444444444";
const test_invocation = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE";

test "card transfer Windows command line preserves empty Unicode and shell metacharacter arguments" {
    const allocator = std.testing.allocator;
    const line = try windowsCommandLine(allocator, &.{
        "C:\\Graph Code\\bin\\graphcode.exe",
        "",
        "C:\\A & B\\%literal%!^",
        "\"quoted\"",
        "\u{96ea}\u{1f642}",
    });
    defer allocator.free(line);
    const text = try std.unicode.utf16LeToUtf8Alloc(allocator, line);
    defer allocator.free(text);
    try std.testing.expectEqualStrings(
        "\"C:\\Graph Code\\bin\\graphcode.exe\" \"\" \"C:\\A & B\\%literal%!^\" \"\\\"quoted\\\"\" \"\u{96ea}\u{1f642}\"",
        text,
    );
    try std.testing.expectEqual(@as(u16, 0), line[line.len]);
}

test "card transfer Windows command line doubles trailing slashes and escapes quotes" {
    const allocator = std.testing.allocator;
    const line = try windowsCommandLine(allocator, &.{
        "C:\\GraphCode\\bin\\graphcode.exe",
        "C:\\end\\",
        "before\\\"after",
        "\\\\",
    });
    defer allocator.free(line);
    const text = try std.unicode.utf16LeToUtf8Alloc(allocator, line);
    defer allocator.free(text);
    try std.testing.expectEqualStrings(
        \\"C:\GraphCode\bin\graphcode.exe" "C:\end\\" "before\\\"after" "\\\\"
    , text);
}

test "card transfer Windows command line rejects invalid input before native launch" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidTransferArguments, windowsCommandLine(allocator, &.{}));
    try std.testing.expectError(error.InvalidTransferArguments, windowsCommandLine(allocator, &.{""}));
    try std.testing.expectError(error.InvalidTransferArguments, windowsCommandLine(allocator, &.{ "x", "embedded\x00nul" }));
    try std.testing.expectError(error.InvalidTransferArguments, windowsCommandLine(allocator, &.{ "x", "\xff" }));
}

test "card transfer Windows command line measures UTF16 units including the terminator" {
    const allocator = std.testing.allocator;
    const ascii = try allocator.alloc(u8, 32761);
    defer allocator.free(ascii);
    @memset(ascii, 'a');
    const accepted = try windowsCommandLine(allocator, &.{ "x", ascii[0..32760] });
    defer allocator.free(accepted);
    try std.testing.expectEqual(@as(usize, 32766), accepted.len);
    try std.testing.expectError(error.TransferCommandLineTooLong, windowsCommandLine(allocator, &.{ "x", ascii }));

    const emoji = try allocator.alloc(u8, 16381 * 4);
    defer allocator.free(emoji);
    var offset: usize = 0;
    while (offset < emoji.len) : (offset += 4) @memcpy(emoji[offset..][0..4], "\u{1f642}");
    const accepted_emoji = try windowsCommandLine(allocator, &.{ "x", emoji[0 .. 16380 * 4] });
    defer allocator.free(accepted_emoji);
    try std.testing.expectEqual(@as(usize, 32766), accepted_emoji.len);
    try std.testing.expectError(error.TransferCommandLineTooLong, windowsCommandLine(allocator, &.{ "x", emoji }));
}

fn testWindowsCommandLineAllocations(allocator: std.mem.Allocator) !void {
    const line = try windowsCommandLine(allocator, &.{ "C:\\GC\\bin\\graphcode.exe", "", "slash\\\"quote", "\u{96ea}" });
    defer allocator.free(line);
}

test "card transfer Windows command line releases intermediate allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testWindowsCommandLineAllocations, .{});
}

test "card transfer fallback rejects unconfirmed export but preserves import uncertainty" {
    const exported = fallbackVerdict(.export_loop, true);
    try std.testing.expectEqual(Status.failed, exported.status);
    try std.testing.expectEqualStrings("failed", exported.summary);
    try std.testing.expect(std.mem.indexOf(u8, exported.warning, "output") != null);
    try std.testing.expect(std.mem.indexOf(u8, exported.warning, "not retry automatically") != null);
    const imported = fallbackVerdict(.import_loops, true);
    try std.testing.expectEqual(Status.outcome_unknown, imported.status);
    try std.testing.expectEqualStrings("outcome is unknown", imported.summary);
    try std.testing.expect(std.mem.indexOf(u8, imported.warning, "restored session") != null);
    try std.testing.expect(std.mem.indexOf(u8, imported.warning, "not retry automatically") != null);
}

test "card transfer fallback before dispatch is failed for either operation" {
    for ([_]Operation{ .export_loop, .import_loops }) |operation| {
        const verdict = fallbackVerdict(operation, false);
        try std.testing.expectEqual(Status.failed, verdict.status);
        try std.testing.expectEqualStrings("was not dispatched", verdict.summary);
        try std.testing.expectEqualStrings("No CLI dispatch was confirmed.", verdict.warning);
    }
}

test "card transfer valid export outcome unknown is not replaced by fallback verdict" {
    const record = try testRecord(std.testing.allocator, .{ .status = "outcome_unknown", .output = null });
    defer std.testing.allocator.free(record);
    var result = try parseResult(std.testing.allocator, testBinding(), record, 75);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(Status.outcome_unknown, result.status);
    try std.testing.expectEqual(Status.failed, fallbackVerdict(.export_loop, true).status);
}

test "card transfer destructor stop is bounded by the original five second grace" {
    const start: u64 = 10;
    const waiting = Timing.shutdownDecision(start, start, .stopping);
    try std.testing.expectEqual(@as(u64, 20 * std.time.ns_per_ms), waiting.wait);
    const last_tick = Timing.shutdownDecision(start, start + Timing.stop_ns - 1, .stopping);
    try std.testing.expectEqual(@as(u64, 1), last_tick.wait);
    try std.testing.expect(std.meta.activeTag(Timing.shutdownDecision(start, start + Timing.stop_ns, .stopping)) == .retain_unknown);
    try std.testing.expect(std.meta.activeTag(Timing.shutdownDecision(start, start + Timing.stop_ns + 1, .running)) == .retain_unknown);
}

test "card transfer destructor retains self owned state on blocked or reversed clock" {
    try std.testing.expect(std.meta.activeTag(Timing.shutdownDecision(10, 11, .blocked)) == .retain_unknown);
    try std.testing.expect(std.meta.activeTag(Timing.shutdownDecision(10, 9, .stopping)) == .retain_unknown);
}

test "card transfer destructor accepts only authoritative completion as drained" {
    try std.testing.expect(std.meta.activeTag(Timing.shutdownDecision(10, 10 + Timing.stop_ns, .complete)) == .drained);
    try std.testing.expect(std.meta.activeTag(Timing.shutdownDecision(10, 9, .complete)) == .drained);
}

test "card transfer task timeout starts grace at the same observed clock tick" {
    var started: ?u64 = null;
    const before = Timing.taskDecision(.running, &started, Timing.operation_ns - 1);
    try std.testing.expectEqual(Lifecycle.Phase.running, before.phase);
    try std.testing.expect(!before.cancel);
    try std.testing.expect(started == null);
    const at_deadline = Timing.taskDecision(.running, &started, Timing.operation_ns);
    try std.testing.expect(at_deadline.cancel);
    try std.testing.expectEqual(Lifecycle.Phase.stopping, at_deadline.phase);
    try std.testing.expectEqual(Timing.operation_ns, started.?);
    const before_grace = Timing.taskDecision(.stopping, &started, Timing.operation_ns + Timing.stop_ns - 1);
    try std.testing.expectEqual(Lifecycle.Phase.stopping, before_grace.phase);
    try std.testing.expect(!before_grace.cancel);
    try std.testing.expectEqual(Lifecycle.Phase.blocked, Timing.taskDecision(.stopping, &started, Timing.operation_ns + Timing.stop_ns).phase);
}

test "card transfer task cancellation preserves its first stop deadline" {
    var started: ?u64 = 10;
    const waiting = Timing.taskDecision(.running, &started, 11);
    try std.testing.expectEqual(Lifecycle.Phase.stopping, waiting.phase);
    try std.testing.expect(!waiting.cancel);
    try std.testing.expectEqual(@as(u64, 10), started.?);
    try std.testing.expectEqual(Lifecycle.Phase.blocked, Timing.taskDecision(.stopping, &started, 9).phase);
    try std.testing.expectEqual(Lifecycle.Phase.blocked, Timing.taskDecision(.blocked, &started, 12).phase);
}

test "card transfer task authoritative completion does not introduce timeout cancellation" {
    var started: ?u64 = null;
    const complete = Timing.taskDecision(.complete, &started, Timing.operation_ns + Timing.stop_ns);
    try std.testing.expectEqual(Lifecycle.Phase.complete, complete.phase);
    try std.testing.expect(!complete.cancel);
    try std.testing.expect(started == null);
}

test "card transfer dispatch refuses cancelled or budget expired setup before resume" {
    try authorizeDispatch(0, Timing.operation_ns - 1, false);
    try std.testing.expectError(error.TransferTimedOutBeforeDispatch, authorizeDispatch(0, Timing.operation_ns, false));
    try std.testing.expectError(error.TransferTimedOutBeforeDispatch, authorizeDispatch(0, Timing.operation_ns + 1, false));
    try std.testing.expectError(error.TransferCancelledBeforeDispatch, authorizeDispatch(0, 0, true));
}

test "card transfer dispatch rejects clock reversal and prioritizes cancellation" {
    try std.testing.expectError(error.TransferClockInvalidBeforeDispatch, authorizeDispatch(2, 1, false));
    try std.testing.expectError(error.TransferCancelledBeforeDispatch, authorizeDispatch(2, 1, true));
    try std.testing.expectError(error.TransferCancelledBeforeDispatch, authorizeDispatch(0, Timing.operation_ns, true));
}

fn transferTestModel() !GraphModel.Model {
    var model = GraphModel.Model.init(std.testing.allocator);
    errdefer model.deinit();
    _ = try model.updateFromFrame(
        \\{"graphChanged":{"project":{"path":"C:\\A","name":"A"},"nodes":[{"id":"11111111-1111-4111-8111-111111111111","title":"Root","loopType":"goalBased","state":"succeeded"},{"id":"22222222-2222-4222-8222-222222222222","title":"Group","loopType":"composite","subGraph":{"project":{"path":"C:\\A","name":"A"},"nodes":[{"id":"33333333-3333-4333-8333-333333333333","title":"Child","loopType":"main","state":"stopped"}],"edges":[]}}],"edges":[]}}
    );
    _ = try model.updateFromFrame(
        \\{"graphChanged":{"project":{"path":"C:\\B","name":"B"},"nodes":[{"id":"44444444-4444-4444-8444-444444444444","title":"Other","loopType":"main"}],"edges":[]}}
    );
    if (!model.selectProject("C:\\A") or !model.setSelectedID(test_node)) return error.TestTargetMissing;
    return model;
}

test "card transfer context owns root target without selecting it" {
    var model = try transferTestModel();
    defer model.deinit();
    try std.testing.expectEqualStrings("succeeded", model.selected().?.state);
    var context = try Context.capture(std.testing.allocator, &model, .canvas, "C:\\A", "", test_group);
    defer context.deinit(std.testing.allocator);
    try context.validate(&model, "");
    try std.testing.expectEqualStrings(test_node, model.selectedNodeID().?);
    try std.testing.expectEqualStrings(test_group, context.node_id);
    try std.testing.expectEqualStrings("root", context.containingComposite());
    try std.testing.expectEqualStrings("Group", context.title);
    try std.testing.expect(model.lifecycle_callback == null);
    try std.testing.expect(model.applyLifecycle(.close, "C:\\A"));
    try std.testing.expect(model.graphFor("C:\\A") == null);
    try std.testing.expectEqualStrings("C:\\A", context.project_path);
    try std.testing.expectEqualStrings("Group", context.title);
    try std.testing.expectError(error.TransferContextChanged, context.validate(&model, ""));
}

test "card transfer context captures nested containing graph and stopped target" {
    var model = try transferTestModel();
    defer model.deinit();
    try std.testing.expect(model.openComposite(test_group));
    try std.testing.expect(model.setSelectedID(test_child));
    try std.testing.expectEqualStrings("stopped", model.selected().?.state);
    var context = try Context.capture(std.testing.allocator, &model, .canvas, "C:\\A", test_group, test_child);
    defer context.deinit(std.testing.allocator);
    try context.validate(&model, test_group);
    try std.testing.expectEqualStrings(test_group, context.containingComposite());
    try std.testing.expectError(error.TransferContextChanged, context.validate(&model, ""));
}

test "card transfer context sidebar other project stays root while canvas is drilled in" {
    var model = try transferTestModel();
    defer model.deinit();
    try std.testing.expect(model.openComposite(test_group));
    try std.testing.expect(model.setSelectedID(test_child));
    var context = try Context.capture(std.testing.allocator, &model, .sidebar, "C:\\B", "", test_other);
    defer context.deinit(std.testing.allocator);
    try context.validate(&model, test_group);
    try std.testing.expectEqualStrings("root", context.containingComposite());
    try std.testing.expectEqualStrings("C:\\A", model.graph.?.project.path);
    try std.testing.expectEqualStrings(test_group, model.open_composite_id.?);
    try std.testing.expectEqualStrings(test_child, model.selectedNodeID().?);
    try std.testing.expectError(error.TransferContextChanged, Context.capture(std.testing.allocator, &model, .sidebar, "C:\\A", test_group, test_child));
}

test "card transfer context rejects selection project and composite drift" {
    var model = try transferTestModel();
    defer model.deinit();
    var context = try Context.capture(std.testing.allocator, &model, .canvas, "C:\\A", "", test_node);
    defer context.deinit(std.testing.allocator);
    try std.testing.expect(model.setSelectedID(test_group));
    try std.testing.expectError(error.TransferContextChanged, context.validate(&model, ""));
    try std.testing.expect(model.setSelectedID(test_node));
    try std.testing.expect(model.selectProject("C:\\B"));
    try std.testing.expectError(error.TransferContextChanged, context.validate(&model, ""));
    try std.testing.expect(model.selectProject("C:\\A"));
    try std.testing.expect(model.openComposite(test_group));
    try std.testing.expectError(error.TransferContextChanged, context.validate(&model, test_group));
}

test "card transfer context compares containing and selected UUID identities case insensitively" {
    const allocator = std.testing.allocator;
    var model = GraphModel.Model.init(allocator);
    defer model.deinit();
    _ = try model.updateFromFrame(
        \\{"graphChanged":{"project":{"path":"C:\\A","name":"A"},"nodes":[{"id":"BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB","loopType":"composite","subGraph":{"project":{"path":"C:\\A","name":"A"},"nodes":[{"id":"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA","loopType":"main"}],"edges":[]}}],"edges":[]}}
    );
    try std.testing.expect(model.selectProject("C:\\A"));
    try std.testing.expect(model.openComposite("BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"));
    try std.testing.expect(model.setSelectedID("AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"));
    var context = try Context.capture(allocator, &model, .canvas, "C:\\A", "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa");
    defer context.deinit(allocator);
    const lower_selection = try std.ascii.allocLowerString(allocator, context.origin_node_id);
    allocator.free(context.origin_node_id);
    context.origin_node_id = lower_selection;
    try context.validate(&model, "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb");
    try std.testing.expectError(error.TransferContextChanged, context.validate(&model, "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"));
    try std.testing.expectError(error.TransferContextChanged, context.validate(&model, "not-a-uuid"));
}

test "card transfer context rejects moved missing and changed target" {
    var model = try transferTestModel();
    defer model.deinit();
    var context = try Context.capture(std.testing.allocator, &model, .sidebar, "C:\\B", "", test_other);
    defer context.deinit(std.testing.allocator);
    _ = try model.updateFromFrame(
        \\{"graphChanged":{"project":{"path":"C:\\B","name":"B"},"nodes":[{"id":"44444444-4444-4444-8444-444444444444","loopType":"composite"}],"edges":[]}}
    );
    try std.testing.expectError(error.TransferTargetChanged, context.validate(&model, ""));
    _ = try model.updateFromFrame(
        \\{"graphChanged":{"project":{"path":"C:\\B","name":"B"},"nodes":[{"id":"55555555-5555-4555-8555-555555555555","loopType":"composite","subGraph":{"project":{"path":"C:\\B","name":"B"},"nodes":[{"id":"44444444-4444-4444-8444-444444444444","loopType":"main"}],"edges":[]}}],"edges":[]}}
    );
    try std.testing.expectError(error.TransferTargetMissing, context.validate(&model, ""));
    _ = try model.updateFromFrame(
        \\{"graphChanged":{"project":{"path":"C:\\B","name":"B"},"nodes":[],"edges":[]}}
    );
    try std.testing.expectError(error.TransferTargetMissing, context.validate(&model, ""));
}

test "card transfer context rejects remote global and mismatched canvas scope" {
    var model = try transferTestModel();
    defer model.deinit();
    for ([_][]const u8{ "ssh://host/project", "codespace://box/project", "graphcode://global" }) |path| {
        const frame = try std.fmt.allocPrint(std.testing.allocator,
            \\{{"graphChanged":{{"project":{{"path":"{s}","name":"Remote"}},"nodes":[{{"id":"44444444-4444-4444-8444-444444444444","loopType":"main"}}],"edges":[]}}}}
        , .{path});
        defer std.testing.allocator.free(frame);
        _ = try model.updateFromFrame(frame);
        try std.testing.expectError(error.TransferLocalOnly, Context.capture(std.testing.allocator, &model, .sidebar, path, "", test_other));
    }
    try std.testing.expectError(error.TransferContextChanged, Context.capture(std.testing.allocator, &model, .canvas, "C:\\B", "", test_other));
}

fn contextAllocationExercise(allocator: std.mem.Allocator, model: *const GraphModel.Model) !void {
    var context = try Context.capture(allocator, model, .sidebar, "C:\\B", "", test_other);
    defer context.deinit(allocator);
}

test "card transfer context releases partial owned snapshots" {
    var model = try transferTestModel();
    defer model.deinit();
    try std.testing.checkAllAllocationFailures(std.testing.allocator, contextAllocationExercise, .{&model});
}

fn testContext() Context {
    return .{ .project_path = "C:\\A", .node_id = test_node, .title = "Root", .loop_type = "goalBased" };
}

test "card transfer argv owns exact arguments with no shell interpolation" {
    var context = testContext();
    var arguments = try Arguments.init(std.testing.allocator, "C:\\Program Files\\GraphCode\\graphcode.exe", &context, .export_loop, test_invocation, "C:\\a b\\\u{96ea} & result.zip", false);
    defer arguments.deinit(std.testing.allocator);
    const expected = [_][]const u8{
        "C:\\Program Files\\GraphCode\\graphcode.exe", "--windows-card-transfer", "export",
        "--invocation", test_invocation, "--project", "C:\\A", "--node", test_node,
        "--containing-composite", "root", "--output", "C:\\a b\\\u{96ea} & result.zip",
    };
    try std.testing.expectEqual(@as(usize, expected.len), arguments.slice().len);
    for (expected, arguments.slice()) |wanted, actual| try std.testing.expectEqualStrings(wanted, actual);
    context.project_path = "C:\\changed";
    try std.testing.expectEqualStrings("C:\\A", arguments.slice()[6]);
}

test "card transfer argv preserves nested scope and explicit replacement consent" {
    var context = testContext();
    context.composite_id = test_group;
    var imported = try Arguments.init(std.testing.allocator, "C:\\graphcode.exe", &context, .import_loops, test_invocation, "C:\\input.zip", false);
    defer imported.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("import", imported.slice()[2]);
    try std.testing.expectEqualStrings(test_group, imported.slice()[10]);
    try std.testing.expectEqualStrings("--input", imported.slice()[11]);
    try std.testing.expectError(error.InvalidTransferArguments, Arguments.init(std.testing.allocator, "C:\\graphcode.exe", &context, .import_loops, test_invocation, "C:\\input.zip", true));
    var exported = try Arguments.init(std.testing.allocator, "C:\\graphcode.exe", &context, .export_loop, test_invocation, "C:\\result.zip", true);
    defer exported.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 14), exported.slice().len);
    try std.testing.expectEqualStrings("--replace-existing", exported.slice()[13]);
}

test "card transfer argv rejects invalid identities paths and embedded NUL" {
    var context = testContext();
    for ([_][]const u8{ "", "not-a-uuid" }) |invocation|
        try std.testing.expectError(error.InvalidTransferArguments, Arguments.init(std.testing.allocator, "C:\\graphcode.exe", &context, .export_loop, invocation, "C:\\result.zip", false));
    for ([_][]const u8{ "", "relative.zip", "C:\\bad\x00.zip" }) |path|
        try std.testing.expectError(error.InvalidTransferArguments, Arguments.init(std.testing.allocator, "C:\\graphcode.exe", &context, .export_loop, test_invocation, path, false));
    context.node_id = "bad";
    try std.testing.expectError(error.InvalidTransferArguments, Arguments.init(std.testing.allocator, "C:\\graphcode.exe", &context, .export_loop, test_invocation, "C:\\result.zip", false));
}

const TestRecord = struct {
    version: u8 = 1,
    operation: []const u8 = "export",
    invocation: []const u8 = test_invocation,
    scope: []const u8 = "root",
    status: []const u8 = "succeeded",
    message: []const u8 = "Done",
    preparation: bool = false,
    output: ?[]const u8 = "C:\\result.zip",
};

fn testRecord(allocator: std.mem.Allocator, value: TestRecord) ![]u8 {
    const common = .{
        .version = value.version, .operation = value.operation, .invocation = value.invocation,
        .containingComposite = value.scope, .status = value.status, .message = value.message,
        .sessionPreparationStarted = value.preparation,
    };
    const json = if (value.output) |path|
        try std.json.Stringify.valueAlloc(allocator, .{
            .version = common.version, .operation = common.operation, .invocation = common.invocation,
            .containingComposite = common.containingComposite, .status = common.status, .message = common.message,
            .sessionPreparationStarted = common.sessionPreparationStarted, .outputPath = path,
        }, .{})
    else
        try std.json.Stringify.valueAlloc(allocator, common, .{});
    defer allocator.free(json);
    return std.fmt.allocPrint(allocator, "GRAPHCODE_CARD_TRANSFER_RESULT {s}\n", .{json});
}

fn testBinding() Binding {
    return .{ .operation = .export_loop, .invocation = test_invocation, .containing_composite = "root", .zip_path = "C:\\result.zip" };
}

test "card transfer result accepts only bound export and import success" {
    const allocator = std.testing.allocator;
    const exported = try testRecord(allocator, .{ .invocation = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee" });
    defer allocator.free(exported);
    var result = try parseResult(allocator, testBinding(), exported, 0);
    defer result.deinit(allocator);
    try std.testing.expectEqual(Status.succeeded, result.status);
    try std.testing.expectEqualStrings("C:\\result.zip", result.output_path.?);
    var binding = testBinding();
    binding.operation = .import_loops;
    const imported = try testRecord(allocator, .{ .operation = "import", .output = null });
    defer allocator.free(imported);
    var import_result = try parseResult(allocator, binding, imported, 0);
    defer import_result.deinit(allocator);
    try std.testing.expect(!import_result.session_preparation_started);
    try std.testing.expect(import_result.output_path == null);
}

test "card transfer result preserves failure statuses exit codes and preparation warning" {
    const allocator = std.testing.allocator;
    for ([_]Status{ .rejected, .oversized, .unavailable, .failed, .outcome_unknown }, [_]u32{ 1, 1, 69, 1, 75 }) |status, exit_code| {
        const record = try testRecord(allocator, .{ .status = @tagName(status), .preparation = true, .output = null });
        defer allocator.free(record);
        var result = try parseResult(allocator, testBinding(), record, exit_code);
        defer result.deinit(allocator);
        try std.testing.expectEqual(status, result.status);
        try std.testing.expect(result.session_preparation_started);
        try std.testing.expectError(error.TransferExitMismatch, parseResult(allocator, testBinding(), record, 0));
    }
}

test "card transfer result rejects wrong version invocation operation and containing graph" {
    const allocator = std.testing.allocator;
    for ([_]TestRecord{
        .{ .version = 2 }, .{ .invocation = test_node }, .{ .operation = "import" }, .{ .scope = test_group },
    }) |value| {
        const record = try testRecord(allocator, value);
        defer allocator.free(record);
        try std.testing.expectError(error.TransferBindingMismatch, parseResult(allocator, testBinding(), record, 0));
    }
}

test "card transfer result rejects missing duplicate truncated and malformed records" {
    const allocator = std.testing.allocator;
    const record = try testRecord(allocator, .{});
    defer allocator.free(record);
    const duplicate = try std.mem.concat(allocator, u8, &.{ record, record });
    defer allocator.free(duplicate);
    try std.testing.expectError(error.TransferResultMissing, parseResult(allocator, testBinding(), "ordinary diagnostic\n", 0));
    try std.testing.expectError(error.TransferResultDuplicate, parseResult(allocator, testBinding(), duplicate, 0));
    try std.testing.expectError(error.TransferResultTruncated, parseResult(allocator, testBinding(), record[0 .. record.len - 1], 0));
    try std.testing.expectError(error.InvalidTransferResult, parseResult(allocator, testBinding(), "GRAPHCODE_CARD_TRANSFER_RESULT {\"version\":1,\"version\":1}\n", 0));
    try std.testing.expectError(error.InvalidTransferResult, parseResult(allocator, testBinding(), "GRAPHCODE_CARD_TRANSFER_RESULT {}\n", 0));
}

test "card transfer result rejects missing wrong and forbidden destination echoes" {
    const allocator = std.testing.allocator;
    for ([_]TestRecord{
        .{ .output = null }, .{ .output = "" }, .{ .output = "C:\\OTHER.zip" },
        .{ .status = "failed" },
    }, [_]u32{ 0, 0, 0, 1 }) |value, exit_code| {
        const record = try testRecord(allocator, value);
        defer allocator.free(record);
        try std.testing.expectError(error.TransferDestinationMismatch, parseResult(allocator, testBinding(), record, exit_code));
    }
}

test "card transfer result enforces nonempty bounded messages and total stdout cap" {
    const allocator = std.testing.allocator;
    const empty = try testRecord(allocator, .{ .message = "" });
    defer allocator.free(empty);
    try std.testing.expectError(error.InvalidTransferResult, parseResult(allocator, testBinding(), empty, 0));
    const long = try allocator.alloc(u8, 2049);
    defer allocator.free(long);
    @memset(long, 'x');
    const record = try testRecord(allocator, .{ .message = long });
    defer allocator.free(record);
    try std.testing.expectError(error.InvalidTransferResult, parseResult(allocator, testBinding(), record, 0));
    const oversized = try allocator.alloc(u8, 256 * 1024 + 1);
    defer allocator.free(oversized);
    @memset(oversized, 'x');
    try std.testing.expectError(error.TransferOutputTooLarge, parseResult(allocator, testBinding(), oversized, 0));
}

test "card transfer output enforces independent stdout and stderr byte limits" {
    const allocator = std.testing.allocator;
    for ([_]usize{ 256 * 1024, 64 * 1024 }) |limit| {
        var output = Output.init(allocator, limit);
        defer output.deinit();
        const bytes = try allocator.alloc(u8, limit);
        defer allocator.free(bytes);
        @memset(bytes, 'x');
        try output.append(bytes);
        try std.testing.expectEqual(limit, output.bytes.items.len);
        try std.testing.expectError(error.TransferOutputTooLarge, output.append("x"));
        try std.testing.expectEqual(limit, output.bytes.items.len);
    }
}

test "card transfer budget expires exactly at the accepted wall threshold" {
    const start: u64 = 10 * std.time.ns_per_s;
    try std.testing.expectEqual(Timing.Decision.running, Timing.decide(start, start + Timing.operation_ns - 1, false));
    try std.testing.expectEqual(Timing.Decision.timed_out, Timing.decide(start, start + Timing.operation_ns, false));
    try std.testing.expectEqual(Timing.Decision.timed_out, Timing.decide(start, std.math.maxInt(u64), false));
}

test "card transfer budget cancellation never waits for deadline and rejects clock reversal" {
    try std.testing.expectEqual(Timing.Decision.cancel_requested, Timing.decide(10, 10, true));
    try std.testing.expectEqual(Timing.Decision.cancel_requested, Timing.decide(0, Timing.operation_ns, true));
    try std.testing.expectEqual(Timing.Decision.clock_invalid, Timing.decide(10, 9, false));
}

test "card transfer stop grace is bounded without claiming process termination" {
    const start: u64 = 20 * std.time.ns_per_s;
    try std.testing.expectEqual(Timing.StopDecision.waiting, Timing.stopDecision(start, start + Timing.stop_ns - 1));
    try std.testing.expectEqual(Timing.StopDecision.expired, Timing.stopDecision(start, start + Timing.stop_ns));
    try std.testing.expectEqual(Timing.StopDecision.clock_invalid, Timing.stopDecision(start, start - 1));
}

test "card transfer result requires preparation boolean and integer version" {
    const allocator = std.testing.allocator;
    const record = try testRecord(allocator, .{});
    defer allocator.free(record);
    for ([_][]const u8{
        "\"sessionPreparationStarted\":false,", "\"sessionPreparationStarted\":false", "\"version\":1",
    }, [_][]const u8{ "", "\"sessionPreparationStarted\":0", "\"version\":1.0" }) |needle, replacement| {
        try std.testing.expect(std.mem.indexOf(u8, record, needle) != null);
        const changed = try std.mem.replaceOwned(u8, allocator, record, needle, replacement);
        defer allocator.free(changed);
        try std.testing.expectError(error.InvalidTransferResult, parseResult(allocator, testBinding(), changed, 0));
    }
}

test "card transfer result message limit counts Unicode scalars not grapheme clusters" {
    const allocator = std.testing.allocator;
    var message: [1024 * 3]u8 = undefined;
    for (0..1024) |index| @memcpy(message[index * 3 ..][0..3], "a\u{301}");
    const record = try testRecord(allocator, .{ .message = &message });
    defer allocator.free(record);
    var result = try parseResult(allocator, testBinding(), record, 0);
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings(&message, result.message);
    const longer = try std.mem.concat(allocator, u8, &.{ &message, "a" });
    defer allocator.free(longer);
    const oversized = try testRecord(allocator, .{ .message = longer });
    defer allocator.free(oversized);
    try std.testing.expectError(error.InvalidTransferResult, parseResult(allocator, testBinding(), oversized, 0));
}

fn transferAllocationExercise(allocator: std.mem.Allocator, record: []const u8) !void {
    const context = testContext();
    var arguments = try Arguments.init(allocator, "C:\\graphcode.exe", &context, .export_loop, test_invocation, "C:\\result.zip", false);
    defer arguments.deinit(allocator);
    var result = try parseResult(allocator, arguments.binding(), record, 0);
    defer result.deinit(allocator);
}

test "card transfer arguments and result release all partial allocations" {
    const record = try testRecord(std.testing.allocator, .{});
    defer std.testing.allocator.free(record);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, transferAllocationExercise, .{record});
}

const LaunchProbe = struct {
    reject_assignment: bool = false,
    reject_identity: bool = false,
    calls: [3]enum { assign, verify, resume_thread } = undefined,
    count: usize = 0,

    fn assign(self: *LaunchProbe) !void {
        self.calls[self.count] = .assign;
        self.count += 1;
        if (self.reject_assignment) return error.TransferJobAssignmentFailed;
    }

    fn verify(self: *LaunchProbe) !void {
        self.calls[self.count] = .verify;
        self.count += 1;
        if (self.reject_identity) return error.TransferJobIdentityFailed;
    }

    fn resumeThread(self: *LaunchProbe) !void {
        self.calls[self.count] = .resume_thread;
        self.count += 1;
    }
};

test "card transfer launch assigns and verifies owned job before resuming" {
    var probe = LaunchProbe{};
    try resumeOwned(&probe);
    try std.testing.expectEqual(@as(usize, 3), probe.count);
    try std.testing.expect(probe.calls[0] == .assign);
    try std.testing.expect(probe.calls[1] == .verify);
    try std.testing.expect(probe.calls[2] == .resume_thread);
}

test "card transfer launch assignment and identity failure never resumes" {
    var assignment = LaunchProbe{ .reject_assignment = true };
    try std.testing.expectError(error.TransferJobAssignmentFailed, resumeOwned(&assignment));
    try std.testing.expectEqual(@as(usize, 1), assignment.count);
    var identity = LaunchProbe{ .reject_identity = true };
    try std.testing.expectError(error.TransferJobIdentityFailed, resumeOwned(&identity));
    try std.testing.expectEqual(@as(usize, 2), identity.count);
}

test "card transfer lifecycle root exit alone never proves descendants or pipes drained" {
    var lifecycle = Lifecycle{ .started_ns = 0 };
    try std.testing.expectEqual(Lifecycle.Step.wait, lifecycle.observe(1, false, .{ .root_exited = true, .job_active = 1 }));
    try std.testing.expectEqual(Lifecycle.Step.wait, lifecycle.observe(2, false, .{ .root_exited = true, .job_active = 0, .stdout_eof = true }));
    try std.testing.expectEqual(Lifecycle.Step.complete, lifecycle.observe(3, false, .{
        .root_exited = true, .job_active = 0, .stdout_eof = true, .stderr_eof = true,
    }));
    try std.testing.expect(lifecycle.canPublishSuccess());
}

test "card transfer lifecycle missing job observation is unknown not empty" {
    var lifecycle = Lifecycle{ .started_ns = 0 };
    try std.testing.expectEqual(Lifecycle.Step.terminate_job, lifecycle.observe(1, false, .{ .root_exited = true }));
    try std.testing.expectEqual(Lifecycle.Failure.job_inspection_failed, lifecycle.failure.?);
    try std.testing.expectEqual(Lifecycle.Step.blocked, lifecycle.observe(1 + Timing.stop_ns, false, .{ .root_exited = true }));
    try std.testing.expect(!lifecycle.canPublishSuccess());
}

test "card transfer lifecycle cancellation retains ambiguity until authoritative drainage" {
    var lifecycle = Lifecycle{ .started_ns = 0 };
    try std.testing.expectEqual(Lifecycle.Step.terminate_job, lifecycle.observe(1, true, .{ .job_active = 2 }));
    try std.testing.expectEqual(Lifecycle.Step.wait, lifecycle.observe(2, true, .{ .job_active = 1 }));
    try std.testing.expectEqual(Lifecycle.Step.blocked, lifecycle.observe(1 + Timing.stop_ns, true, .{ .job_active = 1 }));
    try std.testing.expectEqual(Lifecycle.Step.complete, lifecycle.observe(2 + Timing.stop_ns, false, .{
        .root_exited = true, .job_active = 0, .stdout_eof = true, .stderr_eof = true,
    }));
    try std.testing.expectEqual(Lifecycle.Failure.cancelled, lifecycle.failure.?);
    try std.testing.expect(!lifecycle.canPublishSuccess());
}

test "card transfer lifecycle deadline and stop grace use fake clock exact boundaries" {
    var lifecycle = Lifecycle{ .started_ns = 0 };
    try std.testing.expectEqual(Lifecycle.Step.wait, lifecycle.observe(Timing.operation_ns - 1, false, .{ .job_active = 1 }));
    try std.testing.expectEqual(Lifecycle.Step.terminate_job, lifecycle.observe(Timing.operation_ns, false, .{ .job_active = 1 }));
    try std.testing.expectEqual(Lifecycle.Step.wait, lifecycle.observe(Timing.operation_ns + Timing.stop_ns - 1, false, .{ .job_active = 1 }));
    try std.testing.expectEqual(Lifecycle.Step.blocked, lifecycle.observe(Timing.operation_ns + Timing.stop_ns, false, .{ .job_active = 1 }));
    try std.testing.expectEqual(Lifecycle.Failure.timed_out, lifecycle.failure.?);
}

test "card transfer lifecycle capture failure cannot become a successful result" {
    var lifecycle = Lifecycle{ .started_ns = 0 };
    try std.testing.expectEqual(Lifecycle.Step.terminate_job, lifecycle.fail(.capture_failed, 1));
    try std.testing.expectEqual(Lifecycle.Step.complete, lifecycle.observe(2, false, .{
        .root_exited = true, .job_active = 0, .stdout_eof = true, .stderr_eof = true,
    }));
    try std.testing.expect(!lifecycle.canPublishSuccess());
}
