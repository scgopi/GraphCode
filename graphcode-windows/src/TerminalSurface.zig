const std = @import("std");
const c = @import("Win32.zig").c;

const columns: usize = 120;
const rows: usize = 40;
const cell_count: usize = columns * rows;

const ParserState = enum { normal, escape, csi, osc };
const input_queue_capacity: usize = 64;
const input_queue_max_bytes: usize = 1024 * 1024;
const input_write_timeout_ms: c.DWORD = 50;

pub const InputQueue = struct {
    pub const max_bytes = input_queue_max_bytes;

    pub const Item = struct {
        surface: usize,
        bytes: []u8,
    };

    allocator: std.mem.Allocator,
    items: [input_queue_capacity]Item = undefined,
    head: usize = 0,
    count: usize = 0,
    bytes: usize = 0,

    pub fn enqueue(self: *InputQueue, surface: usize, bytes: []u8) !void {
        if (bytes.len > input_queue_max_bytes) return error.InputTooLarge;
        if (self.count == input_queue_capacity or self.bytes + bytes.len > input_queue_max_bytes) {
            return error.InputQueueFull;
        }
        const index = (self.head + self.count) % input_queue_capacity;
        self.items[index] = .{ .surface = surface, .bytes = bytes };
        self.count += 1;
        self.bytes += bytes.len;
    }

    pub fn dequeue(self: *InputQueue) ?Item {
        if (self.count == 0) return null;
        const item = self.items[self.head];
        self.head = (self.head + 1) % input_queue_capacity;
        self.count -= 1;
        self.bytes -= item.bytes.len;
        return item;
    }

    pub fn clear(self: *InputQueue) void {
        while (self.dequeue()) |item| self.allocator.free(item.bytes);
    }

    pub fn removeSurface(self: *InputQueue, surface: usize) void {
        var kept: [input_queue_capacity]Item = undefined;
        var kept_count: usize = 0;
        while (self.dequeue()) |item| {
            if (item.surface == surface) {
                self.allocator.free(item.bytes);
            } else {
                kept[kept_count] = item;
                kept_count += 1;
            }
        }
        for (kept[0..kept_count]) |item| {
            self.items[self.count] = item;
            self.count += 1;
            self.bytes += item.bytes.len;
        }
        self.head = 0;
    }
};

pub const Surface = struct {
    surface: ?*c.winghostty_surface = null,
    attach: ?std.process.Child = null,
    session_name: []u8 = &.{},
    destroying: bool = false,
    destroyed: bool = false,
    input_bytes: usize = 0,
    output_events: usize = 0,
    terminal_buffer: [16 * 1024]u8 = undefined,
    terminal_buffer_len: usize = 0,
    cells: [cell_count]c.winghostty_terminal_cell = [_]c.winghostty_terminal_cell{
        .{ .codepoint = 0, .foreground = 0xE6E6E6, .background = 0, .flags = 0 },
    } ** cell_count,
    terminal_x: usize = 0,
    terminal_y: usize = 0,
    parser: ParserState = .normal,
    csi_value: usize = 0,
    csi_have_value: bool = false,
};

