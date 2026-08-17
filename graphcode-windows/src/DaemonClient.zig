const std = @import("std");
const FrameBuffer = @import("FrameBuffer.zig").FrameBuffer;
const Wire = @import("Wire.zig");
const Forms = @import("Forms.zig");
const c = @import("Win32.zig").c;

pub const EventCallback = *const fn (
    context: ?*anyopaque,
    frame: [*]const u8,
    length: usize,
) callconv(.c) void;

pub const DaemonClient = struct {
    const reconnect_initial_ms: i64 = 100;
    const reconnect_max_ms: i64 = 4_000;
    const negotiation_timeout_ms: i64 = 1_500;
    const outbound_capacity: usize = 64;
    const inbound_capacity: usize = 128;

    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    worker: ?std.Thread = null,
    stop_worker: bool = false,
    want_connected: bool = false,
    reconnect_requested: bool = false,
    retry_now: bool = false,
    outbound: [outbound_capacity][]u8 = undefined,
    outbound_head: usize = 0,
    outbound_count: usize = 0,
    worker_busy: bool = false,
    inbound: [inbound_capacity][]u8 = undefined,
    inbound_head: usize = 0,
    inbound_count: usize = 0,
    pipe: c.HANDLE = c.INVALID_HANDLE_VALUE,
    pipe_name: []u8 = &.{},
    client_id: [36]u8 = undefined,
    mode: Wire.ProtocolMode = .v2,
    state: Wire.ConnectionState = .disconnected,
    selected_version: u8 = Wire.current_version,
    last_error: []const u8 = "",
    resume_from: u64 = 0,
    next_request: u64 = 1,
    next_draft: u64 = 1,
    pending_request_ids: [64][36]u8 = undefined,
    pending_request_count: usize = 0,
    subscription_path: []const u8 = "",
    frame_buffer: FrameBuffer,
    retry_at_ms: i64 = 0,
    retry_delay_ms: i64 = reconnect_initial_ms,
    negotiation_deadline_ms: i64 = 0,
    fallback_to_v1: bool = false,
    callback: ?EventCallback = null,
    callback_context: ?*anyopaque = null,

    pub fn init(allocator: std.mem.Allocator) !DaemonClient {
        var client = DaemonClient{
            .allocator = allocator,
            .frame_buffer = try FrameBuffer.init(allocator, .v2),
        };
        errdefer client.frame_buffer.deinit();
        makeClientID(&client.client_id);
        client.pipe_name = endpointName(allocator) catch
            try allocator.dupe(u8, "\\\\.\\pipe\\graphcode-daemon-unavailable");
        return client;
    }

    pub fn start(self: *DaemonClient) !void {
        self.worker = try std.Thread.spawn(.{}, workerMain, .{self});
    }

    pub fn deinit(self: *DaemonClient) void {
        self.mutex.lock();
        self.stop_worker = true;
        self.want_connected = false;
        self.condition.broadcast();
        self.mutex.unlock();
        if (self.worker) |thread| thread.join();
        self.clearQueues();
        if (self.pipe_name.len != 0) self.allocator.free(self.pipe_name);
        if (self.subscription_path.len != 0) self.allocator.free(self.subscription_path);
        self.frame_buffer.deinit();
    }

    pub fn setCallback(
        self: *DaemonClient,
        callback: EventCallback,
        context: ?*anyopaque,
    ) void {
        self.callback = callback;
        self.callback_context = context;
    }

    pub fn setSubscription(self: *DaemonClient, project_path: []const u8) void {
        const copy = self.allocator.dupe(u8, project_path) catch {
            self.mutex.lock();
            self.last_error = "subscription allocation failed";
            self.mutex.unlock();
            return;
        };
        self.mutex.lock();
        if (std.mem.eql(u8, self.subscription_path, project_path)) {
            self.mutex.unlock();
            self.allocator.free(copy);
            return;
        }
        if (self.subscription_path.len != 0) self.allocator.free(self.subscription_path);
        self.subscription_path = copy;
        self.reconnect_requested = true;
        self.retry_now = true;
        self.condition.signal();
        self.mutex.unlock();
        self.publishState(.reconnecting, "");
    }

    pub fn validateSettings(
        self: *DaemonClient,
        pipe_override: []const u8,
        support_directory: []const u8,
    ) !void {
        _ = self;
        const allocator = std.heap.page_allocator;
        const support = try supportDirectoryFor(allocator, support_directory);
        defer allocator.free(support);
        try validateSupportDirectory(allocator, support);
        const endpoint = try endpointNameFor(allocator, pipe_override, support);
        defer allocator.free(endpoint);
        if (!std.mem.startsWith(u8, endpoint, "\\\\.\\pipe\\") or endpoint.len > 240)
            return error.InvalidDaemonPipe;
    }

    pub fn applySettings(
        self: *DaemonClient,
        pipe_override: []const u8,
        support_directory: []const u8,
    ) !void {
        try self.validateSettings(pipe_override, support_directory);
        const old_pipe = std.process.getEnvVarOwned(self.allocator, "GRAPHCODE_DAEMON_PIPE") catch null;
        defer if (old_pipe) |value| self.allocator.free(value);
        const old_support = std.process.getEnvVarOwned(self.allocator, "GRAPHCODE_SUPPORT_DIR") catch null;
        defer if (old_support) |value| self.allocator.free(value);
        setEnvironmentChecked("GRAPHCODE_DAEMON_PIPE", if (pipe_override.len == 0) null else pipe_override) catch return error.EnvironmentUpdateFailed;
        setEnvironmentChecked("GRAPHCODE_SUPPORT_DIR", if (support_directory.len == 0) null else support_directory) catch {
            setEnvironmentChecked("GRAPHCODE_DAEMON_PIPE", old_pipe) catch {};
            return error.EnvironmentUpdateFailed;
        };
        self.reconnect();
    }

    pub fn effectiveSettings(self: *DaemonClient, allocator: std.mem.Allocator) !Forms.Settings {
        _ = self;
        const pipe = std.process.getEnvVarOwned(allocator, "GRAPHCODE_DAEMON_PIPE") catch try allocator.dupe(u8, "");
        errdefer allocator.free(pipe);
        const support = std.process.getEnvVarOwned(allocator, "GRAPHCODE_SUPPORT_DIR") catch try allocator.dupe(u8, "");
        return .{ .daemon_pipe = pipe, .support_directory = support };
    }

    pub fn currentEndpointName(self: *DaemonClient, allocator: std.mem.Allocator) ![]u8 {
        _ = self;
        return endpointName(allocator);
    }

    fn validateSupportDirectory(allocator: std.mem.Allocator, support_directory: []const u8) !void {
        const normalized = try normalizedSupportPath(allocator, support_directory);
        defer std.heap.page_allocator.free(normalized);
        const wide = try utf8ToWide(allocator, normalized);
        defer allocator.free(wide);
        const attributes = c.GetFileAttributesW(wide.ptr);
        if (attributes == c.INVALID_FILE_ATTRIBUTES or
            (attributes & c.FILE_ATTRIBUTE_DIRECTORY) == 0)
            return error.SupportDirectoryMissing;
        const secret_path = try std.fs.path.join(allocator, &.{ normalized, ".graphcode-rendezvous.secret" });
        defer allocator.free(secret_path);
        const secret = std.fs.cwd().readFileAlloc(
            allocator,
            secret_path,
            4096,
        ) catch return error.SupportSecretMissing;
        defer allocator.free(secret);
        if (secret.len != 32 or std.mem.allEqual(u8, secret, 0))
            return error.SupportSecretInvalid;
    }

    pub fn connect(self: *DaemonClient) void {
        self.mutex.lock();
        self.want_connected = true;
        self.condition.signal();
        self.mutex.unlock();
    }

    pub fn reconnect(self: *DaemonClient) void {
        self.mutex.lock();
        self.want_connected = true;
        self.reconnect_requested = true;
        self.retry_now = true;
        self.condition.signal();
        self.mutex.unlock();
    }

    pub fn close(self: *DaemonClient) void {
        self.mutex.lock();
        self.want_connected = false;
        self.reconnect_requested = false;
        self.clearOutboundLocked();
        self.condition.signal();
        self.mutex.unlock();
    }

    pub fn sendListProjects(self: *DaemonClient) void {
        const command = Wire.commandListRecentProjects(self.allocator) catch return;
        self.sendCommand(command);
    }

    pub fn sendRestoreOpenProjects(self: *DaemonClient) void {
        const command = Wire.commandRestoreOpenProjects(self.allocator) catch return;
        self.sendCommand(command);
    }

    pub fn sendOpenGlobalGraph(self: *DaemonClient) void {
        const command = Wire.commandOpenGlobalGraph(self.allocator) catch return;
        self.sendCommand(command);
    }

    pub fn sendOpenProject(self: *DaemonClient, path: []const u8) void {
        const command = Wire.commandOpenProject(self.allocator, path) catch return;
        self.sendCommand(command);
    }

    pub fn sendCreateNode(self: *DaemonClient, project_path: []const u8, title: []const u8) void {
        var node_id: [36]u8 = undefined;
        self.mutex.lock();
        const sequence = self.next_draft;
        self.next_draft +%= 1;
        self.mutex.unlock();
        makeRequestID(&node_id, sequence);
        const command = Wire.commandGraphCreateNode(
            self.allocator,
            project_path,
            title,
            &node_id,
        ) catch return;
        self.sendCommand(command);
    }

    pub fn sendNodeAction(
        self: *DaemonClient,
        project_path: []const u8,
        node_id: []const u8,
        action: []const u8,
        text: ?[]const u8,
    ) void {
        const command = Wire.commandGraphNodeAction(
            self.allocator,
            project_path,
            node_id,
            action,
            text,
        ) catch return;
        self.sendCommand(command);
    }

    pub fn sendRenameNode(self: *DaemonClient, project_path: []const u8, node_id: []const u8, title: []const u8) void {
        const command = Wire.commandGraphRenameNode(self.allocator, project_path, node_id, title) catch {
            self.publishState(self.connectionState(), "rename node command encoding failed");
            return;
        };
        self.sendCommand(command);
    }

    pub fn sendCreateEdge(
        self: *DaemonClient,
        project_path: []const u8,
        from: []const u8,
        to: []const u8,
        kind: []const u8,
    ) void {
        const command = Wire.commandGraphCreateEdge(self.allocator, project_path, from, to, kind) catch {
            self.publishState(self.connectionState(), "create edge command encoding failed");
            return;
        };
        self.sendCommand(command);
    }

    pub fn poll(self: *DaemonClient) void {
        var count: usize = 0;
        while (count < inbound_capacity) : (count += 1) {
            self.mutex.lock();
            if (self.inbound_count == 0) {
                self.mutex.unlock();
                return;
            }
            const frame = self.inbound[self.inbound_head];
            self.inbound_head = (self.inbound_head + 1) % inbound_capacity;
            self.inbound_count -= 1;
            self.mutex.unlock();
            defer self.allocator.free(frame);
            if (self.callback) |callback| callback(self.callback_context, frame.ptr, frame.len);
        }
    }

    pub fn connectionState(self: *const DaemonClient) Wire.ConnectionState {
        const client: *DaemonClient = @constCast(self);
        client.mutex.lock();
        defer client.mutex.unlock();
        return client.state;
    }

    pub fn isIdle(self: *const DaemonClient) bool {
        const client: *DaemonClient = @constCast(self);
        client.mutex.lock();
        defer client.mutex.unlock();
        return client.state == .connected and
            client.outbound_count == 0 and
            client.inbound_count == 0 and
            client.pending_request_count == 0 and
            !client.worker_busy;
    }

    pub fn statusText(self: *const DaemonClient) []const u8 {
        const client: *DaemonClient = @constCast(self);
        client.mutex.lock();
        defer client.mutex.unlock();
        if (client.last_error.len != 0) return client.last_error;
        return switch (client.state) {
            .disconnected => "Disconnected",
            .connecting => "Connecting…",
            .negotiating => "Negotiating daemon protocol…",
            .connected => if (self.mode == .v2) "Connected · protocol v2" else "Connected · protocol v1",
            .reconnecting => "Reconnecting…",
            .unavailable => "Daemon unavailable · retrying",
            .protocol_error => "Daemon protocol error",
        };
    }

    fn sendCommand(self: *DaemonClient, command_json: []const u8) void {
        self.mutex.lock();
        if (self.stop_worker or self.outbound_count == outbound_capacity) {
            self.last_error = "daemon outbound queue is full";
            self.mutex.unlock();
            self.allocator.free(command_json);
            return;
        }
        const index = (self.outbound_head + self.outbound_count) % outbound_capacity;
        self.outbound[index] = @constCast(command_json);
        self.outbound_count += 1;
        self.condition.signal();
        self.mutex.unlock();
    }

    fn openPipe(self: *DaemonClient) bool {
        const wide = utf8ToWide(self.allocator, self.pipe_name) catch return false;
        defer self.allocator.free(wide);
        const handle = c.CreateFileW(
            wide.ptr,
            c.GENERIC_READ | c.GENERIC_WRITE,
            0,
            null,
            c.OPEN_EXISTING,
            c.FILE_FLAG_OVERLAPPED,
            null,
        );
        if (handle == c.INVALID_HANDLE_VALUE) {
            if (c.GetLastError() == c.ERROR_PIPE_BUSY) {
                _ = c.WaitNamedPipeW(wide.ptr, 50);
            }
            return false;
        }
        self.pipe = handle;
        return true;
    }

    fn workerMain(self: *DaemonClient) void {
        while (true) {
            self.mutex.lock();
            const stop = self.stop_worker;
            const want_connected = self.want_connected;
            const reconnect_pending = self.reconnect_requested;
            const retry_immediately = self.retry_now;
            self.reconnect_requested = false;
            self.retry_now = false;
            self.mutex.unlock();
            if (stop) break;

            if (!want_connected) {
                if (self.pipe != c.INVALID_HANDLE_VALUE) self.closeHandleOnly();
                self.clearPendingRequests();
                if (self.state != .disconnected) self.publishState(.disconnected, "");
                if (self.waitForWork(50)) break;
                continue;
            }

            if (reconnect_pending) {
                self.closeHandleOnly();
                self.clearPendingRequests();
                self.retry_at_ms = nowMilliseconds();
                self.retry_delay_ms = reconnect_initial_ms;
                self.publishState(.reconnecting, "");
            }
            if (retry_immediately) self.retry_at_ms = 0;

            const now = nowMilliseconds();
            if (self.pipe == c.INVALID_HANDLE_VALUE and now >= self.retry_at_ms) {
                self.attemptConnection(now);
            }

            if (self.pipe != c.INVALID_HANDLE_VALUE) {
                if (!self.pumpIncoming()) continue;
                if (self.state == .negotiating and nowMilliseconds() >= self.negotiation_deadline_ms) {
                    self.beginLegacyFallback(nowMilliseconds());
                }
            }

            if (self.pipe != c.INVALID_HANDLE_VALUE and self.state == .connected) {
                if (self.dequeueOutbound()) |command| {
                    self.sendCommandOnWorker(command);
                    self.allocator.free(command);
                    self.mutex.lock();
                    self.worker_busy = false;
                    self.mutex.unlock();
                }
            }
            if (self.waitForWork(25)) break;
        }
        if (self.pipe != c.INVALID_HANDLE_VALUE) self.closeHandleOnly();
        self.clearPendingRequests();
        self.clearQueues();
        self.publishState(.disconnected, "");
    }

    fn waitForWork(self: *DaemonClient, milliseconds: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.stop_worker) return true;
        if (self.outbound_count == 0 and self.inbound_count == 0) {
            _ = self.condition.timedWait(&self.mutex, milliseconds * std.time.ns_per_ms) catch {};
        }
        return self.stop_worker;
    }

    fn dequeueOutbound(self: *DaemonClient) ?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.outbound_count == 0) return null;
        const command = self.outbound[self.outbound_head];
        self.outbound_head = (self.outbound_head + 1) % outbound_capacity;
        self.outbound_count -= 1;
        self.worker_busy = true;
        return command;
    }

    fn sendCommandOnWorker(self: *DaemonClient, command_json: []const u8) void {
        const frame = if (self.mode == .v2) blk: {
            var request_id: [36]u8 = undefined;
            makeRequestID(&request_id, self.next_request);
            self.next_request +%= 1;
            if (!self.trackRequest(&request_id)) {
                self.publishState(self.state, "too many outstanding daemon requests");
                return;
            }
            break :blk Wire.v2Request(
                self.allocator,
                &request_id,
                command_json,
            ) catch {
                self.publishState(self.state, "request encoding failed");
                return;
            };
        } else Wire.v1Command(self.allocator, command_json) catch {
            self.publishState(self.state, "request encoding failed");
            return;
        };
        defer self.allocator.free(frame);
        self.writeFrame(frame) catch {
            if (self.mode == .v2) {
                if (Wire.responseRequestID(frame)) |request_id| {
                    _ = self.completeRequest(request_id);
                }
            }
            self.markTransportFailure("daemon write failed");
        };
    }

    fn writeFrame(self: *DaemonClient, data: []const u8) !void {
        const header = try Wire.frameLength(data, self.mode);
        try writeAll(self.pipe, &header);
        try writeAll(self.pipe, data);
    }

    fn attemptConnection(self: *DaemonClient, now: i64) void {
        self.closeHandleOnly();
        self.prepareV2Negotiation();
        if (endpointName(self.allocator)) |current| {
            if (!std.mem.eql(u8, current, self.pipe_name)) {
                self.allocator.free(self.pipe_name);
                self.pipe_name = current;
            } else {
                self.allocator.free(current);
            }
        } else |_| {}
        self.publishState(.connecting, "");
        if (!self.openPipe()) {
            self.scheduleRetry(now, "daemon unavailable; retrying");
            return;
        }
        self.frame_buffer.reset();
        if (self.fallback_to_v1) {
            self.frame_buffer.setMode(.v1);
            self.mode = .v1;
            self.selected_version = 1;
            self.publishState(.connected, "");
            self.fallback_to_v1 = false;
            self.retry_delay_ms = reconnect_initial_ms;
            return;
        }
        self.publishState(.negotiating, "");
        self.negotiation_deadline_ms = now + negotiation_timeout_ms;
        const subscription = self.subscriptionSnapshot() catch {
            self.scheduleRetry(now, "daemon subscription allocation failed");
            return;
        };
        defer self.allocator.free(subscription);
        const hello = Wire.v2Hello(
            self.allocator,
            &self.client_id,
            if (self.resume_from == 0) null else self.resume_from,
            subscription,
        ) catch {
            self.scheduleRetry(now, "daemon hello encoding failed");
            return;
        };
        defer self.allocator.free(hello);
        self.writeFrame(hello) catch {
            self.scheduleRetry(now, "daemon hello write failed");
            return;
        };
    }

    fn prepareV2Negotiation(self: *DaemonClient) void {
        self.mode = .v2;
        self.selected_version = Wire.current_version;
        self.frame_buffer.setMode(.v2);
    }

    fn pumpIncoming(self: *DaemonClient) bool {
        if (self.pipe == c.INVALID_HANDLE_VALUE) return true;
        var round: usize = 0;
        while (round < 8) : (round += 1) {
            var chunk: [16 * 1024]u8 = undefined;
            var overlapped = std.mem.zeroes(c.OVERLAPPED);
            overlapped.hEvent = c.CreateEventW(null, 1, 0, null);
            if (overlapped.hEvent == null) {
                self.markTransportFailure("daemon read event failed");
                return false;
            }
            defer _ = c.CloseHandle(overlapped.hEvent);
            var read: c.DWORD = 0;
            const completed = c.ReadFile(
                self.pipe,
                &chunk,
                @intCast(chunk.len),
                &read,
                &overlapped,
            ) != 0;
            if (!completed) {
                const read_error = c.GetLastError();
                if (read_error == c.ERROR_IO_PENDING) {
                    const wait_result = c.WaitForSingleObject(overlapped.hEvent, 20);
                    if (wait_result == c.WAIT_TIMEOUT) {
                        _ = c.CancelIoEx(self.pipe, &overlapped);
                        _ = c.GetOverlappedResult(self.pipe, &overlapped, &read, 1);
                        break;
                    }
                    if (wait_result != c.WAIT_OBJECT_0 or
                        c.GetOverlappedResult(self.pipe, &overlapped, &read, 0) == 0)
                    {
                        const result_error = c.GetLastError();
                        if (result_error == c.ERROR_OPERATION_ABORTED) break;
                        self.markTransportFailure("daemon frame read failed");
                        return false;
                    }
                } else if (read_error == c.ERROR_NO_DATA or read_error == c.ERROR_BROKEN_PIPE) {
                    self.markTransportFailure("daemon connection closed");
                    return false;
                } else {
                    self.markTransportFailure("daemon frame read failed");
                    return false;
                }
            }
            if (read == 0) {
                self.markTransportFailure("daemon connection closed");
                return false;
            }
            self.frame_buffer.append(chunk[0..read]) catch {
                self.markProtocolFailure("daemon receive buffer overflow");
                return false;
            };
        }

        while (true) {
            const frame = self.frame_buffer.next(self.allocator) catch {
                self.markProtocolFailure("daemon frame allocation failed");
                return false;
            };
            const complete = frame orelse return true;
            defer self.allocator.free(complete);
            if (!self.handleFrame(complete)) return false;
            if (self.state != .connected) return true;
        }
    }

    fn markTransportFailure(self: *DaemonClient, message: []const u8) void {
        self.clearPendingRequests();
        self.closeHandleOnly();
        self.publishState(.reconnecting, message);
        self.retry_at_ms = nowMilliseconds() + self.retry_delay_ms;
        self.retry_delay_ms = @min(self.retry_delay_ms * 2, reconnect_max_ms);
    }

    fn markProtocolFailure(self: *DaemonClient, message: []const u8) void {
        self.clearPendingRequests();
        self.closeHandleOnly();
        self.publishState(.protocol_error, message);
        self.retry_at_ms = nowMilliseconds() + self.retry_delay_ms;
        self.retry_delay_ms = @min(self.retry_delay_ms * 2, reconnect_max_ms);
    }

    fn scheduleRetry(self: *DaemonClient, now: i64, message: []const u8) void {
        self.closeHandleOnly();
        self.frame_buffer.reset();
        self.publishState(.unavailable, message);
        self.retry_at_ms = now + self.retry_delay_ms;
        self.retry_delay_ms = @min(self.retry_delay_ms * 2, reconnect_max_ms);
    }

    fn beginLegacyFallback(self: *DaemonClient, now: i64) void {
        self.closeHandleOnly();
        self.frame_buffer.setMode(.v1);
        self.clearPendingRequests();
        self.mode = .v1;
        self.selected_version = 1;
        self.fallback_to_v1 = true;
        self.publishState(.reconnecting, "");
        self.retry_at_ms = now;
    }

    fn handleFrame(self: *DaemonClient, frame: []const u8) bool {
        if (self.state == .negotiating) {
            if (Wire.looksLikeV2(frame) and
                std.mem.indexOf(u8, frame, "\"kind\":\"hello\"") != null and
                std.mem.indexOf(u8, frame, "\"selectedVersion\":2") != null)
            {
                self.mode = .v2;
                self.frame_buffer.setModePreservingData(.v2);
                self.selected_version = 2;
                self.publishState(.connected, "");
                self.retry_delay_ms = reconnect_initial_ms;
                return true;
            }
            self.beginLegacyFallback(nowMilliseconds());
            return true;
        }
        if (self.mode == .v2) {
            if (Wire.responseRequestID(frame)) |request_id| {
                if (!self.completeRequest(request_id)) {
                    self.markProtocolFailure("unmatched daemon response");
                    return false;
                }
            }
        }
        self.enqueueInbound(frame);
        if (Wire.jsonNumber(frame, "sequence")) |sequence| self.resume_from = sequence;
        return true;
    }

    fn enqueueInbound(self: *DaemonClient, frame: []const u8) void {
        const copy = self.allocator.dupe(u8, frame) catch {
            self.publishState(self.state, "daemon event allocation failed");
            return;
        };
        self.mutex.lock();
        if (self.inbound_count == inbound_capacity) {
            self.mutex.unlock();
            self.allocator.free(copy);
            self.publishState(self.state, "daemon event queue is full");
            return;
        }
        const index = (self.inbound_head + self.inbound_count) % inbound_capacity;
        self.inbound[index] = copy;
        self.inbound_count += 1;
        self.condition.signal();
        self.mutex.unlock();
    }

    fn subscriptionSnapshot(self: *DaemonClient) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.allocator.dupe(u8, self.subscription_path);
    }

    fn publishState(self: *DaemonClient, state: Wire.ConnectionState, message: []const u8) void {
        self.mutex.lock();
        self.state = state;
        self.last_error = message;
        self.mutex.unlock();
    }

    fn trackRequest(self: *DaemonClient, request_id: *const [36]u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.pending_request_count == self.pending_request_ids.len) return false;
        self.pending_request_ids[self.pending_request_count] = request_id.*;
        self.pending_request_count += 1;
        return true;
    }

    fn completeRequest(self: *DaemonClient, request_id: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (request_id.len != 36) return false;
        for (self.pending_request_ids[0..self.pending_request_count], 0..) |pending, index| {
            if (std.ascii.eqlIgnoreCase(&pending, request_id)) {
                self.pending_request_count -= 1;
                if (index != self.pending_request_count) {
                    self.pending_request_ids[index] = self.pending_request_ids[self.pending_request_count];
                }
                return true;
            }
        }
        return false;
    }

    fn clearPendingRequests(self: *DaemonClient) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.pending_request_count = 0;
    }

    fn clearOutboundLocked(self: *DaemonClient) void {
        while (self.outbound_count != 0) {
            const command = self.outbound[self.outbound_head];
            self.outbound_head = (self.outbound_head + 1) % outbound_capacity;
            self.outbound_count -= 1;
            self.allocator.free(command);
        }
    }

    fn clearQueues(self: *DaemonClient) void {
        self.mutex.lock();
        self.clearOutboundLocked();
        while (self.inbound_count != 0) {
            const frame = self.inbound[self.inbound_head];
            self.inbound_head = (self.inbound_head + 1) % inbound_capacity;
            self.inbound_count -= 1;
            self.allocator.free(frame);
        }
        self.mutex.unlock();
    }

    fn closeHandleOnly(self: *DaemonClient) void {
        if (self.pipe != c.INVALID_HANDLE_VALUE) {
            _ = c.CloseHandle(self.pipe);
            self.pipe = c.INVALID_HANDLE_VALUE;
        }
        self.frame_buffer.reset();
    }
};

