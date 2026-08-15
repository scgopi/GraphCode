const std = @import("std");
const FrameBuffer = @import("FrameBuffer.zig").FrameBuffer;
const Wire = @import("Wire.zig");
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

    allocator: std.mem.Allocator,
    pipe: c.HANDLE = c.INVALID_HANDLE_VALUE,
    pipe_name: []u8 = &.{},
    client_id: [36]u8 = undefined,
    mode: Wire.ProtocolMode = .v2,
    state: Wire.ConnectionState = .disconnected,
    selected_version: u8 = Wire.current_version,
    last_error: []const u8 = "",
    resume_from: u64 = 0,
    next_request: u64 = 1,
    pending_request_ids: [64][36]u8 = undefined,
    pending_request_count: usize = 0,
    subscription_path: []const u8 = "",
    frame_buffer: FrameBuffer = .{},
    retry_at_ms: i64 = 0,
    retry_delay_ms: i64 = reconnect_initial_ms,
    negotiation_deadline_ms: i64 = 0,
    fallback_to_v1: bool = false,
    callback: ?EventCallback = null,
    callback_context: ?*anyopaque = null,

    pub fn init(allocator: std.mem.Allocator) !DaemonClient {
        var client = DaemonClient{
            .allocator = allocator,
            .frame_buffer = FrameBuffer.init(.v2),
        };
        makeClientID(&client.client_id);
        client.pipe_name = endpointName(allocator) catch
            try allocator.dupe(u8, "\\\\.\\pipe\\graphcode-daemon-unavailable");
        return client;
    }

    pub fn deinit(self: *DaemonClient) void {
        self.close();
        if (self.pipe_name.len != 0) self.allocator.free(self.pipe_name);
        if (self.subscription_path.len != 0) self.allocator.free(self.subscription_path);
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
        if (std.mem.eql(u8, self.subscription_path, project_path)) return;
        const copy = self.allocator.dupe(u8, project_path) catch {
            self.last_error = "subscription allocation failed";
            return;
        };
        if (self.subscription_path.len != 0) self.allocator.free(self.subscription_path);
        self.subscription_path = copy;
        if (self.state == .connected) {
            self.closeHandleOnly();
            self.state = .reconnecting;
            self.connect();
        }
    }

    pub fn connect(self: *DaemonClient) void {
        if (self.state == .connected or self.state == .connecting or self.state == .negotiating) return;
        self.state = .connecting;
        self.last_error = "";
        self.clearPendingRequests();
        self.mode = .v2;
        self.frame_buffer.setMode(.v2);
        self.selected_version = Wire.current_version;
        self.fallback_to_v1 = false;
        self.retry_delay_ms = reconnect_initial_ms;
        self.retry_at_ms = 0;
        self.closeHandleOnly();
        if (endpointName(self.allocator)) |current| {
            if (!std.mem.eql(u8, current, self.pipe_name)) {
                self.allocator.free(self.pipe_name);
                self.pipe_name = current;
            } else {
                self.allocator.free(current);
            }
        } else |_| {}
    }

    pub fn reconnect(self: *DaemonClient) void {
        if (self.state == .disconnected) {
            self.connect();
        } else if (self.state != .connected) {
            self.retry_at_ms = 0;
            self.poll();
        }
    }

    pub fn close(self: *DaemonClient) void {
        self.closeHandleOnly();
        self.clearPendingRequests();
        self.state = .disconnected;
    }

    pub fn sendListProjects(self: *DaemonClient) void {
        const command = Wire.commandListRecentProjects(self.allocator) catch return;
        defer self.allocator.free(command);
        self.sendCommand(command);
    }

    pub fn sendRestoreOpenProjects(self: *DaemonClient) void {
        const command = Wire.commandRestoreOpenProjects(self.allocator) catch return;
        defer self.allocator.free(command);
        self.sendCommand(command);
    }

    pub fn sendOpenProject(self: *DaemonClient, path: []const u8) void {
        const command = Wire.commandOpenProject(self.allocator, path) catch return;
        defer self.allocator.free(command);
        self.sendCommand(command);
    }

    pub fn sendCreateNode(self: *DaemonClient, project_path: []const u8, title: []const u8) void {
        var node_id: [36]u8 = undefined;
        makeRequestID(&node_id, self.next_request);
        const command = Wire.commandGraphCreateNode(
            self.allocator,
            project_path,
            title,
            &node_id,
        ) catch return;
        defer self.allocator.free(command);
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
        defer self.allocator.free(command);
        self.sendCommand(command);
    }

    pub fn poll(self: *DaemonClient) void {
        const now = nowMilliseconds();
        switch (self.state) {
            .connecting, .reconnecting, .unavailable, .protocol_error => {
                if (now >= self.retry_at_ms) self.attemptConnection(now);
            },
            .negotiating, .connected => {
                if (!self.pumpIncoming()) return;
                if (self.state == .negotiating and now >= self.negotiation_deadline_ms) {
                    self.beginLegacyFallback(now);
                }
            },
            .disconnected => {},
        }
    }

    pub fn statusText(self: *const DaemonClient) []const u8 {
        if (self.last_error.len != 0) return self.last_error;
        return switch (self.state) {
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
        if (self.state != .connected) {
            self.last_error = "daemon unavailable; command not sent";
            return;
        }
        const frame = if (self.mode == .v2) blk: {
            var request_id: [36]u8 = undefined;
            makeRequestID(&request_id, self.next_request);
            self.next_request +%= 1;
            if (!self.trackRequest(&request_id)) {
                self.last_error = "too many outstanding daemon requests";
                return;
            }
            break :blk Wire.v2Request(
                self.allocator,
                &request_id,
                command_json,
            ) catch {
                self.last_error = "request encoding failed";
                return;
            };
        } else Wire.v1Command(self.allocator, command_json) catch {
            self.last_error = "request encoding failed";
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
                _ = c.WaitNamedPipeW(wide.ptr, 500);
            }
            return false;
        }
        self.pipe = handle;
        return true;
    }

    fn writeFrame(self: *DaemonClient, data: []const u8) !void {
        const header = try Wire.frameLength(data, self.mode);
        try writeAll(self.pipe, &header);
        try writeAll(self.pipe, data);
    }

    fn attemptConnection(self: *DaemonClient, now: i64) void {
        self.closeHandleOnly();
        if (!self.openPipe()) {
            self.scheduleRetry(now, "daemon unavailable; retrying");
            return;
        }
        self.frame_buffer.reset();
        if (self.fallback_to_v1) {
            self.state = .connected;
            self.fallback_to_v1 = false;
            self.retry_delay_ms = reconnect_initial_ms;
            self.last_error = "";
            return;
        }
        self.state = .negotiating;
        self.negotiation_deadline_ms = now + negotiation_timeout_ms;
        const hello = Wire.v2Hello(
            self.allocator,
            &self.client_id,
            if (self.resume_from == 0) null else self.resume_from,
            self.subscription_path,
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
        self.last_error = message;
        self.clearPendingRequests();
        self.closeHandleOnly();
        self.state = .reconnecting;
        self.retry_at_ms = nowMilliseconds() + self.retry_delay_ms;
        self.retry_delay_ms = @min(self.retry_delay_ms * 2, reconnect_max_ms);
    }

    fn markProtocolFailure(self: *DaemonClient, message: []const u8) void {
        self.last_error = message;
        self.clearPendingRequests();
        self.closeHandleOnly();
        self.state = .protocol_error;
        self.retry_at_ms = nowMilliseconds() + self.retry_delay_ms;
        self.retry_delay_ms = @min(self.retry_delay_ms * 2, reconnect_max_ms);
    }

    fn scheduleRetry(self: *DaemonClient, now: i64, message: []const u8) void {
        self.last_error = message;
        self.closeHandleOnly();
        self.frame_buffer.reset();
        self.state = .unavailable;
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
        self.state = .reconnecting;
        self.retry_at_ms = now;
    }

    fn handleFrame(self: *DaemonClient, frame: []const u8) bool {
        if (self.state == .negotiating) {
            if (Wire.looksLikeV2(frame) and
                std.mem.indexOf(u8, frame, "\"kind\":\"hello\"") != null and
                std.mem.indexOf(u8, frame, "\"selectedVersion\":2") != null)
            {
                self.mode = .v2;
                self.frame_buffer.setMode(.v2);
                self.selected_version = 2;
                self.state = .connected;
                self.retry_delay_ms = reconnect_initial_ms;
                self.last_error = "";
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
        if (self.callback) |callback| callback(self.callback_context, frame.ptr, frame.len);
        if (Wire.jsonNumber(frame, "sequence")) |sequence| self.resume_from = sequence;
        return true;
    }

    fn trackRequest(self: *DaemonClient, request_id: *const [36]u8) bool {
        if (self.pending_request_count == self.pending_request_ids.len) return false;
        self.pending_request_ids[self.pending_request_count] = request_id.*;
        self.pending_request_count += 1;
        return true;
    }

    fn completeRequest(self: *DaemonClient, request_id: []const u8) bool {
        if (request_id.len != 36) return false;
        for (self.pending_request_ids[0..self.pending_request_count], 0..) |pending, index| {
            if (std.mem.eql(u8, &pending, request_id)) {
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
        self.pending_request_count = 0;
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
            if (c.WaitForSingleObject(overlapped.hEvent, c.INFINITE) != c.WAIT_OBJECT_0) {
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

fn endpointName(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "GRAPHCODE_DAEMON_PIPE")) |override| {
        return override;
    } else |_| {}

    const sid = try currentSID(allocator);
    defer allocator.free(sid);
    const support = try supportDirectory(allocator);
    defer allocator.free(support);
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
        if (isAbsoluteWindowsPath(value)) return value;
        const home = std.process.getEnvVarOwned(allocator, "USERPROFILE") catch
            return value;
        defer allocator.free(home);
        const joined = std.fs.path.join(allocator, &.{ home, value }) catch {
            return value;
        };
        allocator.free(value);
        return joined;
    } else |_| {}
    const home = std.process.getEnvVarOwned(allocator, "USERPROFILE") catch
        return error.UserProfileMissing;
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".graphcode" });
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
        if (byte.* == '/') byte.* = '\\';
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