pub const Workspace = struct {
    parent: c.HWND,
    host: ?*c.winghostty_host = null,
    surfaces: [2]Surface = .{ .{}, .{} },
    active_surface: usize = 0,
    allocator: std.mem.Allocator,
    zmx_path: []u8,
    cwd: []u8,
    recreate_sessions: [2][]u8 = .{ &.{}, &.{} },
    recreate_due_ms: [2]i64 = .{ 0, 0 },
    recreate_delay_ms: [2]i64 = .{ 100, 100 },
    fatal_error: bool = false,
    render_error: c.winghostty_result = c.WINGHOSTTY_OK,
    input_mutex: std.Thread.Mutex = .{},
    input_condition: std.Thread.Condition = .{},
    input_worker: ?std.Thread = null,
    input_stop: bool = false,
    input_busy: bool = false,
    input_worker_surface: ?usize = null,
    input_worker_handle: c.HANDLE = null,
    input_cancel_requested: bool = false,
    input_queue: InputQueue,
    input_error_message: []const u8 = "",
    layout_origin_x: i32 = 0,
    layout_origin_y: i32 = 0,
    layout_width: i32 = 960,
    layout_height: i32 = 250,

    pub fn init(parent: c.HWND, allocator_: std.mem.Allocator) !Workspace {
        var workspace = Workspace{
            .parent = parent,
            .allocator = allocator_,
            .zmx_path = try allocator_.dupe(u8, std.process.getEnvVarOwned(allocator_, "GRAPHCODE_ZMX") catch "zmx.exe"),
            .cwd = try allocator_.dupe(u8, std.process.getEnvVarOwned(allocator_, "GRAPHCODE_GATE_CWD") catch "."),
            .input_queue = .{ .allocator = allocator_ },
        };
        errdefer {
            allocator_.free(workspace.zmx_path);
            allocator_.free(workspace.cwd);
        }
        if (c.winghostty_host_initialize(&workspace.host) != c.WINGHOSTTY_OK) {
            return error.WinghosttyHostInitializeFailed;
        }
        return workspace;
    }

    pub fn startInputWorker(self: *Workspace) !void {
        self.input_worker = try std.Thread.spawn(.{}, inputWorkerMain, .{self});
    }

    pub fn deinit(self: *Workspace) void {
        self.stopInputWorker();
        self.destroySurface(0);
        self.destroySurface(1);
        for (&self.recreate_sessions) |*session| {
            if (session.*.len != 0) self.allocator.free(session.*);
            session.* = &.{};
        }
        if (self.host) |host| {
            _ = c.winghostty_host_deinitialize(host);
            self.host = null;
        }
        self.allocator.free(self.zmx_path);
        self.allocator.free(self.cwd);
    }

    pub fn openNode(self: *Workspace, index: usize, node_id: []const u8) !void {
        if (index >= self.surfaces.len) return error.InvalidSurface;
        self.destroySurface(index);
        self.resetSessionState(index);
        self.recreate_due_ms[index] = 0;
        const session = try self.allocator.dupe(u8, node_id);
        errdefer self.allocator.free(session);
        if (self.recreate_sessions[index].len != 0) {
            self.allocator.free(self.recreate_sessions[index]);
            self.recreate_sessions[index] = &.{};
        }
        try self.startSession(index, session);
        var options = self.surfaceOptions(index);
        const result = c.winghostty_host_create_surface_v2(
            self.host,
            self.parent,
            &options,
            &self.surfaces[index].surface,
        );
        if (result != c.WINGHOSTTY_OK or self.surfaces[index].surface == null) {
            self.waitAttach(index);
            return error.WinghosttySurfaceCreateFailed;
        }
        self.surfaces[index].session_name = session;
        self.surfaces[index].destroyed = false;
        self.surfaces[index].destroying = false;
        clearCells(&self.surfaces[index]);
        self.resize(
            self.layout_origin_x,
            self.layout_origin_y,
            self.layout_width,
            self.layout_height,
        );
    }

    pub fn recreate(self: *Workspace, index: usize) !void {
        const session = if (self.surfaces[index].session_name.len == 0) return else try self.allocator.dupe(u8, self.surfaces[index].session_name);
        defer self.allocator.free(session);
        self.destroySurface(index);
        try self.openNode(index, session);
    }

    pub fn resize(self: *Workspace, origin_x: i32, origin_y: i32, width: i32, height: i32) void {
        const graph_height = @max(1, height);
        const half = @max(1, @divTrunc(width, 2));
        self.layout_origin_x = origin_x;
        self.layout_origin_y = origin_y;
        self.layout_width = width;
        self.layout_height = graph_height;
        for (&self.surfaces, 0..) |*slot, index| {
            if (slot.surface) |surface| {
                var bounds = c.winghostty_rect{
                    .x = origin_x + if (index == 0) 0 else half,
                    .y = origin_y,
                    .width = @intCast(if (index == 0) half else width - half),
                    .height = @intCast(graph_height),
                };
                _ = c.winghostty_surface_set_bounds(surface, &bounds);
            }
        }
    }

    pub fn poll(self: *Workspace) void {
        self.readAttachOutput(0);
        self.readAttachOutput(1);
        self.pollRecreates();
    }

    pub fn focus(self: *Workspace, index: usize) void {
        if (index >= self.surfaces.len) return;
        self.active_surface = index;
        for (&self.surfaces, 0..) |*slot, other_index| {
            if (slot.surface) |surface| {
                _ = c.winghostty_surface_set_focus(surface, if (index == other_index) 1 else 0);
            }
        }
    }

    pub fn send(self: *Workspace, text: []const u8) void {
        if (self.active_surface >= self.surfaces.len) return;
        self.enqueueInput(self.active_surface, text);
    }

    pub fn inputStatus(self: *const Workspace) ?[]const u8 {
        const workspace: *Workspace = @constCast(self);
        workspace.input_mutex.lock();
        defer workspace.input_mutex.unlock();
        if (workspace.input_error_message.len == 0) return null;
        return workspace.input_error_message;
    }

    pub fn hasSurface(self: *const Workspace, index: usize) bool {
        return index < self.surfaces.len and self.surfaces[index].surface != null;
    }

    pub fn hasAttach(self: *const Workspace, index: usize) bool {
        return index < self.surfaces.len and self.surfaces[index].attach != null;
    }

    pub fn layoutMatches(self: *const Workspace, origin_x: i32, origin_y: i32, width: i32, height: i32) bool {
        return self.layout_origin_x == origin_x and
            self.layout_origin_y == origin_y and
            self.layout_width == width and
            self.layout_height == @max(1, height);
    }

    pub fn destroySurface(self: *Workspace, index: usize) void {
        if (index >= self.surfaces.len) return;
        const slot = &self.surfaces[index];
        slot.destroying = true;
        self.cancelSurfaceInput(index);
        self.waitInputIdle(index);
        self.waitAttach(index);
        if (slot.surface) |surface| {
            _ = c.winghostty_surface_destroy(surface);
            slot.surface = null;
            slot.destroyed = true;
        }
        slot.destroying = false;
        if (slot.session_name.len != 0) {
            self.allocator.free(slot.session_name);
            slot.session_name = &.{};
        }
        self.resetSessionState(index);
    }

    fn surfaceOptions(self: *Workspace, index: usize) c.winghostty_surface_options_v2 {
        var options: c.winghostty_surface_options_v2 = undefined;
        c.winghostty_surface_options_v2_init(&options);
        options.bounds.x = if (index == 0) 0 else 480;
        options.bounds.y = 0;
        options.bounds.width = 480;
        options.bounds.height = 240;
        options.visible = 1;
        options.focus = if (index == self.active_surface) 1 else 0;
        options.theme = c.WINGHOSTTY_THEME_DARK;
        options.font_scale = 1.0;
        options.user_data = @ptrCast(self);
        options.callbacks.on_exit = @ptrCast(&onExit);
        options.callbacks.on_title = @ptrCast(&onTitle);
        options.callbacks.on_cwd = @ptrCast(&onCwd);
        options.callbacks.on_bell = @ptrCast(&onBell);
        options.callbacks.on_notification = @ptrCast(&onNotification);
        options.callbacks.on_redraw = @ptrCast(&onRedraw);
        options.callbacks.on_focus = @ptrCast(&onFocus);
        options.callbacks.on_fatal_error = @ptrCast(&onFatalError);
        options.callbacks.on_dpi_changed = @ptrCast(&onDpiChanged);
        options.callbacks.on_metrics_changed = @ptrCast(&onMetricsChanged);
        options.callbacks.on_accessibility_selection = @ptrCast(&onAccessibilitySelection);
        options.input_callbacks.on_key = @ptrCast(&onKey);
        options.input_callbacks.on_text = @ptrCast(&onText);
        options.input_callbacks.on_ime_start = @ptrCast(&onImeStart);
        options.input_callbacks.on_ime_update = @ptrCast(&onImeUpdate);
        options.input_callbacks.on_ime_end = @ptrCast(&onImeEnd);
        options.input_callbacks.on_mouse = @ptrCast(&onMouse);
        options.input_callbacks.on_selection = @ptrCast(&onSelection);
        options.input_callbacks.on_link = @ptrCast(&onLink);
        options.input_callbacks.on_paste = @ptrCast(&onPaste);
        options.input_callbacks.on_clipboard_read = @ptrCast(&onClipboardRead);
        options.input_callbacks.on_clipboard_write = @ptrCast(&onClipboardWrite);
        options.input.cell_width = 8;
        options.input.cell_height = 16;
        options.input.selection_enabled = 1;
        options.input.links_enabled = 1;
        options.input.paste_protection = 1;
        options.input.bracketed_paste = 1;
        options.input.keyboard_layout = null;
        return options;
    }

    fn startSession(self: *Workspace, index: usize, session: []const u8) !void {
        const nonreading = std.process.getEnvVarOwned(self.allocator, "GRAPHCODE_SHELL_NONREADING_ATTACH") catch null;
        defer if (nonreading) |value| self.allocator.free(value);
        var attach_args: [4][]const u8 = undefined;
        var attach_len: usize = 3;
        if (nonreading != null and std.mem.eql(u8, nonreading.?, "1")) {
            attach_args = .{ "pwsh", "-NoProfile", "-Command", "Start-Sleep -Seconds 60" };
            attach_len = 4;
        } else {
            attach_args[0] = self.zmx_path;
            attach_args[1] = "attach";
            attach_args[2] = session;
        }
        var child = std.process.Child.init(attach_args[0..attach_len], self.allocator);
        child.cwd = self.cwd;
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        try child.spawn();
        if (child.stdin) |stdin| {
            var mode: c.DWORD = c.PIPE_NOWAIT;
            _ = c.SetNamedPipeHandleState(stdin.handle, &mode, null, null);
        }
        self.input_mutex.lock();
        self.surfaces[index].attach = child;
        self.input_mutex.unlock();
    }

    fn waitAttach(self: *Workspace, index: usize) void {
        self.cancelSurfaceInput(index);
        self.waitInputIdle(index);
        if (self.surfaces[index].attach) |*child| {
            _ = child.kill() catch {};
            _ = child.wait() catch {};
            self.surfaces[index].attach = null;
        }
    }

    fn enqueueInput(self: *Workspace, index: usize, bytes: []const u8) void {
        if (bytes.len == 0) return;
        if (bytes.len > input_queue_max_bytes) {
            self.setInputError("terminal input queue overflow: paste is too large");
            return;
        }
        const copy = self.allocator.dupe(u8, bytes) catch {
            self.setInputError("terminal input queue allocation failed");
            return;
        };
        self.input_mutex.lock();
        if (self.input_stop) {
            self.input_mutex.unlock();
            self.allocator.free(copy);
            return;
        }
        self.input_queue.enqueue(index, copy) catch |err| {
            self.input_mutex.unlock();
            self.allocator.free(copy);
            self.setInputError(switch (err) {
                error.InputTooLarge => "terminal input queue overflow: paste is too large",
                error.InputQueueFull => "terminal input queue overflow",
            });
            return;
        };
        self.input_condition.signal();
        self.input_mutex.unlock();
    }

    fn stopInputWorker(self: *Workspace) void {
        self.input_mutex.lock();
        self.input_stop = true;
        self.input_condition.broadcast();
        self.input_mutex.unlock();
        self.cancelInputIo();
        if (self.input_worker) |worker| worker.join();
        self.input_worker = null;
        self.input_mutex.lock();
        self.input_queue.clear();
        self.input_busy = false;
        self.input_worker_surface = null;
        self.input_worker_handle = null;
        self.input_mutex.unlock();
    }

    fn inputWorkerMain(self: *Workspace) void {
        while (true) {
            self.input_mutex.lock();
            while (self.input_queue.count == 0 and !self.input_stop) {
                _ = self.input_condition.timedWait(&self.input_mutex, 25 * std.time.ns_per_ms) catch {};
            }
            if (self.input_stop) {
                self.input_mutex.unlock();
                break;
            }
            const item = self.input_queue.dequeue().?;
            self.input_busy = true;
            self.input_worker_surface = item.surface;
            self.input_worker_handle = if (self.surfaces[item.surface].attach) |child|
                if (child.stdin) |stdin| stdin.handle else null
            else
                null;
            self.input_cancel_requested = false;
            const handle = self.input_worker_handle;
            self.input_mutex.unlock();

            const result = if (handle) |value|
                writeInputBounded(value, item.bytes)
            else
                error.InputUnavailable;
            const cancelled = self.inputCancelled();
            if (result) |written| {
                self.input_mutex.lock();
                if (item.surface < self.surfaces.len) self.surfaces[item.surface].input_bytes += written;
                self.input_mutex.unlock();
            } else |err| {
                if (!cancelled) {
                    self.setInputError(switch (err) {
                        error.WriteTimeout => "terminal input write timed out",
                        error.InputUnavailable => "terminal attach input unavailable",
                        else => "terminal input write failed",
                    });
                }
            }
            self.allocator.free(item.bytes);
            self.input_mutex.lock();
            self.input_busy = false;
            self.input_worker_surface = null;
            self.input_worker_handle = null;
            self.input_cancel_requested = false;
            self.input_condition.broadcast();
            self.input_mutex.unlock();
        }
    }

    fn inputCancelled(self: *Workspace) bool {
        self.input_mutex.lock();
        defer self.input_mutex.unlock();
        return self.input_cancel_requested or self.input_stop;
    }

    fn setInputError(self: *Workspace, message: []const u8) void {
        self.input_mutex.lock();
        self.input_error_message = message;
        self.fatal_error = true;
        self.input_mutex.unlock();
    }

    fn cancelInputIo(self: *Workspace) void {
        var handle: c.HANDLE = null;
        var thread_handle: std.Thread.Handle = undefined;
        var have_thread = false;
        self.input_mutex.lock();
        self.input_cancel_requested = true;
        handle = self.input_worker_handle;
        if (self.input_worker) |worker| {
            thread_handle = worker.getHandle();
            have_thread = true;
        }
        self.input_mutex.unlock();
        if (handle != null and handle != c.INVALID_HANDLE_VALUE) {
            _ = c.CancelIoEx(handle, null);
        }
        if (have_thread) _ = c.CancelSynchronousIo(thread_handle);
    }

    fn cancelSurfaceInput(self: *Workspace, index: usize) void {
        self.input_mutex.lock();
        self.input_queue.removeSurface(index);
        const busy = self.input_busy and self.input_worker_surface == index;
        self.input_mutex.unlock();
        if (busy) self.cancelInputIo();
    }

    fn waitInputIdle(self: *Workspace, index: usize) void {
        const deadline = nowMilliseconds() + 500;
        while (true) {
            self.input_mutex.lock();
            const busy = self.input_busy and self.input_worker_surface == index;
            if (!busy) {
                self.input_mutex.unlock();
                return;
            }
            _ = self.input_condition.timedWait(&self.input_mutex, 25 * std.time.ns_per_ms) catch {};
            self.input_mutex.unlock();
            if (nowMilliseconds() >= deadline) {
                self.cancelInputIo();
                return;
            }
        }
    }

    fn readAttachOutput(self: *Workspace, index: usize) void {
        const slot = &self.surfaces[index];
        const child = slot.attach orelse return;
        const stdout = child.stdout orelse return;
        var available: c.DWORD = 0;
        if (c.PeekNamedPipe(@ptrCast(stdout.handle), null, 0, null, &available, null) == 0) {
            self.handleAttachExit(index);
            return;
        }
        var budget: usize = 64 * 1024;
        while (available > 0 and budget > 0) {
            var buffer: [4096]u8 = undefined;
            var read: c.DWORD = 0;
            const amount = @min(
                @min(available, @as(c.DWORD, @intCast(buffer.len))),
                @as(c.DWORD, @intCast(budget)),
            );
            if (c.ReadFile(@ptrCast(stdout.handle), &buffer, amount, &read, null) == 0 or read == 0) {
                self.handleAttachExit(index);
                return;
            }
            self.feedTerminalOutput(index, buffer[0..@intCast(read)]);
            budget -= @intCast(read);
            if (c.PeekNamedPipe(@ptrCast(stdout.handle), null, 0, null, &available, null) == 0) {
                self.handleAttachExit(index);
                return;
            }
        }
        if (c.GetExitCodeProcess(child.id, &available) != 0 and available != c.STILL_ACTIVE) {
            self.handleAttachExit(index);
        }
    }

    fn handleAttachExit(self: *Workspace, index: usize) void {
        if (index >= self.surfaces.len) return;
        const slot = &self.surfaces[index];
        if (slot.attach == null) return;
        const session = if (slot.session_name.len == 0)
            null
        else
            self.allocator.dupe(u8, slot.session_name) catch null;
        self.waitAttach(index);
        self.destroySurface(index);
        if (session) |value| {
            if (self.recreate_sessions[index].len != 0) self.allocator.free(self.recreate_sessions[index]);
            self.recreate_sessions[index] = value;
            self.recreate_due_ms[index] = nowMilliseconds() + self.recreate_delay_ms[index];
            self.recreate_delay_ms[index] = @min(self.recreate_delay_ms[index] * 2, 4_000);
        }
    }

    fn pollRecreates(self: *Workspace) void {
        const now = nowMilliseconds();
        for (self.recreate_sessions, 0..) |session, index| {
            if (session.len == 0 or self.surfaces[index].surface != null or now < self.recreate_due_ms[index]) {
                continue;
            }
            self.openNode(index, session) catch {
                self.recreate_due_ms[index] = now + self.recreate_delay_ms[index];
                self.recreate_delay_ms[index] = @min(self.recreate_delay_ms[index] * 2, 4_000);
                continue;
            };
            self.recreate_delay_ms[index] = 100;
        }
    }

    fn resetSessionState(self: *Workspace, index: usize) void {
        const slot = &self.surfaces[index];
        slot.terminal_buffer_len = 0;
        slot.parser = .normal;
        slot.csi_value = 0;
        slot.csi_have_value = false;
        clearCells(slot);
        slot.input_bytes = 0;
        slot.output_events = 0;
    }

    fn feedTerminalOutput(self: *Workspace, index: usize, bytes: []const u8) void {
        const slot = &self.surfaces[index];
        const surface = slot.surface orelse return;
        appendOutput(slot, bytes);
        feedCells(slot, bytes);
        self.render_error = c.winghostty_surface_set_terminal_cells(
            surface,
            columns,
            rows,
            &slot.cells,
            cell_count,
        );
        _ = c.winghostty_surface_notify_accessibility_text(
            surface,
            slot.terminal_buffer[0..slot.terminal_buffer_len].ptr,
            slot.terminal_buffer_len,
            0,
            slot.terminal_buffer_len,
            0,
            0,
            slot.terminal_buffer_len,
        );
        _ = c.winghostty_surface_notify_redraw(surface);
        slot.output_events += 1;
    }
};