fn nowMilliseconds() i64 {
    return @intCast(std.time.milliTimestamp());
}

fn writeAll(handle: c.HANDLE, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        var overlapped = std.mem.zeroes(c.OVERLAPPED);
        overlapped.hEvent = c.CreateEventW(null, 1, 0, null);
        if (overlapped.hEvent == null) return error.WriteFailed;
        defer _ = c.CloseHandle(overlapped.hEvent);
        var written: c.DWORD = 0;
        const amount: c.DWORD = @intCast(@min(bytes.len - offset, std.math.maxInt(c.DWORD)));
        if (c.WriteFile(handle, bytes[offset..].ptr, amount, &written, &overlapped) == 0) {
            if (c.GetLastError() != c.ERROR_IO_PENDING) return error.WriteFailed;
            const wait_result = c.WaitForSingleObject(overlapped.hEvent, 50);
            if (wait_result == c.WAIT_TIMEOUT) {
                _ = c.CancelIoEx(handle, &overlapped);
                _ = c.GetOverlappedResult(handle, &overlapped, &written, 1);
                return error.WriteTimeout;
            }
            if (wait_result != c.WAIT_OBJECT_0) {
                return error.WriteFailed;
            }
            if (c.GetOverlappedResult(handle, &overlapped, &written, 0) == 0) {
                return error.WriteFailed;
            }
        }
        if (written == 0) return error.WriteFailed;
        offset += written;
    }
}

test "daemon client startup state fits the default stack" {
    try std.testing.expect(@sizeOf(DaemonClient) < 1024 * 1024);
}

test "new negotiations reset legacy fallback state to v2 framing" {
    const allocator = std.testing.allocator;
    var client = try DaemonClient.init(allocator);
    defer client.deinit();
    client.mode = .v1;
    client.selected_version = 1;
    client.frame_buffer.setMode(.v1);
    client.fallback_to_v1 = true;
    client.prepareV2Negotiation();
    try std.testing.expectEqual(Wire.ProtocolMode.v2, client.mode);
    try std.testing.expectEqual(Wire.current_version, client.selected_version);
    const header = try Wire.frameLength(&[_]u8{0} ** (Wire.v2_max_payload + 1), .v1);
    try std.testing.expectError(error.PayloadTooLarge, Wire.decodedLength(header, .v2));
}

test "successful hello switches a coalesced reconnect buffer back to v2" {
    const allocator = std.testing.allocator;
    var client = try DaemonClient.init(allocator);
    defer client.deinit();
    client.state = .negotiating;
    client.mode = .v1;
    client.frame_buffer.setMode(.v1);
    const hello = "{\"version\":2,\"kind\":\"hello\",\"selectedVersion\":2}";
    const hello_header = try Wire.frameLength(hello, .v1);
    const payload = "after-hello";
    const payload_header = try Wire.frameLength(payload, .v2);
    try client.frame_buffer.append(&hello_header);
    try client.frame_buffer.append(hello);
    try client.frame_buffer.append(&payload_header);
    try client.frame_buffer.append(payload);
    const hello_frame = (try client.frame_buffer.next(allocator)).?;
    defer allocator.free(hello_frame);
    try std.testing.expect(client.handleFrame(hello_frame));
    const payload_frame = (try client.frame_buffer.next(allocator)).?;
    defer allocator.free(payload_frame);
    try std.testing.expectEqualStrings(payload, payload_frame);
    try std.testing.expectEqual(Wire.ProtocolMode.v2, client.mode);
}