fn writeInputBounded(handle: c.HANDLE, bytes: []const u8) !usize {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const amount: c.DWORD = @intCast(@min(bytes.len - offset, 16 * 1024));
        var overlapped = std.mem.zeroes(c.OVERLAPPED);
        overlapped.hEvent = c.CreateEventW(null, 1, 0, null);
        if (overlapped.hEvent == null) return error.WriteFailed;
        defer _ = c.CloseHandle(overlapped.hEvent);
        var written: c.DWORD = 0;
        if (c.WriteFile(handle, bytes[offset..].ptr, amount, &written, &overlapped) == 0) {
            if (c.GetLastError() != c.ERROR_IO_PENDING) return error.WriteFailed;
            const wait_result = c.WaitForSingleObject(overlapped.hEvent, input_write_timeout_ms);
            if (wait_result == c.WAIT_TIMEOUT) {
                _ = c.CancelIoEx(handle, &overlapped);
                waitForCancelledWrite(handle, &overlapped, &written);
                return error.WriteTimeout;
            }
            if (wait_result != c.WAIT_OBJECT_0 or
                c.GetOverlappedResult(handle, &overlapped, &written, 0) == 0)
            {
                return error.WriteFailed;
            }
        }
        if (written == 0) return error.WriteFailed;
        offset += written;
    }
    return offset;
}