test "settings validation rejects missing directories, invalid secrets, and pipe syntax" {
    var client = try DaemonClient.init(std.testing.allocator);
    defer client.deinit();
    try std.testing.expectError(
        error.InvalidDaemonPipe,
        client.validateSettings("not-a-pipe", ""),
    );
    try std.testing.expectError(
        error.SupportDirectoryMissing,
        client.validateSettings("", "C:\\graphcode\\missing-support-directory"),
    );
    try std.testing.expectError(
        error.SupportSecretMissing,
        client.validateSettings("", "."),
    );
}

test "clearing support override ignores the old environment override" {
    const allocator = std.testing.allocator;
    const old_override = std.process.getEnvVarOwned(allocator, "GRAPHCODE_SUPPORT_DIR") catch null;
    const old_profile = std.process.getEnvVarOwned(allocator, "USERPROFILE") catch null;
    defer {
        setTestEnvironment("GRAPHCODE_SUPPORT_DIR", old_override);
        setTestEnvironment("USERPROFILE", old_profile);
        if (old_override) |value| allocator.free(value);
        if (old_profile) |value| allocator.free(value);
    }
    setTestEnvironment("GRAPHCODE_SUPPORT_DIR", "C:\\Windows");
    setTestEnvironment("USERPROFILE", "C:\\graphcode-missing-default");

    var client = try DaemonClient.init(allocator);
    defer client.deinit();
    try std.testing.expectError(
        error.SupportDirectoryMissing,
        client.validateSettings("", ""),
    );
}

fn setTestEnvironment(name: []const u8, value: ?[]const u8) void {
    const name_wide = utf8ToWide(std.heap.page_allocator, name) catch return;
    defer std.heap.page_allocator.free(name_wide);
    const value_wide = if (value) |text|
        (utf8ToWide(std.heap.page_allocator, text) catch return)
    else
        null;
    defer if (value_wide) |wide| std.heap.page_allocator.free(wide);
    _ = c.SetEnvironmentVariableW(name_wide.ptr, if (value_wide) |wide| wide.ptr else null);
}

fn setEnvironmentChecked(name: []const u8, value: ?[]const u8) !void {
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "GRAPHCODE_TEST_FAIL_SET_ENV")) |fail| {
        defer std.heap.page_allocator.free(fail);
        if (std.mem.eql(u8, fail, name)) return error.EnvironmentUpdateFailed;
    } else |_| {}
    const name_wide = try utf8ToWide(std.heap.page_allocator, name);
    defer std.heap.page_allocator.free(name_wide);
    const value_wide = if (value) |text| try utf8ToWide(std.heap.page_allocator, text) else null;
    defer if (value_wide) |wide| std.heap.page_allocator.free(wide);
    if (c.SetEnvironmentVariableW(name_wide.ptr, if (value_wide) |wide| wide.ptr else null) == 0)
        return error.EnvironmentUpdateFailed;
}