fn waitForCancelledWrite(
    handle: c.HANDLE,
    overlapped: *c.OVERLAPPED,
    written: *c.DWORD,
) void {
    if (c.GetOverlappedResult(handle, overlapped, written, 1) != 0) return;
    const completion_error = c.GetLastError();
    if (completion_error == c.ERROR_OPERATION_ABORTED or
        completion_error == c.ERROR_IO_INCOMPLETE)
    {
        return;
    }
}

fn nowMilliseconds() i64 {
    return @intCast(std.time.milliTimestamp());
}

fn workspaceFromUserData(user_data: ?*anyopaque) ?*Workspace {
    return if (user_data) |value| @ptrCast(@alignCast(value)) else null;
}

fn slotForSurface(workspace: *Workspace, surface: *c.winghostty_surface) ?*Surface {
    for (&workspace.surfaces) |*slot| if (slot.surface == surface) return slot;
    return null;
}

fn callbackSlot(workspace: *Workspace, surface: *c.winghostty_surface) ?*Surface {
    const slot = slotForSurface(workspace, surface) orelse return null;
    if (slot.destroying or slot.destroyed) return null;
    return slot;
}

fn onExit(user_data: ?*anyopaque, surface: ?*c.winghostty_surface, status: i32) callconv(.c) void {
    const workspace = workspaceFromUserData(user_data) orelse return;
    if (surface) |value| _ = callbackSlot(workspace, value);
    _ = status;
}