fn endpointName(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "GRAPHCODE_DAEMON_PIPE")) |override| {
        return override;
    } else |_| {}

    const support = try supportDirectory(allocator);
    defer allocator.free(support);
    return endpointNameFor(allocator, "", support);
}

fn endpointNameFor(
    allocator: std.mem.Allocator,
    pipe_override: []const u8,
    support: []const u8,
) ![]u8 {
    if (pipe_override.len != 0) return allocator.dupe(u8, pipe_override);
    const sid = try currentSID(allocator);
    defer allocator.free(sid);
    const support_identity = normalizedSupportPath(allocator, support) catch
        return error.EndpointHashFailed;
    defer allocator.free(support_identity);
    const support_hash = sha256Hex(allocator, support_identity) catch
        return error.EndpointHashFailed;
    defer allocator.free(support_hash);
    const secret_path = try std.fs.path.join(allocator, &.{ support, ".graphcode-rendezvous.secret" });
    defer allocator.free(secret_path);
    const secret = std.fs.cwd().readFileAlloc(allocator, secret_path, 4096) catch return error.EndpointSecretMissing;
    defer allocator.free(secret);
    const rendezvous_hash = sha256Hex(allocator, secret) catch return error.EndpointHashFailed;
    defer allocator.free(rendezvous_hash);
    return std.fmt.allocPrint(
        allocator,
        "\\\\.\\pipe\\graphcode-{s}-{s}-{s}",
        .{ sid, support_hash[0..24], rendezvous_hash[0..24] },
    );
}

fn supportDirectory(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "GRAPHCODE_SUPPORT_DIR")) |value| {
        defer allocator.free(value);
        return resolveSupportPath(allocator, value);
    } else |_| {}
    return defaultSupportDirectory(allocator);
}

fn supportDirectoryFor(allocator: std.mem.Allocator, submitted: []const u8) ![]u8 {
    if (submitted.len == 0) return defaultSupportDirectory(allocator);
    return resolveSupportPath(allocator, submitted);
}

fn defaultSupportDirectory(allocator: std.mem.Allocator) ![]u8 {
    const home = std.process.getEnvVarOwned(allocator, "USERPROFILE") catch
        return error.UserProfileMissing;
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".graphcode" });
}

fn resolveSupportPath(allocator: std.mem.Allocator, configured: []const u8) ![]u8 {
    const value = try allocator.dupe(u8, configured);
    if (isAbsoluteWindowsPath(value)) return value;
    const home = std.process.getEnvVarOwned(allocator, "USERPROFILE") catch
        return value;
    defer allocator.free(home);
    const joined = std.fs.path.join(allocator, &.{ home, value }) catch {
        return value;
    };
    allocator.free(value);
    return joined;
}

fn isAbsoluteWindowsPath(path: []const u8) bool {
    return (path.len >= 2 and path[1] == ':') or
        (path.len >= 2 and path[0] == '\\' and path[1] == '\\') or
        (path.len >= 2 and path[0] == '/' and path[1] == '/');
}