fn onTitle(user_data: ?*anyopaque, surface: *c.winghostty_surface, title: [*:0]const u8) callconv(.c) void {
    _ = user_data;
    _ = surface;
    _ = title;
}

fn onCwd(user_data: ?*anyopaque, surface: *c.winghostty_surface, cwd: [*:0]const u8) callconv(.c) void {
    _ = user_data;
    _ = surface;
    _ = cwd;
}

fn onBell(user_data: ?*anyopaque, surface: *c.winghostty_surface) callconv(.c) void {
    _ = user_data;
    _ = surface;
}

fn onNotification(user_data: ?*anyopaque, surface: *c.winghostty_surface, notification: [*:0]const u8) callconv(.c) void {
    _ = user_data;
    _ = surface;
    _ = notification;
}

fn onRedraw(user_data: ?*anyopaque, surface: *c.winghostty_surface) callconv(.c) void {
    const workspace = workspaceFromUserData(user_data) orelse return;
    _ = callbackSlot(workspace, surface) orelse return;
    if (c.winghostty_surface_make_current(surface) != c.WINGHOSTTY_OK) return;
    _ = c.winghostty_surface_render(surface);
    _ = c.winghostty_surface_present(surface);
    _ = c.winghostty_surface_clear_current(surface);
}

fn onFocus(user_data: ?*anyopaque, surface: *c.winghostty_surface, focused: u8) callconv(.c) void {
    const workspace = workspaceFromUserData(user_data) orelse return;
    _ = callbackSlot(workspace, surface) orelse return;
    if (focused == 0) return;
    for (&workspace.surfaces, 0..) |*slot, index| {
        if (slot.surface == surface) workspace.active_surface = index;
        if (slot.surface) |other| {
            if (other != surface) {
                _ = c.winghostty_surface_set_focus(other, 0);
            }
        }
    }
}

fn onFatalError(
    user_data: ?*anyopaque,
    surface: *c.winghostty_surface,
    result: c.winghostty_result,
    message: [*:0]const u8,
) callconv(.c) void {
    const workspace = workspaceFromUserData(user_data) orelse return;
    _ = callbackSlot(workspace, surface) orelse return;
    _ = result;
    _ = message;
    workspace.fatal_error = true;
}

fn onDpiChanged(user_data: ?*anyopaque, surface: *c.winghostty_surface, dpi: u32, scale: f32) callconv(.c) void {
    _ = user_data;
    _ = surface;
    _ = dpi;
    _ = scale;
}

fn onMetricsChanged(user_data: ?*anyopaque, surface: *c.winghostty_surface, metrics: *const c.winghostty_cell_metrics) callconv(.c) void {
    _ = user_data;
    _ = surface;
    _ = metrics;
}

fn onAccessibilitySelection(user_data: ?*anyopaque, surface: *c.winghostty_surface, start: u64, end: u64) callconv(.c) void {
    _ = user_data;
    _ = surface;
    _ = start;
    _ = end;
}

fn onKey(user_data: ?*anyopaque, surface: *c.winghostty_surface, event: *const c.winghostty_key_event) callconv(.c) void {
    const workspace = workspaceFromUserData(user_data) orelse return;
    _ = callbackSlot(workspace, surface) orelse return;
    if (event.action == c.WINGHOSTTY_KEY_RELEASE) return;
    const bytes: []const u8 = switch (event.virtual_key) {
        c.VK_RETURN => "\r",
        c.VK_BACK => "\x08",
        c.VK_TAB => "\t",
        c.VK_ESCAPE => "\x1b",
        c.VK_UP => "\x1b[A",
        c.VK_DOWN => "\x1b[B",
        c.VK_LEFT => "\x1b[D",
        c.VK_RIGHT => "\x1b[C",
        else => return,
    };
    const index = surfaceIndex(workspace, surface) orelse return;
    workspace.enqueueInput(index, bytes);
}