fn normalizedSupportPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const wide = try utf8ToWide(allocator, path);
    defer allocator.free(wide);
    var buffer: [32768]u16 = undefined;
    const length = c.GetFullPathNameW(wide.ptr, buffer.len, &buffer, null);
    if (length == 0 or length >= buffer.len) return error.SupportPathNormalizationFailed;
    const utf8 = try std.unicode.utf16LeToUtf8Alloc(allocator, buffer[0..length]);
    defer allocator.free(utf8);
    const result = try allocator.dupe(u8, utf8);
    for (result) |*byte| {
        if (byte.* >= 'A' and byte.* <= 'Z') byte.* += 'a' - 'A';
        if (byte.* == '\\') byte.* = '/';
    }
    return result;
}

fn currentSID(allocator: std.mem.Allocator) ![]u8 {
    var token: c.HANDLE = null;
    if (c.OpenProcessToken(c.GetCurrentProcess(), c.TOKEN_QUERY, &token) == 0) {
        return error.OpenProcessTokenFailed;
    }
    defer _ = c.CloseHandle(token);
    var required: c.DWORD = 0;
    _ = c.GetTokenInformation(token, c.TokenUser, null, 0, &required);
    if (required == 0) return error.TokenInformationFailed;
    const memory = try allocator.alloc(u8, required);
    defer allocator.free(memory);
    if (c.GetTokenInformation(token, c.TokenUser, memory.ptr, required, &required) == 0) {
        return error.TokenInformationFailed;
    }
    const token_user: *c.TOKEN_USER = @ptrCast(@alignCast(memory.ptr));
    var sid_text: c.LPWSTR = null;
    if (c.ConvertSidToStringSidW(token_user.User.Sid, &sid_text) == 0) {
        return error.SidConversionFailed;
    }
    defer _ = c.LocalFree(sid_text);
    return wideToUtf8(allocator, sid_text);
}

fn sha256Hex(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const result = try allocator.alloc(u8, 64);
    const alphabet = "0123456789abcdef";
    for (digest, 0..) |byte, index| {
        result[index * 2] = alphabet[byte >> 4];
        result[index * 2 + 1] = alphabet[byte & 0x0f];
    }
    return result;
}

test "support identity matches Swift standardized file URL hashing" {
    const allocator = std.testing.allocator;
    const normalized = try normalizedSupportPath(allocator, "C:\\Users\\Test User\\.graphcode");
    defer allocator.free(normalized);
    try std.testing.expectEqualStrings("c:/users/test user/.graphcode", normalized);

    const digest = try sha256Hex(allocator, normalized);
    defer allocator.free(digest);
    try std.testing.expectEqualStrings(
        "854409ec88ff68bd47d6f7d1c63e12e8d52fa8c695f28719df2c47e1fd1f0221",
        digest,
    );
}

test "response correlation accepts Swift uppercase UUID serialization" {
    const allocator = std.testing.allocator;
    var client = try DaemonClient.init(allocator);
    defer client.deinit();
    const lower = "00000000-0000-4000-8000-abcdef123456";
    var request_id: [36]u8 = undefined;
    @memcpy(&request_id, lower);
    try std.testing.expect(client.trackRequest(&request_id));
    try std.testing.expect(client.completeRequest("00000000-0000-4000-8000-ABCDEF123456"));
    try std.testing.expectEqual(@as(usize, 0), client.pending_request_count);
}

fn utf8ToWide(allocator: std.mem.Allocator, value: []const u8) ![]u16 {
    const raw = try std.unicode.utf8ToUtf16LeAlloc(allocator, value);
    defer allocator.free(raw);
    const result = try allocator.alloc(u16, raw.len + 1);
    @memcpy(result[0..raw.len], raw);
    result[raw.len] = 0;
    return result;
}

fn wideToUtf8(allocator: std.mem.Allocator, value: [*:0]const u16) ![]u8 {
    const slice = std.mem.sliceTo(value, 0);
    return std.unicode.utf16LeToUtf8Alloc(allocator, slice);
}

fn makeClientID(buffer: *[36]u8) void {
    makeRequestID(buffer, 0);
}

fn makeRequestID(buffer: *[36]u8, value: u64) void {
    const timestamp: u64 = @intCast(std.time.nanoTimestamp());
    const seed = timestamp ^ value;
    const result = std.fmt.bufPrint(
        buffer,
        "00000000-0000-4000-8000-{x:0>12}",
        .{seed & 0xffffffffffff},
    ) catch unreachable;
    _ = result;
}