fn onText(user_data: ?*anyopaque, surface: *c.winghostty_surface, text: [*:0]const u8, length: u32) callconv(.c) void {
    const workspace = workspaceFromUserData(user_data) orelse return;
    _ = callbackSlot(workspace, surface) orelse return;
    const index = surfaceIndex(workspace, surface) orelse return;
    workspace.enqueueInput(index, text[0..length]);
}

fn onImeStart(user_data: ?*anyopaque, surface: *c.winghostty_surface) callconv(.c) void {
    _ = user_data;
    _ = surface;
}

fn onImeUpdate(user_data: ?*anyopaque, surface: *c.winghostty_surface, text: [*:0]const u8, length: u32, cursor: u32) callconv(.c) void {
    _ = user_data;
    _ = surface;
    _ = text;
    _ = length;
    _ = cursor;
}

fn onImeEnd(user_data: ?*anyopaque, surface: *c.winghostty_surface) callconv(.c) void {
    _ = user_data;
    _ = surface;
}

fn onMouse(user_data: ?*anyopaque, surface: *c.winghostty_surface, event: *const c.winghostty_mouse_event) callconv(.c) void {
    _ = user_data;
    _ = surface;
    _ = event;
}

fn onSelection(user_data: ?*anyopaque, surface: *c.winghostty_surface, event: *const c.winghostty_selection_event) callconv(.c) void {
    _ = user_data;
    _ = surface;
    _ = event;
}

fn onLink(
    user_data: ?*anyopaque,
    surface: *c.winghostty_surface,
    link: [*:0]const u8,
    hovered: u8,
    clicked: u8,
) callconv(.c) void {
    _ = user_data;
    _ = surface;
    _ = link;
    _ = hovered;
    _ = clicked;
}

fn onPaste(user_data: ?*anyopaque, surface: *c.winghostty_surface, text: [*:0]const u8, length: u32, bracketed: u8) callconv(.c) void {
    const workspace = workspaceFromUserData(user_data) orelse return;
    _ = callbackSlot(workspace, surface) orelse return;
    const index = surfaceIndex(workspace, surface) orelse return;
    workspace.enqueueInput(index, text[0..length]);
    _ = bracketed;
}

fn onClipboardRead(
    user_data: ?*anyopaque,
    surface: *c.winghostty_surface,
    format: u32,
    text: [*:0]const u8,
    length: u32,
) callconv(.c) void {
    _ = user_data;
    _ = surface;
    _ = format;
    _ = text;
    _ = length;
}

fn onClipboardWrite(
    user_data: ?*anyopaque,
    surface: *c.winghostty_surface,
    format: u32,
    text: [*:0]const u8,
    length: u32,
) callconv(.c) void {
    _ = user_data;
    _ = surface;
    _ = format;
    _ = text;
    _ = length;
}

fn surfaceIndex(workspace: *Workspace, surface: *c.winghostty_surface) ?usize {
    for (workspace.surfaces, 0..) |slot, index| if (slot.surface == surface) return index;
    return null;
}

fn appendOutput(slot: *Surface, bytes: []const u8) void {
    if (bytes.len >= slot.terminal_buffer.len) {
        @memcpy(&slot.terminal_buffer, bytes[bytes.len - slot.terminal_buffer.len ..]);
        slot.terminal_buffer_len = slot.terminal_buffer.len;
        return;
    }
    if (slot.terminal_buffer_len + bytes.len > slot.terminal_buffer.len) {
        const overflow = slot.terminal_buffer_len + bytes.len - slot.terminal_buffer.len;
        std.mem.copyForwards(u8, slot.terminal_buffer[0 .. slot.terminal_buffer_len - overflow], slot.terminal_buffer[overflow..slot.terminal_buffer_len]);
        slot.terminal_buffer_len -= overflow;
    }
    @memcpy(slot.terminal_buffer[slot.terminal_buffer_len..][0..bytes.len], bytes);
    slot.terminal_buffer_len += bytes.len;
}

fn clearCells(slot: *Surface) void {
    for (&slot.cells) |*cell| cell.* = .{ .codepoint = 0, .foreground = 0xE6E6E6, .background = 0, .flags = 0 };
    slot.terminal_x = 0;
    slot.terminal_y = 0;
}

fn advanceLine(slot: *Surface) void {
    slot.terminal_x = 0;
    if (slot.terminal_y + 1 < rows) {
        slot.terminal_y += 1;
        return;
    }
    std.mem.copyForwards(c.winghostty_terminal_cell, slot.cells[0 .. cell_count - columns], slot.cells[columns..]);
    for (slot.cells[cell_count - columns ..]) |*cell| cell.* = .{ .codepoint = 0, .foreground = 0xE6E6E6, .background = 0, .flags = 0 };
}

fn putCodepoint(slot: *Surface, codepoint: u32) void {
    if (slot.terminal_x >= columns) advanceLine(slot);
    slot.cells[slot.terminal_y * columns + slot.terminal_x] = .{ .codepoint = codepoint, .foreground = 0xE6E6E6, .background = 0, .flags = 0 };
    slot.terminal_x += 1;
}

fn finishCsi(slot: *Surface, final: u8) void {
    const value = if (slot.csi_have_value) slot.csi_value else 1;
    switch (final) {
        'A' => slot.terminal_y -|= value,
        'B' => slot.terminal_y = @min(rows - 1, slot.terminal_y + value),
        'C' => slot.terminal_x = @min(columns, slot.terminal_x + value),
        'D' => slot.terminal_x -|= value,
        'J' => if (slot.csi_have_value and slot.csi_value == 2) clearCells(slot),
        'K' => {
            const start = slot.terminal_y * columns + slot.terminal_x;
            for (slot.cells[start..][0 .. columns - slot.terminal_x]) |*cell| cell.* = .{ .codepoint = 0, .foreground = 0xE6E6E6, .background = 0, .flags = 0 };
        },
        else => {},
    }
    slot.csi_value = 0;
    slot.csi_have_value = false;
}

fn feedCells(slot: *Surface, bytes: []const u8) void {
    for (bytes) |byte| switch (slot.parser) {
        .normal => switch (byte) {
            0x1B => slot.parser = .escape,
            '\r' => slot.terminal_x = 0,
            '\n' => advanceLine(slot),
            '\x08' => slot.terminal_x -|= 1,
            '\t' => slot.terminal_x = @min(columns, (slot.terminal_x + 8) & ~@as(usize, 7)),
            0x20...0x7E => putCodepoint(slot, byte),
            else => {},
        },
        .escape => switch (byte) {
            '[' => {
                slot.parser = .csi;
                slot.csi_value = 0;
                slot.csi_have_value = false;
            },
            ']' => slot.parser = .osc,
            'c' => {
                clearCells(slot);
                slot.parser = .normal;
            },
            else => slot.parser = .normal,
        },
        .csi => switch (byte) {
            '0'...'9' => {
                slot.csi_have_value = true;
                slot.csi_value = @min(9999, slot.csi_value * 10 + (byte - '0'));
            },
            0x40...0x7E => {
                finishCsi(slot, byte);
                slot.parser = .normal;
            },
            else => {},
        },
        .osc => {
            if (byte == 0x07) {
                slot.parser = .normal;
            } else if (byte == 0x1B) {
                slot.parser = .escape;
            }
        },
    };
}

test "terminal input queue rejects large paste without waiting" {
    const allocator = std.testing.allocator;
    var queue = InputQueue{ .allocator = allocator };
    defer queue.clear();
    const paste = try allocator.alloc(u8, InputQueue.max_bytes + 1);
    try std.testing.expectError(error.InputTooLarge, queue.enqueue(0, paste));
    allocator.free(paste);
}

test "terminal input queue reports bounded overflow" {
    const allocator = std.testing.allocator;
    var queue = InputQueue{ .allocator = allocator };
    defer queue.clear();
    for (0..input_queue_capacity) |index| {
        const item = try allocator.dupe(u8, "x");
        try queue.enqueue(index % 2, item);
    }
    const overflow = try allocator.dupe(u8, "x");
    try std.testing.expectError(error.InputQueueFull, queue.enqueue(0, overflow));
    allocator.free(overflow);
}

test "bounded input write rejects an invalid attach without blocking" {
    try std.testing.expectError(error.WriteFailed, writeInputBounded(c.INVALID_HANDLE_VALUE, "paste"));
}
