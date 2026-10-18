const std = @import("std");
const FrameBuffer = @import("FrameBuffer.zig").FrameBuffer;
const Wire = @import("Wire.zig");
const Forms = @import("Forms.zig");
const SketchPromotion = @import("SketchPromotion.zig");
const Diagnostics = @import("Diagnostics.zig");
const c = @import("Win32.zig").c;
const ReconnectDecision = enum { none, ready, drain_timeout };
// statusText's borrowed notice must not change underneath its caller on the worker.
threadlocal var negotiation_status_buffer: [256]u8 = undefined;

test "sketch promotion real outbound queue matches Swift fixtures for every variant" {
    const allocator = std.testing.allocator;
    var client = try DaemonClient.initUnstartedForTest(allocator);
    defer client.deinit();
    var model = @import("GraphModel.zig").Model.init(allocator);
    defer model.deinit();
    _ = try model.updateFromFrame(
        \\{"graphChanged":{"project":{"path":"C:\\work\\graph","name":"Graph"},"nodes":[{"id":"11111111-1111-4111-8111-111111111111","title":"Sketch","loopType":"sketch"}],"edges":[]}}
    );
    var context = try SketchPromotion.Context.capture(allocator, &model, model.graph.?.project.path, "", model.graph.?.nodes.items[0]);
    defer context.deinit(allocator);
    const drafts = [_]SketchPromotion.Draft{ .{ .goal = "Done \"well\" \u{96ea}" }, .{ .turn = true }, .{ .timed = "/loop 1h watch \"\u{96ea}\"" } };
    for (drafts, [_][]const u8{ "goal", "turn", "timed" }, 0..) |draft, name, index| {
        try std.testing.expect(try client.sendSketchPromotion(&model, context, draft));
        const envelope = try Wire.v2Request(allocator, "00000000-0000-4000-8000-000000000025", client.outbound[index]);
        defer allocator.free(envelope);
        const path = try std.fmt.allocPrint(allocator, "fixtures\\daemon-v2-promote-{s}.json", .{name});
        defer allocator.free(path);
        const fixture = try std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024);
        defer allocator.free(fixture);
        try std.testing.expectEqualStrings(std.mem.trim(u8, fixture, "\r\n"), std.mem.trim(u8, envelope, "\r\n"));
        const v1 = try Wire.v1Command(allocator, client.outbound[index]);
        defer allocator.free(v1);
        try std.testing.expect(std.mem.indexOf(u8, v1, "\"promoteNode\"") != null);
        _ = try Wire.frameLength(envelope, .v2);
    }
    try std.testing.expectEqual(@as(usize, 3), client.outbound_count);
    try std.testing.expect(client.worker == null);
}

test "sketch promotion sender refuses changed type deletion foreign scope and invalid data without retargeting" {
    const allocator = std.testing.allocator;
    var client = try DaemonClient.initUnstartedForTest(allocator);
    defer client.deinit();
    var model = @import("GraphModel.zig").Model.init(allocator);
    defer model.deinit();
    const frame =
        \\{"graphChanged":{"project":{"path":"A","name":"A"},"nodes":[{"id":"same","title":"Sketch","loopType":"sketch","firstInstruction":"original"},{"id":"other","title":"Other","loopType":"sketch"}],"edges":[]}}
    ;
    _ = try model.updateFromFrame(frame);
    var context = try SketchPromotion.Context.capture(allocator, &model, "A", "", model.graph.?.nodes.items[0]);
    defer context.deinit(allocator);
    try std.testing.expectError(error.MissingGoal, client.sendSketchPromotion(&model, context, .{ .goal = "\u{2003}\n" }));
    try std.testing.expectError(error.MissingCadence, client.sendSketchPromotion(&model, context, .{ .timed = " " }));
    try std.testing.expect(model.setSelectedID("other"));
    try std.testing.expectError(error.PromotionContextChanged, client.sendSketchPromotion(&model, context, .{ .turn = false }));
    try std.testing.expectEqualStrings("other", model.selectedNodeID().?);
    try std.testing.expect(model.setSelectedID("same"));
    client.setSubgraphAddress("other");
    try std.testing.expectError(error.PromotionContextChanged, client.sendSketchPromotion(&model, context, .{ .turn = false }));
    try std.testing.expectEqualStrings("other", client.subgraph_node_id);
    client.setSubgraphAddress(null);
    _ = try model.updateFromFrame(
        \\{"graphChanged":{"project":{"path":"B","name":"B"},"nodes":[{"id":"same","title":"Foreign","loopType":"sketch"}],"edges":[]}}
    );
    try std.testing.expect(model.selectProject("B"));
    try std.testing.expectError(error.PromotionContextChanged, client.sendSketchPromotion(&model, context, .{ .turn = false }));
    try std.testing.expectEqualStrings("B", model.graph.?.project.path);
    try std.testing.expect(model.selectProject("A"));
    _ = try model.updateFromFrame(
        \\{"graphChanged":{"project":{"path":"A","name":"A"},"nodes":[{"id":"same","title":"Changed","loopType":"turnBased"}],"edges":[]}}
    );
    try std.testing.expectError(error.NotSketch, client.sendSketchPromotion(&model, context, .{ .turn = false }));
    try std.testing.expectEqualStrings("original", context.first_instruction);
    try std.testing.expectEqualStrings("Sketch", context.title);
    _ = try model.updateFromFrame(
        \\{"graphChanged":{"project":{"path":"A","name":"A"},"nodes":[],"edges":[]}}
    );
    try std.testing.expectError(error.PromotionNodeMissing, client.sendSketchPromotion(&model, context, .{ .turn = false }));
    try std.testing.expect(!try client.sendSketchPromotion(&model, context, null));
    try std.testing.expectEqual(@as(usize, 0), client.outbound_count);
}

test "sketch promotion sender preserves composite address and cleans every serialization allocation" {
    const allocator = std.testing.allocator;
    var model = @import("GraphModel.zig").Model.init(allocator);
    defer model.deinit();
    _ = try model.updateFromFrame(
        \\{"graphChanged":{"project":{"path":"A","name":"A"},"nodes":[{"id":"group","title":"Group","loopType":"proactive","subGraph":{"project":{"path":"A","name":"A"},"nodes":[{"id":"child","title":"Sketch","loopType":"sketch"}],"edges":[]}}],"edges":[]}}
    );
    try std.testing.expect(model.openComposite("group"));
    var context = try SketchPromotion.Context.capture(allocator, &model, "A", "group", model.graph.?.nodes.items[0]);
    defer context.deinit(allocator);
    try std.testing.expect(model.setSelectedID("child"));
    const Probe = struct {
        fn run(test_allocator: std.mem.Allocator, current: *const @import("GraphModel.zig").Model, captured: SketchPromotion.Context) !void {
            var client = try DaemonClient.initUnstartedForTest(test_allocator);
            defer client.deinit();
            client.subgraph_node_id = try test_allocator.dupe(u8, "group");
            for ([_]SketchPromotion.Draft{ .{ .goal = "done" }, .{ .turn = false }, .{ .timed = "/loop 1h work" } }) |draft| {
                try std.testing.expect(try client.sendSketchPromotion(current, captured, draft));
            }
            try std.testing.expect(std.mem.indexOf(u8, client.outbound[0], "\"subGraphCommand\":{\"nodeID\":\"group\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, client.outbound[0], "\"_0\":\"child\"") != null);
            try std.testing.expectEqualStrings("group", client.subgraph_node_id);
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Probe.run, .{ &model, context });
    var client = try DaemonClient.initUnstartedForTest(allocator);
    defer client.deinit();
    client.setSubgraphAddress("group");
    for (0..DaemonClient.outbound_capacity) |_| try std.testing.expect(try client.sendSketchPromotion(&model, context, .{ .turn = false }));
    try std.testing.expectError(error.PromotionQueueFull, client.sendSketchPromotion(&model, context, .{ .turn = true }));
    try std.testing.expectEqual(@as(usize, DaemonClient.outbound_capacity), client.outbound_count);
}

test "sketch promotion test client has a fixed synthetic endpoint and inactive transport" {
    var client = try DaemonClient.initUnstartedForTest(std.testing.allocator);
    defer client.deinit();
    try std.testing.expectEqualStrings("\\\\.\\pipe\\graphcode-sketch-promotion-unit-test-not-connected", client.pipe_name);
    try std.testing.expectEqualStrings("00000000-0000-4000-8000-000000000025", &client.client_id);
    try std.testing.expect(client.worker == null);
    try std.testing.expect(!client.want_connected);
    try std.testing.expect(client.pipe == c.INVALID_HANDLE_VALUE);
    try std.testing.expectEqual(Wire.ConnectionState.disconnected, client.state);
    try std.testing.expectEqual(@as(usize, 0), client.outbound_count);
    try std.testing.expectEqual(@as(usize, 0), client.inbound_count);
}

test "client-generated node ids on the create-node wire are random version-4 UUIDs" {
    const allocator = std.testing.allocator;
    var client = try DaemonClient.initUnstartedForTest(allocator);
    defer client.deinit();
    client.sendCreateNodeConfigured("C:\\work\\graph", "Loop", "claudeCode", null);
    client.sendCreateNodeDraft("C:\\work\\graph", .{ .title = "" });
    try std.testing.expectEqual(@as(usize, 2), client.outbound_count);
    var ids: [2][]const u8 = undefined;
    for (client.outbound[0..2], &ids) |command, *id| {
        const marker = "\"createNode\":{\"_0\":{\"id\":\"";
        const start = (std.mem.indexOf(u8, command, marker) orelse return error.MissingNodeId) + marker.len;
        id.* = command[start .. start + 36];
        try std.testing.expect(Forms.isUuid(id.*));
        try std.testing.expectEqual(@as(u8, '4'), id.*[14]);
        try std.testing.expect(!std.mem.startsWith(u8, id.*, "00000000-0000-4000-8000-"));
    }
    try std.testing.expect(!std.mem.eql(u8, ids[0], ids[1]));
}

pub const EventCallback = *const fn (
    context: ?*anyopaque,
    frame: [*]const u8,
    length: usize,
) callconv(.c) void;

pub const DaemonClient = struct {
    const V1Expectation = enum { recent_projects, graph_changed };
    const LegacyFallbackReason = enum {
        v1_reply,
        selected_v1,
        unsupported_version,

        fn text(self: LegacyFallbackReason) []const u8 {
            return switch (self) {
                .v1_reply => "v1-shaped reply",
                .selected_v1 => "daemon selected v1",
                .unsupported_version => "daemon refused v2 (unsupportedVersion)",
            };
        }
    };
    const FallbackNotice = struct {
        reason: LegacyFallbackReason,
        elapsed_ms: u64,

        fn text(self: FallbackNotice, buffer: *[256]u8, connected: bool) []const u8 {
            return std.fmt.bufPrint(
                buffer,
                "{s}v2 -> v1: {s} after {d} ms",
                .{ if (connected) "Connected · protocol v1 · " else "", self.reason.text(), self.elapsed_ms },
            ) catch unreachable;
        }
    };
    const reconnect_initial_ms: i64 = 100;
    const reconnect_max_ms: i64 = 4_000;
    const negotiation_timeout_ms: i64 = 5_000;
    const subscription_drain_timeout_ms: i64 = 1_500;
    const outbound_capacity: usize = 64;
    const inbound_capacity: usize = 128;

    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    worker: ?std.Thread = null,
    stop_worker: bool = false,
    want_connected: bool = false,
    reconnect_requested: bool = false,
    subscription_reconnect_requested: bool = false,
    subscription_reconnect_deadline_ms: i64 = 0,
    retry_now: bool = false,
    outbound: [outbound_capacity][]u8 = undefined,
    outbound_request_ids: [outbound_capacity]? [36]u8 = [_]? [36]u8{null} ** outbound_capacity,
    outbound_expectations: [outbound_capacity]V1Expectation = [_]V1Expectation{.graph_changed} ** outbound_capacity,
    outbound_head: usize = 0,
    outbound_count: usize = 0,
    worker_busy: bool = false,
    inbound: [inbound_capacity][]u8 = undefined,
    inbound_generations: [inbound_capacity]u64 = [_]u64{0} ** inbound_capacity,
    inbound_head: usize = 0,
    inbound_count: usize = 0,
    connection_generation: u64 = 0,
    /// A connection has been established at least once, and again after an earlier one ended.
    ever_connected: bool = false,
    reconnected: bool = false,
    delivering_generation: u64 = 0,
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
    v1_pending_count: usize = 0,
    v1_pending_expectation: ?V1Expectation = null,
    subscription_path: []const u8 = "",
    subgraph_node_id: []const u8 = "",
    frame_buffer: FrameBuffer,
    retry_at_ms: i64 = 0,
    retry_delay_ms: i64 = reconnect_initial_ms,
    negotiation_started_ms: i64 = 0,
    negotiation_deadline_ms: i64 = 0,
    fallback_to_v1: bool = false,
    fallback_notice: ?FallbackNotice = null,
    callback: ?EventCallback = null,
    callback_context: ?*anyopaque = null,
    command_recorder: ?*const fn (*DaemonClient, []const u8) void = recordUiaCommand,

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

    pub fn initUnstartedForTest(allocator: std.mem.Allocator) !DaemonClient {
        comptime {
            if (!@import("builtin").is_test) @compileError("initUnstartedForTest is only available to tests");
        }
        var client = DaemonClient{
            .allocator = allocator,
            .frame_buffer = try FrameBuffer.init(allocator, .v2),
            .client_id = "00000000-0000-4000-8000-000000000025".*,
        };
        errdefer client.frame_buffer.deinit();
        client.pipe_name = try allocator.dupe(u8, "\\\\.\\pipe\\graphcode-sketch-promotion-unit-test-not-connected");
        return client;
    }

    pub fn start(self: *DaemonClient) !void {
        self.worker = try std.Thread.spawn(.{}, workerMain, .{self});
    }

    pub fn initForTesting(allocator: std.mem.Allocator) !DaemonClient {
        if (!@import("builtin").is_test) @compileError("test-only client construction");
        var client = DaemonClient{
            .allocator = allocator,
            .frame_buffer = try FrameBuffer.init(allocator, .v2),
            .client_id = "00000000-0000-4000-8000-000000000001".*,
            .command_recorder = null,
        };
        errdefer client.frame_buffer.deinit();
        client.pipe_name = try allocator.dupe(u8, "\\\\.\\pipe\\edge-edit-inert");
        return client;
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
        if (self.subgraph_node_id.len != 0) self.allocator.free(self.subgraph_node_id);
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
        if (!self.subscription_reconnect_requested) {
            self.subscription_reconnect_deadline_ms = nowMilliseconds() + subscription_drain_timeout_ms;
        }
        self.subscription_reconnect_requested = true;
        self.retry_now = true;
        self.state = .reconnecting;
        self.last_error = "";
        self.condition.signal();
        self.mutex.unlock();
    }

    pub fn setSubgraphAddress(self: *DaemonClient, node_id: ?[]const u8) void {
        const replacement = if (node_id) |value|
            self.allocator.dupe(u8, value) catch return
        else
            &.{};
        if (self.subgraph_node_id.len != 0) self.allocator.free(self.subgraph_node_id);
        self.subgraph_node_id = replacement;
    }

    pub fn subscriptionPath(self: *DaemonClient, allocator: std.mem.Allocator) ![]u8 {
        return self.subscriptionSnapshotWithAllocator(allocator);
    }

    pub fn validateSettings(
        self: *DaemonClient,
        pipe_override: []const u8,
        support_directory: []const u8,
    ) !void {
        _ = self;
        const allocator = std.heap.page_allocator;
        if (pipe_override.len != 0 and
            (!std.mem.startsWith(u8, pipe_override, "\\\\.\\pipe\\") or pipe_override.len > 240))
            return error.InvalidDaemonPipe;
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

    /// Returns a stable probe for supervisor startup when the daemon has not
    /// created the rendezvous secret yet.
    pub fn currentDaemonStartupEndpoint(self: *DaemonClient, allocator: std.mem.Allocator) ![]u8 {
        _ = self;
        return startupEndpointName(allocator);
    }

    pub fn currentDaemonLockName(self: *DaemonClient, allocator: std.mem.Allocator) ![]u8 {
        _ = self;
        return daemonLockName(allocator);
    }

    pub fn currentDaemonTaskName(self: *DaemonClient, allocator: std.mem.Allocator) ![]u8 {
        _ = self;
        return daemonTaskName(allocator);
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
        self.subscription_reconnect_requested = false;
        self.subscription_reconnect_deadline_ms = 0;
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

    pub fn sendOpenProject(self: *DaemonClient, path: []const u8) ?[36]u8 {
        if (self.protocolMode() == .v1 and !self.v1OpenReady()) return null;
        const command = Wire.commandOpenProject(self.allocator, path) catch return null;
        var request_id: [36]u8 = undefined;
        _ = self.allocateRequestID(&request_id);
        if (!self.sendCommandWithRequestID(command, request_id)) return null;
        return request_id;
    }

    pub fn sendCloseProject(self: *DaemonClient, path: []const u8) void {
        const command = Wire.commandCloseProject(self.allocator, path) catch return;
        self.sendCommand(command);
    }

    pub fn sendForgetProject(self: *DaemonClient, path: []const u8) void {
        const command = Wire.commandForgetProject(self.allocator, path) catch return;
        self.sendCommand(command);
    }

    pub fn sendDeleteProjectGraph(self: *DaemonClient, path: []const u8) void {
        const command = Wire.commandDeleteProjectGraph(self.allocator, path) catch return;
        self.sendCommand(command);
    }

    pub fn v1OpenReady(self: *DaemonClient) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.mode != .v1 or
            (self.outbound_count == 0 and !self.worker_busy and self.v1_pending_expectation == null);
    }

    pub fn sendListQuickChats(self: *DaemonClient) void {
        const command = Wire.commandListQuickChats(self.allocator) catch return;
        self.sendCommand(command);
    }

    pub fn sendCreateQuickChat(self: *DaemonClient, title: []const u8, backend: []const u8) void {
        const command = Wire.commandCreateQuickChat(self.allocator, title, backend) catch return;
        self.sendCommand(command);
    }

    pub fn sendOpenQuickChat(self: *DaemonClient, id: []const u8) void {
        const command = Wire.commandOpenQuickChat(self.allocator, id) catch return;
        self.sendCommand(command);
    }

    pub fn sendRenameQuickChat(self: *DaemonClient, id: []const u8, title: []const u8) void {
        const command = Wire.commandRenameQuickChat(self.allocator, id, title) catch return;
        self.sendCommand(command);
    }

    pub fn sendDeleteQuickChat(self: *DaemonClient, id: []const u8) void {
        const command = Wire.commandDeleteQuickChat(self.allocator, id) catch return;
        self.sendCommand(command);
    }

    pub fn sendCreateNode(self: *DaemonClient, project_path: []const u8, title: []const u8) void {
        self.sendCreateNodeConfigured(project_path, title, "claudeCode", null);
    }

    pub fn sendCreateNodeConfigured(
        self: *DaemonClient,
        project_path: []const u8,
        title: []const u8,
        backend: []const u8,
        model_tier: ?[]const u8,
    ) void {
        var node_id: [36]u8 = undefined;
        Forms.generateDraftId(&node_id);
        const command = Wire.commandGraphCreateNodeConfigured(
            self.allocator,
            project_path,
            title,
            &node_id,
            backend,
            model_tier,
        ) catch return;
        self.sendCommand(command);
    }

    pub fn sendCreateNodeDraft(
        self: *DaemonClient,
        project_path: []const u8,
        draft: Forms.NodeDraft,
    ) void {
        var generated_id: [36]u8 = undefined;
        // A draft that ingested an attachment already chose its id before the dialog
        // opened (`Forms.generateDraftId`, threaded through `NativeForms.node`) — the
        // attachment bytes are already filed under that id on disk, so the node this
        // creates has to carry the same one. Everything else keeps the historical
        // generate-at-send-time id.
        const node_id: []const u8 = if (draft.node_id.len != 0) draft.node_id else blk: {
            Forms.generateDraftId(&generated_id);
            break :blk &generated_id;
        };
        const command = Wire.commandGraphCreateNodeFull(self.allocator, project_path, node_id, draft) catch {
            self.publishState(self.connectionState(), "create node command encoding failed");
            return;
        };
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

    pub fn sendNodeActionChecked(
        self: *DaemonClient,
        project_path: []const u8,
        node_id: []const u8,
        action: []const u8,
        text: ?[]const u8,
    ) !void {
        const command = try Wire.commandGraphNodeAction(self.allocator, project_path, node_id, action, text);
        try self.sendCommandChecked(command);
    }

    pub fn sendDetachTemplate(self: *DaemonClient, project_path: []const u8, node_id: []const u8) void {
        const command = Wire.commandGraphDetachTemplate(self.allocator, project_path, node_id) catch {
            self.publishState(self.connectionState(), "detach template command encoding failed");
            return;
        };
        self.sendCommand(command);
    }

    pub fn sendSidebarRootOrder(
        self: *DaemonClient,
        project_path: []const u8,
        node_ids: []const []const u8,
    ) void {
        const command = Wire.commandGraphSidebarNodesReordered(self.allocator, project_path, node_ids) catch {
            self.publishState(self.connectionState(), "sidebar root order command encoding failed");
            return;
        };
        self.sendCommand(command);
    }

    pub fn sendRenameNode(self: *DaemonClient, project_path: []const u8, node_id: []const u8, title: []const u8) void {
        const command = Wire.commandGraphRenameNode(self.allocator, project_path, node_id, title) catch {
            self.publishState(self.connectionState(), "rename node command encoding failed");
            return;
        };
        self.sendCommand(command);
    }

    pub fn sendDeleteNode(self: *DaemonClient, project_path: []const u8, node_id: []const u8) void {
        const command = Wire.commandGraphDeleteNode(self.allocator, project_path, node_id) catch {
            self.publishState(self.connectionState(), "delete node command encoding failed");
            return;
        };
        self.sendCommand(command);
    }

    pub fn sendDeleteEdge(self: *DaemonClient, project_path: []const u8, edge_id: []const u8) void {
        const command = Wire.commandGraphDeleteEdge(self.allocator, project_path, edge_id) catch {
            self.publishState(self.connectionState(), "delete edge command encoding failed");
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

    pub fn sendCreateEdgeDraft(
        self: *DaemonClient,
        project_path: []const u8,
        draft: Forms.EdgeDraft,
    ) void {
        const command = Wire.commandGraphCreateEdgeFull(
            self.allocator, project_path, draft.from, draft.to, draft,
        ) catch {
            self.publishState(self.connectionState(), "create edge command encoding failed");
            return;
        };
        self.sendCommand(command);
    }

    pub fn sendUpdateEdge(
        self: *DaemonClient,
        project_path: []const u8,
        edge_id: []const u8,
        from: []const u8,
        to: []const u8,
        expected: Forms.EdgeConfiguration,
        replacement: Forms.EdgeConfiguration,
        subgraph_address: []const u8,
    ) !void {
        if (!std.mem.eql(u8, self.subgraph_node_id, subgraph_address)) return error.StaleScope;
        const command = try Wire.commandGraphUpdateEdge(self.allocator, project_path, edge_id, from, to, expected, replacement);
        try self.sendCommandChecked(command);
    }

    pub fn sendPilotComposite(self: *DaemonClient, project_path: []const u8, node_id: []const u8) void {
        const command = Wire.commandGraphPilotComposite(self.allocator, project_path, node_id) catch return;
        self.sendCommand(command);
    }

    pub fn sendArmComposite(self: *DaemonClient, project_path: []const u8, node_id: []const u8) void {
        const command = Wire.commandGraphArmComposite(self.allocator, project_path, node_id) catch return;
        self.sendCommand(command);
    }

    pub fn sendRefreshUsage(self: *DaemonClient, project_path: []const u8) void {
        const command = Wire.commandGraphRefreshUsage(self.allocator, project_path) catch return;
        self.sendCommand(command);
    }

    pub fn sendMemoNode(
        self: *DaemonClient,
        project_path: []const u8,
        node_id: []const u8,
        text: []const u8,
        from: ?[]const u8,
    ) void {
        const command = Wire.commandGraphMemoNode(self.allocator, project_path, node_id, text, from) catch return;
        self.sendCommand(command);
    }

    pub fn sendUpdateNode(
        self: *DaemonClient,
        project_path: []const u8,
        node_id: []const u8,
        update_json: []const u8,
    ) void {
        const command = Wire.commandGraphUpdateNode(self.allocator, project_path, node_id, update_json) catch return;
        self.sendCommand(command);
    }

    pub fn sendUpdateNodeForm(
        self: *DaemonClient,
        project_path: []const u8,
        node_id: []const u8,
        update: Forms.NodeUpdate,
    ) void {
        const command = Wire.commandGraphUpdateNodeForm(self.allocator, project_path, node_id, update) catch return;
        self.sendCommand(command);
    }

    pub fn sendSketchPromotion(
        self: *DaemonClient,
        model: *const @import("GraphModel.zig").Model,
        context: SketchPromotion.Context,
        draft: ?SketchPromotion.Draft,
    ) !bool {
        const promotion = draft orelse return false;
        try context.validateCurrent(model, self.subgraph_node_id);
        if (!std.mem.eql(u8, model.selectedNodeID() orelse "", context.node_id))
            return error.PromotionContextChanged;
        const command = try Wire.commandGraphPromoteNode(self.allocator, context.project_path, context.node_id, promotion);
        const addressed = if (context.composite_id.len != 0) blk: {
            defer self.allocator.free(command);
            break :blk try Wire.addressGraphCommandToSubGraph(self.allocator, command, context.composite_id);
        } else command;
        // This is queue insertion, not daemon acceptance or persistence.
        if (!self.sendCommandInternal(addressed, null)) return error.PromotionQueueFull;
        return true;
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
            self.delivering_generation = self.inbound_generations[self.inbound_head];
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

    pub fn protocolMode(self: *DaemonClient) Wire.ProtocolMode {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.mode;
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
        if (client.mode == .v1 and (client.state == .connected or client.state == .reconnecting)) {
            if (client.fallback_notice) |notice| {
                return notice.text(&negotiation_status_buffer, client.state == .connected);
            }
        }
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

    fn expectationForCommand(command_json: []const u8) V1Expectation {
        if (std.mem.indexOf(u8, command_json, "\"listRecentProjects\"") != null or
            std.mem.indexOf(u8, command_json, "\"restoreOpenProjects\"") != null)
            return .recent_projects;
        return .graph_changed;
    }

    fn sendCommand(self: *DaemonClient, command_json: []u8) void {
        self.sendCommandChecked(command_json) catch {};
    }

    fn sendCommandChecked(self: *DaemonClient, command_json: []u8) !void {
        var addressed = command_json;
        if (self.subgraph_node_id.len != 0 and
            std.mem.indexOf(u8, command_json, "\"graphCommand\"") != null)
        {
            addressed = Wire.addressGraphCommandToSubGraph(
                self.allocator,
                command_json,
                self.subgraph_node_id,
            ) catch |err| {
                self.allocator.free(command_json);
                self.mutex.lock();
                self.last_error = "unable to address composite graph command";
                self.mutex.unlock();
                return err;
            };
            self.allocator.free(command_json);
        }
        if (self.command_recorder) |record| record(self, addressed);
        if (!self.sendCommandInternal(addressed, null)) return error.OutboundQueueRejected;
    }

    fn sendCommandWithRequestID(self: *DaemonClient, command_json: []u8, request_id: [36]u8) bool {
        if (self.command_recorder) |record| record(self, command_json);
        return self.sendCommandInternal(command_json, request_id);
    }

    fn recordUiaCommand(self: *DaemonClient, command_json: []const u8) void {
        const log_path = std.process.getEnvVarOwned(self.allocator, "GRAPHCODE_UIA_DAEMON_COMMAND_LOG") catch return;
        defer self.allocator.free(log_path);
        var file = std.fs.createFileAbsolute(log_path, .{ .truncate = true }) catch return;
        defer file.close();
        file.writeAll(command_json) catch {};
    }

    fn sendCommandInternal(self: *DaemonClient, command_json: []u8, request_id: ?[36]u8) bool {
        self.mutex.lock();
        if (self.stop_worker or self.outbound_count == outbound_capacity) {
            self.last_error = "daemon outbound queue is full";
            self.mutex.unlock();
            self.allocator.free(command_json);
            return false;
        }
        const index = (self.outbound_head + self.outbound_count) % outbound_capacity;
        self.outbound[index] = @constCast(command_json);
        self.outbound_request_ids[index] = request_id;
        self.outbound_expectations[index] = expectationForCommand(command_json);
        self.outbound_count += 1;
        self.condition.signal();
        self.mutex.unlock();
        return true;
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
            const retry_immediately = self.retry_now;
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

            const reconnect_decision = self.takeReconnect(nowMilliseconds());
            if (reconnect_decision != .none) {
                self.closeHandleOnly();
                self.clearPendingRequests();
                self.retry_at_ms = nowMilliseconds();
                self.retry_delay_ms = reconnect_initial_ms;
                self.publishState(
                    .reconnecting,
                    if (reconnect_decision == .drain_timeout) "daemon subscription drain timed out" else "",
                );
            }
            if (retry_immediately) self.retry_at_ms = 0;

            const now = nowMilliseconds();
            if (self.pipe == c.INVALID_HANDLE_VALUE and now >= self.retry_at_ms) {
                self.attemptConnection(now);
            }

            if (self.pipe != c.INVALID_HANDLE_VALUE) {
                if (!self.pumpIncoming()) continue;
                if (self.state == .negotiating and nowMilliseconds() >= self.negotiation_deadline_ms) {
                    var detail: [128]u8 = undefined;
                    const message = std.fmt.bufPrint(&detail, "v2 hello timed out after {d} ms; retrying v2", .{
                        self.negotiationElapsed(nowMilliseconds()),
                    }) catch unreachable;
                    Diagnostics.record(self.allocator, "daemon-negotiation", message);
                    self.markTransportFailure("daemon v2 hello timed out; retrying v2");
                }
            }

            if (self.pipe != c.INVALID_HANDLE_VALUE and self.state == .connected) {
                if (self.dequeueOutbound()) |outbound| {
                    self.sendCommandOnWorker(outbound.command, outbound.request_id, outbound.expectation);
                    self.allocator.free(outbound.command);
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

    fn takeReconnect(self: *DaemonClient, now: i64) ReconnectDecision {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.reconnect_requested and !self.subscription_reconnect_requested) return .none;
        var decision: ReconnectDecision = .ready;
        const pending = self.pending_request_count != 0 or self.v1_pending_expectation != null or self.worker_busy;
        // A subscription change must not abandon replies already being written by the daemon.
        if (!self.reconnect_requested and self.pipe != c.INVALID_HANDLE_VALUE and pending) {
            if (now < self.subscription_reconnect_deadline_ms) return .none;
            decision = .drain_timeout;
        }
        self.reconnect_requested = false;
        self.subscription_reconnect_requested = false;
        self.subscription_reconnect_deadline_ms = 0;
        return decision;
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

    const OutboundCommand = struct {
        command: []u8,
        request_id: ?[36]u8,
        expectation: V1Expectation,
    };

    fn dequeueOutbound(self: *DaemonClient) ?OutboundCommand {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.outbound_count == 0) return null;
        if (self.mode == .v1 and self.v1_pending_expectation != null) return null;
        const command = self.outbound[self.outbound_head];
        const request_id = self.outbound_request_ids[self.outbound_head];
        const expectation = self.outbound_expectations[self.outbound_head];
        self.outbound_request_ids[self.outbound_head] = null;
        self.outbound_head = (self.outbound_head + 1) % outbound_capacity;
        self.outbound_count -= 1;
        self.worker_busy = true;
        return .{ .command = command, .request_id = request_id, .expectation = expectation };
    }

    fn sendCommandOnWorker(
        self: *DaemonClient,
        command_json: []const u8,
        requested_id: ?[36]u8,
        expectation: V1Expectation,
    ) void {
        var tracked_id: ?[36]u8 = null;
        const frame = if (self.mode == .v2) blk: {
            var request_id: [36]u8 = undefined;
            if (requested_id) |value| {
                request_id = value;
            } else {
                _ = self.allocateRequestID(&request_id);
            }
            // Encode first: a request that cannot be encoded must leave nothing pending.
            const encoded = Wire.v2Request(
                self.allocator,
                &request_id,
                command_json,
            ) catch {
                self.publishState(self.state, "request encoding failed");
                return;
            };
            if (!self.trackRequest(&request_id)) {
                self.allocator.free(encoded);
                self.publishState(self.state, "too many outstanding daemon requests");
                return;
            }
            tracked_id = request_id;
            break :blk encoded;
        } else Wire.v1Command(self.allocator, command_json) catch {
            self.publishState(self.state, "request encoding failed");
            return;
        };
        defer self.allocator.free(frame);
        self.writeFrame(frame) catch {
            if (tracked_id) |request_id| _ = self.completeRequest(&request_id);
            self.markTransportFailure("daemon write failed");
            return;
        };
        if (self.mode == .v1) {
            self.mutex.lock();
            self.v1_pending_count += 1;
            self.v1_pending_expectation = expectation;
            self.mutex.unlock();
        }
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
            self.mutex.lock();
            self.mode = .v1;
            self.selected_version = 1;
            self.mutex.unlock();
            self.publishState(.connected, "");
            self.fallback_to_v1 = false;
            self.retry_delay_ms = reconnect_initial_ms;
            return;
        }
        self.publishState(.negotiating, "");
        self.negotiation_started_ms = nowMilliseconds();
        self.negotiation_deadline_ms = self.negotiation_started_ms + negotiation_timeout_ms;
        const hello = self.helloFrame(self.allocator) catch {
            self.scheduleRetry(now, "daemon hello encoding failed");
            return;
        };
        defer self.allocator.free(hello);
        self.writeFrame(hello) catch {
            self.scheduleRetry(now, "daemon hello write failed");
            return;
        };
    }

    /// The shell is a sidebar client (`restoreOpenProjects`): every open project's rows
    /// and Needs-you entries must stay live, so the hello never narrows delivery to the
    /// focused project. `subscription_path` only records that focus and still triggers
    /// the drained re-dial whose restore resynchronizes every open project.
    fn helloFrame(self: *DaemonClient, allocator: std.mem.Allocator) ![]u8 {
        return Wire.v2Hello(
            allocator,
            &self.client_id,
            if (self.resume_from == 0) null else self.resume_from,
            "",
        );
    }

    fn prepareV2Negotiation(self: *DaemonClient) void {
        self.mutex.lock();
        self.mode = .v2;
        self.selected_version = Wire.current_version;
        self.mutex.unlock();
        self.frame_buffer.setMode(.v2);
    }

    fn pumpIncoming(self: *DaemonClient) bool {
        return self.pumpIncomingWithWait(.{});
    }

    const IncomingReadWait = struct {
        context: ?*anyopaque = null,
        wait: *const fn (?*anyopaque, c.HANDLE, c.DWORD) c.DWORD = waitForRead,

        fn waitForRead(_: ?*anyopaque, event: c.HANDLE, milliseconds: c.DWORD) c.DWORD {
            return c.WaitForSingleObject(event, milliseconds);
        }
    };

    fn pumpIncomingWithWait(self: *DaemonClient, read_wait: IncomingReadWait) bool {
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
                    const wait_result = read_wait.wait(read_wait.context, overlapped.hEvent, 20);
                    const cancel = wait_result != c.WAIT_OBJECT_0;
                    if (cancel) _ = c.CancelIoEx(self.pipe, &overlapped);
                    // A completion can beat cancellation; join it before using or discarding bytes.
                    const result = c.GetOverlappedResult(self.pipe, &overlapped, &read, if (cancel) 1 else 0);
                    const result_error = if (result == 0) c.GetLastError() else c.ERROR_SUCCESS;
                    if (wait_result != c.WAIT_OBJECT_0 and wait_result != c.WAIT_TIMEOUT) {
                        self.markTransportFailure("daemon read wait failed");
                        return false;
                    }
                    if (result == 0) {
                        if (result_error == c.ERROR_OPERATION_ABORTED and read == 0) break;
                        if (result_error != c.ERROR_OPERATION_ABORTED) {
                            self.markTransportFailure("daemon frame read failed");
                            return false;
                        }
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

    fn negotiationElapsed(self: *const DaemonClient, now: i64) u64 {
        return @intCast(@max(0, now -| self.negotiation_started_ms));
    }

    fn beginLegacyFallback(self: *DaemonClient, now: i64, reason: LegacyFallbackReason) void {
        self.closeHandleOnly();
        self.frame_buffer.setMode(.v1);
        self.clearPendingRequests();
        const notice = FallbackNotice{ .reason = reason, .elapsed_ms = self.negotiationElapsed(now) };
        self.mutex.lock();
        self.mode = .v1;
        self.selected_version = 1;
        self.fallback_notice = notice;
        self.mutex.unlock();
        self.fallback_to_v1 = true;
        self.publishState(.reconnecting, "");
        var detail: [256]u8 = undefined;
        Diagnostics.record(self.allocator, "daemon-negotiation", notice.text(&detail, false));
        self.retry_at_ms = now;
    }

    const NegotiationReply = union(enum) { v2, legacy: LegacyFallbackReason };

    fn negotiationReply(self: *DaemonClient, frame: []const u8) !NegotiationReply {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, frame, .{});
        defer parsed.deinit();
        const root = parsed.value;
        if (root != .object) return error.InvalidNegotiationReply;
        if (root.object.get("version")) |version| {
            if (version != .integer or version.integer != 2) return error.InvalidNegotiationReply;
            const kind = root.object.get("kind") orelse return error.InvalidNegotiationReply;
            if (kind != .string) return error.InvalidNegotiationReply;
            if (std.mem.eql(u8, kind.string, "hello")) {
                const selected = root.object.get("selectedVersion") orelse return error.InvalidNegotiationReply;
                if (selected != .integer) return error.InvalidNegotiationReply;
                return switch (selected.integer) {
                    2 => .v2,
                    1 => .{ .legacy = .selected_v1 },
                    else => error.InvalidNegotiationReply,
                };
            }
            if (std.mem.eql(u8, kind.string, "error")) {
                const refusal = root.object.get("error") orelse return error.InvalidNegotiationReply;
                if (refusal != .object) return error.InvalidNegotiationReply;
                const code = refusal.object.get("code") orelse return error.InvalidNegotiationReply;
                if (code == .string and std.mem.eql(u8, code.string, "unsupportedVersion"))
                    return .{ .legacy = .unsupported_version };
            }
            return error.InvalidNegotiationReply;
        }
        // Swift's v1 DaemonEvent is a single enum-case key, not a v2 envelope.
        if (root.object.count() == 1) {
            inline for (.{
                "recentProjectsListed", "graphChanged", "quickChatsListed", "quickChatChanged",
                "quickChatDeleted", "quickChatActivity", "errorOccurred", "mailbox", "nodesChanged",
            }) |name| {
                if (root.object.get(name)) |payload| {
                    if (payload == .object) return .{ .legacy = .v1_reply };
                }
            }
        }
        return error.InvalidNegotiationReply;
    }

    fn handleFrame(self: *DaemonClient, frame: []const u8) bool {
        if (self.state == .negotiating) {
            const reply = self.negotiationReply(frame) catch {
                self.markProtocolFailure("invalid daemon negotiation reply");
                return false;
            };
            switch (reply) {
                .v2 => {
                    self.mutex.lock();
                    self.mode = .v2;
                    self.selected_version = 2;
                    self.fallback_notice = null;
                    self.mutex.unlock();
                    self.fallback_to_v1 = false;
                    self.frame_buffer.setModePreservingData(.v2);
                    self.publishState(.connected, "");
                    self.retry_delay_ms = reconnect_initial_ms;
                },
                .legacy => |reason| self.beginLegacyFallback(nowMilliseconds(), reason),
            }
            return true;
        }
        if (self.mode == .v2) {
            if (Wire.correlatedRequestID(frame)) |request_id| {
                if (!self.completeRequest(request_id)) {
                    self.markProtocolFailure("unmatched daemon response");
                    return false;
                }
            }
        }
        if (self.mode == .v1) {
            self.mutex.lock();
            const expected = self.v1_pending_expectation;
            const kind = Wire.eventKind(frame);
            if (expected != null and
                (kind == .error_occurred or
                    (expected.? == .recent_projects and kind == .recent_projects) or
                    (expected.? == .graph_changed and kind == .graph_changed)))
            {
                self.v1_pending_expectation = null;
                self.v1_pending_count = 0;
            }
            self.mutex.unlock();
        }
        self.enqueueInbound(frame);
        if (Wire.jsonNumber(frame, "sequence")) |sequence| self.resume_from = sequence;
        return true;
    }

    /// Public so shell tests can queue a frame stamped with the generation it arrives on.
    pub fn enqueueInbound(self: *DaemonClient, frame: []const u8) void {
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
        self.inbound_generations[index] = self.connection_generation;
        self.inbound_count += 1;
        self.condition.signal();
        self.mutex.unlock();
    }

    fn subscriptionSnapshot(self: *DaemonClient) ![]u8 {
        return self.subscriptionSnapshotWithAllocator(self.allocator);
    }

    fn subscriptionSnapshotWithAllocator(self: *DaemonClient, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return allocator.dupe(u8, self.subscription_path);
    }

test "subscription can be restored after a rejected project open" {
    var client = try DaemonClient.init(std.testing.allocator);
    defer client.deinit();
    client.setSubscription("C:\\old-project");
    const previous = try client.subscriptionSnapshot();
    defer std.testing.allocator.free(previous);
    client.setSubscription("C:\\rejected-project");
    client.setSubscription(previous);
    const restored = try client.subscriptionSnapshot();
    defer std.testing.allocator.free(restored);
    try std.testing.expectEqualStrings("C:\\old-project", restored);
}

test "open project returns the request ID used by the v2 envelope" {
    var client = try DaemonClient.init(std.testing.allocator);
    defer client.deinit();
    const request_id = client.sendOpenProject("C:\\work\\C").?;
    try std.testing.expectEqual(@as(usize, 1), client.outbound_count);
    try std.testing.expect(std.mem.eql(
        u8,
        &client.outbound_request_ids[client.outbound_head].?,
        &request_id,
    ));
    const frame = try Wire.v2Request(
        std.testing.allocator,
        &request_id,
        client.outbound[client.outbound_head],
    );
    defer std.testing.allocator.free(frame);
    try std.testing.expectEqualStrings(&request_id, Wire.responseRequestID(frame).?);
}

const ReadCapture = struct {
    var frames: [8][512]u8 = undefined;
    var lengths: [8]usize = [_]usize{0} ** 8;
    var generations: [8]u64 = [_]u64{0} ** 8;
    var count: usize = 0;
    var client: ?*DaemonClient = null;

    fn reset(target: *DaemonClient) void {
        count = 0;
        client = target;
        target.setCallback(onFrame, null);
    }

    fn onFrame(_: ?*anyopaque, frame: [*]const u8, length: usize) callconv(.c) void {
        if (count == frames.len) return;
        @memcpy(frames[count][0..length], frame[0..length]);
        lengths[count] = length;
        generations[count] = client.?.deliveringGeneration();
        count += 1;
    }

    fn at(index: usize) []const u8 {
        return frames[index][0..lengths[index]];
    }
};

test "read project graph is v2 and connected only, and sends the read-only command" {
    var client = try DaemonClient.initForTesting(std.testing.allocator);
    defer client.deinit();
    try std.testing.expect(client.sendReadProjectGraph("C:\\work\\A") == null);
    try std.testing.expectEqual(@as(usize, 0), client.outbound_count);
    client.publishState(.connected, "");
    client.mode = .v1;
    try std.testing.expect(client.sendReadProjectGraph("C:\\work\\A") == null);
    try std.testing.expectEqual(@as(usize, 0), client.outbound_count);
    client.mode = .v2;
    const read = client.sendReadProjectGraph("C:\\work\\A").?;
    try std.testing.expectEqual(client.connectionGeneration(), read.generation);
    try std.testing.expectEqual(@as(usize, 1), client.outbound_count);
    try std.testing.expectEqualStrings(
        "{\"readProjectGraph\":{\"path\":\"C:\\\\work\\\\A\"}}",
        client.outbound[client.outbound_head],
    );
    try std.testing.expectEqualSlices(u8, &read.request_id, &client.outbound_request_ids[client.outbound_head].?);
    const second = client.sendReadProjectGraph("C:\\work\\A").?;
    try std.testing.expect(!std.mem.eql(u8, &read.request_id, &second.request_id));
}

test "read project graph reports a full outbound queue as not sent" {
    var client = try DaemonClient.initForTesting(std.testing.allocator);
    defer client.deinit();
    client.publishState(.connected, "");
    for (&client.outbound) |*slot| slot.* = try std.testing.allocator.dupe(u8, "");
    client.outbound_count = outbound_capacity;
    try std.testing.expect(client.sendReadProjectGraph("C:\\work\\A") == null);
}

test "connection generation changes on every entry to connected and only then" {
    var client = try DaemonClient.initForTesting(std.testing.allocator);
    defer client.deinit();
    try std.testing.expectEqual(@as(u64, 0), client.connectionGeneration());
    client.publishState(.connected, "");
    const first = client.connectionGeneration();
    client.publishState(.connected, "");
    try std.testing.expectEqual(first, client.connectionGeneration());
    client.publishState(.reconnecting, "");
    try std.testing.expectEqual(first, client.connectionGeneration());
    client.publishState(.connected, "");
    try std.testing.expect(client.connectionGeneration() != first);
}

test "a connected generation exists only while the client is connected" {
    var client = try DaemonClient.initForTesting(std.testing.allocator);
    defer client.deinit();
    try std.testing.expect(client.connectedGeneration() == null);
    client.publishState(.connected, "");
    try std.testing.expectEqual(client.connectionGeneration(), client.connectedGeneration().?);
    // A failure moves the state but not the generation.
    client.publishState(.reconnecting, "");
    try std.testing.expect(client.connectedGeneration() == null);
    const failed_on = client.connectionGeneration();
    client.publishState(.connected, "");
    try std.testing.expect(client.connectedGeneration().? != failed_on);
}

test "a reconnect is recorded when the connection is established, once, and stays recorded" {
    var client = try DaemonClient.initForTesting(std.testing.allocator);
    defer client.deinit();
    try std.testing.expect(!client.hasReconnected());
    // Startup with the daemon down, then up: still the first connection.
    client.publishState(.connecting, "");
    client.publishState(.unavailable, "");
    client.publishState(.connecting, "");
    client.publishState(.connected, "");
    client.publishState(.connected, "");
    try std.testing.expect(!client.hasReconnected());

    // The daemon dies and returns before anything polls: the transition itself records it.
    client.publishState(.reconnecting, "");
    try std.testing.expect(!client.hasReconnected());
    client.publishState(.connected, "");
    try std.testing.expect(client.hasReconnected());
    client.connection_generation = std.math.maxInt(u64);
    client.publishState(.reconnecting, "");
    client.publishState(.connected, "");
    try std.testing.expectEqual(@as(u64, 0), client.connectionGeneration());
    try std.testing.expect(client.hasReconnected());
}

test "a correlated response and an uncorrelated snapshot are told apart on real envelopes" {
    var client = try DaemonClient.initForTesting(std.testing.allocator);
    defer client.deinit();
    client.publishState(.connected, "");
    ReadCapture.reset(&client);
    const read = client.sendReadProjectGraph("C:\\work\\A").?;
    try std.testing.expect(client.trackRequest(&read.request_id));
    const graph = "{\"graphChanged\":{\"project\":{\"path\":\"C:/work/A\"},\"nodes\":[" ++
        "{\"title\":\"\\\"kind\\\":\\\"response\\\",\\\"requestID\\\":\\\"x\\\"\",\"kind\":\"response\"}]}}";
    try std.testing.expect(client.handleFrame("{\"version\":2,\"kind\":\"event\",\"sequence\":7,\"event\":" ++ graph ++ "}"));
    const response = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"version\":2,\"kind\":\"response\",\"requestID\":\"{s}\",\"event\":{s}}}",
        .{ read.request_id, graph },
    );
    defer std.testing.allocator.free(response);
    try std.testing.expect(client.handleFrame(response));
    client.poll();
    try std.testing.expectEqual(@as(usize, 2), ReadCapture.count);
    try std.testing.expectEqual(Wire.FrameKind.event, Wire.frameKind(ReadCapture.at(0)));
    try std.testing.expect(Wire.correlatedRequestID(ReadCapture.at(0)) == null);
    try std.testing.expectEqual(Wire.FrameKind.response, Wire.frameKind(ReadCapture.at(1)));
    try std.testing.expectEqualStrings(&read.request_id, Wire.correlatedRequestID(ReadCapture.at(1)).?);
    try std.testing.expectEqual(read.generation, ReadCapture.generations[1]);
    try std.testing.expectEqual(@as(usize, 0), client.pending_request_count);
}

test "request ids minted by concurrent producers are all distinct" {
    var client = try DaemonClient.initForTesting(std.testing.allocator);
    defer client.deinit();
    const threads = 4;
    const each = 250;
    const Worker = struct {
        fn run(owner: *DaemonClient, out: *[each][36]u8) void {
            for (out) |*slot| _ = owner.allocateRequestID(slot);
        }
    };
    var ids: [threads][each][36]u8 = undefined;
    var handles: [threads]std.Thread = undefined;
    for (&handles, 0..) |*handle, index| handle.* = try std.Thread.spawn(.{}, Worker.run, .{ &client, &ids[index] });
    for (handles) |handle| handle.join();
    var seen = std.StringHashMap(void).init(std.testing.allocator);
    defer seen.deinit();
    for (&ids) |*group| {
        for (group) |*id| {
            const entry = try seen.getOrPut(id);
            try std.testing.expect(!entry.found_existing);
        }
    }
    try std.testing.expectEqual(@as(u32, threads * each), seen.count());
}

test "public producers and the worker allocation never draw the same request id" {
    var client = try DaemonClient.initForTesting(std.testing.allocator);
    defer client.deinit();
    client.publishState(.connected, "");
    client.mode = .v2;
    const producers = 2;
    const sends = 20;
    const worker_draws = 200;
    const Shared = struct {
        client: *DaemonClient,
        ready: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        go: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        fn arrive(self: *@This()) void {
            _ = self.ready.fetchAdd(1, .acq_rel);
            while (!self.go.load(.acquire)) std.Thread.yield() catch {};
        }
        fn produce(self: *@This()) void {
            self.arrive();
            for (0..sends) |index| {
                var path_buffer: [16]u8 = undefined;
                const path = std.fmt.bufPrint(&path_buffer, "C:\\p{d}", .{index}) catch return;
                _ = self.client.sendReadProjectGraph(path);
            }
        }
    };
    var shared: Shared = .{ .client = &client };
    var handles: [producers]std.Thread = undefined;
    for (&handles) |*handle| handle.* = try std.Thread.spawn(.{}, Shared.produce, .{&shared});
    while (shared.ready.load(.acquire) != producers) std.Thread.yield() catch {};
    shared.go.store(true, .release);
    var drawn: [worker_draws][36]u8 = undefined;
    for (&drawn) |*slot| _ = client.allocateRequestID(slot);
    for (handles) |handle| handle.join();

    var seen = std.StringHashMap(void).init(std.testing.allocator);
    defer seen.deinit();
    for (&drawn) |*id| try std.testing.expect(!(try seen.getOrPut(id)).found_existing);
    try std.testing.expectEqual(@as(usize, producers * sends), client.outbound_count);
    for (client.outbound_request_ids[0..client.outbound_count]) |*maybe| {
        try std.testing.expect(!(try seen.getOrPut(&maybe.*.?)).found_existing);
    }
}
test "a request that cannot be encoded leaves nothing pending" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var client = try DaemonClient.initForTesting(failing.allocator());
    defer client.deinit();
    client.publishState(.connected, "");
    client.mode = .v2;
    failing.fail_index = failing.alloc_index;
    client.sendCommandOnWorker("{\"listRecentProjects\":{}}", null, .graph_changed);
    try std.testing.expectEqual(@as(usize, 0), client.pending_request_count);
}

    test "lane 9 checked node action reports encoding allocation and queue rejection without double freeing" {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var client = try DaemonClient.initForTesting(failing.allocator());
        defer client.deinit();
        try std.testing.expectError(error.UnsupportedGraphAction, client.sendNodeActionChecked("A", "loop", "restartEverything", null));
        try std.testing.expectEqual(@as(usize, 0), client.outbound_count);
        failing.fail_index = failing.alloc_index;
        try std.testing.expectError(error.OutOfMemory, client.sendNodeActionChecked("A", "loop", "restartNode", null));
        try std.testing.expectEqual(@as(usize, 0), client.outbound_count);
        failing.fail_index = std.math.maxInt(usize);
        for (0..outbound_capacity) |_| try client.sendNodeActionChecked("A", "loop", "restartNode", null);
        try std.testing.expectError(error.OutboundQueueRejected, client.sendNodeActionChecked("A", "loop", "restartNode", null));
        try std.testing.expectEqual(outbound_capacity, client.outbound_count);
    }

    test "lane 9 checked node action retains the existing composite addressing path" {
        var client = try DaemonClient.initForTesting(std.testing.allocator);
        defer client.deinit();
        client.setSubgraphAddress("group");
        try client.sendNodeActionChecked("A", "worker", "restartNode", null);
        try std.testing.expectEqual(@as(usize, 1), client.outbound_count);
        const command = client.outbound[client.outbound_head];
        try std.testing.expect(std.mem.indexOf(u8, command, "\"restartNode\":{\"_0\":\"worker\"}") != null);
        try std.testing.expect(std.mem.indexOf(u8, command, "\"group\"") != null);
    }

test "an event that merely carries a requestID does not complete a pending request" {
    var client = try DaemonClient.initForTesting(std.testing.allocator);
    defer client.deinit();
    client.publishState(.connected, "");
    const read = client.sendReadProjectGraph("C:\\work\\A").?;
    try std.testing.expect(client.trackRequest(&read.request_id));
    const spoof = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"version\":2,\"kind\":\"event\",\"sequence\":3,\"requestID\":\"{s}\",\"event\":{{\"graphChanged\":{{\"project\":{{\"path\":\"C:/work/A\"}},\"nodes\":[]}}}}}}",
        .{read.request_id},
    );
    defer std.testing.allocator.free(spoof);
    try std.testing.expect(client.handleFrame(spoof));
    try std.testing.expectEqual(@as(usize, 1), client.pending_request_count);
    const response = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"version\":2,\"kind\":\"response\",\"requestID\":\"{s}\",\"event\":{{\"graphChanged\":{{\"project\":{{\"path\":\"C:/work/A\"}},\"nodes\":[]}}}}}}",
        .{read.request_id},
    );
    defer std.testing.allocator.free(response);
    try std.testing.expect(client.handleFrame(response));
    try std.testing.expectEqual(@as(usize, 0), client.pending_request_count);
}

test "an error envelope for the request correlates and an unknown-command error is not a response" {
    var client = try DaemonClient.initForTesting(std.testing.allocator);
    defer client.deinit();
    client.publishState(.connected, "");
    ReadCapture.reset(&client);
    const read = client.sendReadProjectGraph("C:\\work\\A").?;
    try std.testing.expect(client.trackRequest(&read.request_id));
    const failure = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"version\":2,\"kind\":\"error\",\"requestID\":\"{s}\",\"error\":" ++
            "{{\"code\":\"malformedEnvelope\",\"message\":\"unknown command\"}}}}",
        .{read.request_id},
    );
    defer std.testing.allocator.free(failure);
    try std.testing.expect(client.handleFrame(failure));
    client.poll();
    try std.testing.expectEqual(@as(usize, 1), ReadCapture.count);
    try std.testing.expectEqual(Wire.FrameKind.@"error", Wire.frameKind(ReadCapture.at(0)));
    try std.testing.expectEqualStrings(&read.request_id, Wire.correlatedRequestID(ReadCapture.at(0)).?);
}

test "a frame is stamped with the generation it arrived on even if polled after a reconnect" {
    var client = try DaemonClient.initForTesting(std.testing.allocator);
    defer client.deinit();
    client.publishState(.connected, "");
    ReadCapture.reset(&client);
    const arrived = client.connectionGeneration();
    try std.testing.expect(client.handleFrame("{\"version\":2,\"kind\":\"event\",\"sequence\":1,\"event\":{\"graphChanged\":{}}}"));
    client.publishState(.reconnecting, "");
    client.publishState(.connected, "");
    client.poll();
    try std.testing.expectEqual(@as(usize, 1), ReadCapture.count);
    try std.testing.expectEqual(arrived, ReadCapture.generations[0]);
    try std.testing.expect(client.connectionGeneration() != arrived);
}

test "v1 open waits for all earlier commands and retains retry on full queue" {
    var client = try DaemonClient.init(std.testing.allocator);
    defer client.deinit();
    client.mode = .v1;
    client.v1_pending_count = 1;
    client.v1_pending_expectation = .graph_changed;
    try std.testing.expect(!client.v1OpenReady());
    try std.testing.expect(client.sendOpenProject("C:\\work\\B") == null);
    client.v1_pending_count = 0;
    for (&client.outbound) |*slot| slot.* = try std.testing.allocator.dupe(u8, "");
    client.outbound_count = outbound_capacity;
    try std.testing.expect(client.sendOpenProject("C:\\work\\C") == null);
}

test "v1 response accounting ignores unsolicited events before the expected result" {
    var client = try DaemonClient.init(std.testing.allocator);
    defer client.deinit();
    client.mode = .v1;
    client.state = .connected;
    client.v1_pending_count = 1;
    client.v1_pending_expectation = .graph_changed;
    try std.testing.expect(client.handleFrame(
        "{\"version\":1,\"kind\":\"event\",\"event\":{\"recentProjectsListed\":[]}}",
    ));
    try std.testing.expectEqual(@as(usize, 1), client.v1_pending_count);
    try std.testing.expect(client.handleFrame(
        "{\"version\":1,\"kind\":\"event\",\"event\":{\"attentionChanged\":{}}}",
    ));
    try std.testing.expectEqual(@as(usize, 1), client.v1_pending_count);
    try std.testing.expect(client.handleFrame(
        "{\"version\":1,\"kind\":\"event\",\"event\":{\"errorOccurred\":\"rejected\"}}",
    ));
    try std.testing.expectEqual(@as(usize, 0), client.v1_pending_count);
}

    fn publishState(self: *DaemonClient, state: Wire.ConnectionState, message: []const u8) void {
        self.mutex.lock();
        if (state == .connected and self.state != .connected) {
            self.connection_generation +%= 1;
            if (self.ever_connected) self.reconnected = true;
            self.ever_connected = true;
        }
        self.state = state;
        self.last_error = message;
        self.mutex.unlock();
    }

    /// Whether a connection was ever established after an earlier one. Sticky, recorded at the
    /// state transition itself, so it does not depend on how often anything polls and does not
    /// wrap: a first connection that comes up late (the daemon was down at startup) is still
    /// the first.
    pub fn hasReconnected(self: *DaemonClient) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.reconnected;
    }

    /// Identifies one established connection: it changes every time the client enters
    /// `.connected`, so anything that must not outlive a disconnect (a reply awaited, a
    /// look at the daemon's graph) can be fenced against it.
    pub fn connectionGeneration(self: *DaemonClient) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.connection_generation;
    }

    /// The generation of the current connection, or null unless the client is connected, read
    /// under one lock. State and generation read separately can straddle a failure.
    pub fn connectedGeneration(self: *DaemonClient) ?u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return if (self.state == .connected) self.connection_generation else null;
    }

    /// The generation the frame being delivered by `poll` was received on. Only
    /// meaningful inside the event callback.
    pub fn deliveringGeneration(self: *DaemonClient) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.delivering_generation;
    }

    pub const GraphRead = struct {
        request_id: [36]u8,
        generation: u64,
    };

    /// Asks the daemon for the current graph of a project this connection has already
    /// opened (`readProjectGraph`): one correlated response, no side effect, no event.
    /// Null when it cannot be sent as such — not v2, not connected, or the queue is
    /// full — and then nothing was queued. The caller keeps the returned id and
    /// generation and accepts only a reply that matches both.
    pub fn sendReadProjectGraph(self: *DaemonClient, path: []const u8) ?GraphRead {
        const command = Wire.commandReadProjectGraph(self.allocator, path) catch return null;
        var request_id: [36]u8 = undefined;
        var generation: u64 = 0;
        if (!self.allocateRequestIDIfConnected(&request_id, &generation)) {
            self.allocator.free(command);
            return null;
        }
        if (!self.sendCommandWithRequestID(command, request_id)) return null;
        return .{ .request_id = request_id, .generation = generation };
    }

    /// Request ids are only ever minted by these two helpers, under the queue mutex, so a
    /// caller's thread and the writer thread can never draw the same counter value.
    fn allocateRequestID(self: *DaemonClient, buffer: *[36]u8) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.mintLocked(buffer);
    }

    /// Mints an id only for a connected v2 client, and reports the connection generation
    /// it was minted on, in the same critical section.
    fn allocateRequestIDIfConnected(self: *DaemonClient, buffer: *[36]u8, generation: *u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.mode != .v2 or self.state != .connected) return false;
        generation.* = self.connection_generation;
        _ = self.mintLocked(buffer);
        return true;
    }

    fn mintLocked(self: *DaemonClient, buffer: *[36]u8) u64 {
        const value = self.next_request;
        makeRequestID(buffer, value);
        self.next_request +%= 1;
        return value;
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
        self.v1_pending_count = 0;
        self.v1_pending_expectation = null;
    }

    fn clearOutboundLocked(self: *DaemonClient) void {
        while (self.outbound_count != 0) {
            const index = self.outbound_head;
            const command = self.outbound[index];
            self.outbound_head = (self.outbound_head + 1) % outbound_capacity;
            self.outbound_count -= 1;
            self.outbound_request_ids[index] = null;
            self.outbound_expectations[index] = .graph_changed;
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

test "subscription reconnect drains correlated responses before closing the connection" {
    var client = try DaemonClient.init(std.testing.allocator);
    defer client.deinit();
    client.pipe = c.CreateEventW(null, 1, 0, null);
    try std.testing.expect(client.pipe != null);
    defer client.closeHandleOnly();
    client.state = .connected;
    var request_id: [36]u8 = undefined;
    makeRequestID(&request_id, 1);
    try std.testing.expect(client.trackRequest(&request_id));

    client.setSubscription("C:\\next-project");
    try std.testing.expectEqual(ReconnectDecision.none, client.takeReconnect(nowMilliseconds()));
    try std.testing.expectEqual(@as(usize, 1), client.pending_request_count);
    const response = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"version\":2,\"kind\":\"response\",\"requestID\":\"{s}\",\"success\":true}}",
        .{request_id},
    );
    defer std.testing.allocator.free(response);
    try std.testing.expect(client.handleFrame(response));
    try std.testing.expectEqual(@as(usize, 0), client.pending_request_count);
    try std.testing.expectEqual(ReconnectDecision.ready, client.takeReconnect(nowMilliseconds()));
    try std.testing.expectEqual(ReconnectDecision.none, client.takeReconnect(nowMilliseconds()));
}

test "subscription drain is bounded and an explicit reconnect bypasses it" {
    var client = try DaemonClient.init(std.testing.allocator);
    defer client.deinit();
    client.pipe = c.CreateEventW(null, 1, 0, null);
    try std.testing.expect(client.pipe != null);
    defer client.closeHandleOnly();
    client.state = .connected;
    client.pending_request_count = 1;
    client.setSubscription("C:\\next-project");
    try std.testing.expectEqual(ReconnectDecision.none, client.takeReconnect(nowMilliseconds()));
    try std.testing.expectEqual(ReconnectDecision.drain_timeout, client.takeReconnect(std.math.maxInt(i64)));

    client.setSubscription("C:\\another-project");
    client.reconnect();
    try std.testing.expectEqual(ReconnectDecision.ready, client.takeReconnect(nowMilliseconds()));
}

test "closing the client cancels a deferred subscription reconnect" {
    var client = try DaemonClient.init(std.testing.allocator);
    defer client.deinit();
    client.pending_request_count = 1;
    client.setSubscription("C:\\next-project");
    client.close();
    try std.testing.expectEqual(ReconnectDecision.none, client.takeReconnect(nowMilliseconds()));
}

test "repeated subscription changes do not extend the drain deadline" {
    var client = try DaemonClient.init(std.testing.allocator);
    defer client.deinit();
    client.setSubscription("C:\\first-project");
    const deadline = client.subscription_reconnect_deadline_ms;
    client.setSubscription("C:\\latest-project");
    try std.testing.expectEqual(deadline, client.subscription_reconnect_deadline_ms);
    try std.testing.expectEqualStrings("C:\\latest-project", client.subscription_path);
}

test "subscription reconnect also waits for legacy response accounting" {
    var client = try DaemonClient.init(std.testing.allocator);
    defer client.deinit();
    client.pipe = c.CreateEventW(null, 1, 0, null);
    try std.testing.expect(client.pipe != null);
    defer client.closeHandleOnly();
    client.mode = .v1;
    client.state = .connected;
    client.v1_pending_count = 1;
    client.v1_pending_expectation = .graph_changed;
    client.setSubscription("C:\\next-project");
    try std.testing.expectEqual(ReconnectDecision.none, client.takeReconnect(nowMilliseconds()));
    try std.testing.expect(client.handleFrame(
        "{\"version\":1,\"kind\":\"event\",\"event\":{\"graphChanged\":{}}}",
    ));
    try std.testing.expectEqual(ReconnectDecision.ready, client.takeReconnect(nowMilliseconds()));
}

/// Mirrors GraphcodeKit's `DaemonConnectionChannel.isSubscribed`: a hello without a
/// subscription admits every project the connection joined; one with `projectPaths`
/// admits only the listed projects.
fn daemonAdmitsProjectEvents(hello: []const u8, project_path: []const u8) !bool {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, hello, .{});
    defer parsed.deinit();
    const subscription = parsed.value.object.get("subscription") orelse return true;
    const paths = subscription.object.get("projectPaths") orelse return true;
    for (paths.array.items) |path| {
        if (std.mem.eql(u8, path.string, project_path)) return true;
    }
    return false;
}

test "opening a second project keeps the first project's live graph events admitted" {
    var client = try DaemonClient.init(std.testing.allocator);
    defer client.deinit();
    client.setSubscription("C:\\GraphCode-Fixtures\\Core");
    client.setSubscription("C:\\GraphCode-Fixtures\\Destructive");
    client.resume_from = 42;
    const hello = try client.helloFrame(std.testing.allocator);
    defer std.testing.allocator.free(hello);
    try std.testing.expect(try daemonAdmitsProjectEvents(hello, "C:\\GraphCode-Fixtures\\Destructive"));
    try std.testing.expect(try daemonAdmitsProjectEvents(hello, "C:\\GraphCode-Fixtures\\Core"));
    try std.testing.expect(try daemonAdmitsProjectEvents(hello, "graphcode://global"));
    try std.testing.expect(std.mem.indexOf(u8, hello, "\"resumeFrom\":42") != null);
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

const NegotiationPipeFixture = struct {
    server: c.HANDLE,
    temporary: std.testing.TmpDir,
    old_pipe: ?[]u8,
    old_support: ?[]u8,
    io_timeout_ms: c.DWORD = 2_000,

    fn createServer(name: []const u8) !c.HANDLE {
        const wide = try utf8ToWide(std.testing.allocator, name);
        defer std.testing.allocator.free(wide);
        const server = c.CreateNamedPipeW(
            wide.ptr,
            c.PIPE_ACCESS_DUPLEX | c.FILE_FLAG_OVERLAPPED | c.FILE_FLAG_FIRST_PIPE_INSTANCE,
            c.PIPE_TYPE_BYTE | c.PIPE_REJECT_REMOTE_CLIENTS,
            1,
            64 * 1024,
            64 * 1024,
            0,
            null,
        );
        if (server == c.INVALID_HANDLE_VALUE) return error.TestPipeCreationFailed;
        return server;
    }

    fn init() !NegotiationPipeFixture {
        const allocator = std.testing.allocator;
        var temporary = std.testing.tmpDir(.{});
        errdefer temporary.cleanup();
        const support = try temporary.dir.realpathAlloc(allocator, ".");
        defer allocator.free(support);
        const name = try std.fmt.allocPrint(allocator, "\\\\.\\pipe\\graphcode-negotiation-test-{d}", .{std.time.nanoTimestamp()});
        defer allocator.free(name);
        const server = try createServer(name);
        errdefer _ = c.CloseHandle(server);
        const old_pipe = std.process.getEnvVarOwned(allocator, "GRAPHCODE_DAEMON_PIPE") catch null;
        errdefer if (old_pipe) |value| allocator.free(value);
        const old_support = std.process.getEnvVarOwned(allocator, "GRAPHCODE_SUPPORT_DIR") catch null;
        errdefer if (old_support) |value| allocator.free(value);
        try setEnvironmentChecked("GRAPHCODE_DAEMON_PIPE", name);
        errdefer setTestEnvironment("GRAPHCODE_DAEMON_PIPE", old_pipe);
        try setEnvironmentChecked("GRAPHCODE_SUPPORT_DIR", support);
        return .{ .server = server, .temporary = temporary, .old_pipe = old_pipe, .old_support = old_support };
    }

    fn deinit(self: *NegotiationPipeFixture) void {
        setTestEnvironment("GRAPHCODE_DAEMON_PIPE", self.old_pipe);
        setTestEnvironment("GRAPHCODE_SUPPORT_DIR", self.old_support);
        if (self.old_pipe) |value| std.testing.allocator.free(value);
        if (self.old_support) |value| std.testing.allocator.free(value);
        _ = c.CloseHandle(self.server);
        self.temporary.cleanup();
    }

    fn restart(self: *NegotiationPipeFixture) !void {
        const name = try std.process.getEnvVarOwned(std.testing.allocator, "GRAPHCODE_DAEMON_PIPE");
        defer std.testing.allocator.free(name);
        _ = c.CloseHandle(self.server);
        self.server = c.INVALID_HANDLE_VALUE;
        self.server = try createServer(name);
    }

    fn accept(self: *NegotiationPipeFixture) !void {
        var overlapped = std.mem.zeroes(c.OVERLAPPED);
        overlapped.hEvent = c.CreateEventW(null, 1, 0, null);
        if (overlapped.hEvent == null) return error.TestPipeEventFailed;
        defer _ = c.CloseHandle(overlapped.hEvent);
        if (c.ConnectNamedPipe(self.server, &overlapped) == 0) {
            const code = c.GetLastError();
            if (code == c.ERROR_PIPE_CONNECTED) return;
            if (code != c.ERROR_IO_PENDING) return error.TestPipeAcceptFailed;
            var transferred: c.DWORD = 0;
            if (c.WaitForSingleObject(overlapped.hEvent, self.io_timeout_ms) != c.WAIT_OBJECT_0) {
                _ = c.CancelIoEx(self.server, &overlapped);
                _ = c.GetOverlappedResult(self.server, &overlapped, &transferred, 1);
                return error.TestPipeAcceptTimedOut;
            }
            if (c.GetOverlappedResult(self.server, &overlapped, &transferred, 0) == 0)
                return error.TestPipeAcceptFailed;
        }
    }

    fn readAll(self: *NegotiationPipeFixture, bytes: []u8) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            var overlapped = std.mem.zeroes(c.OVERLAPPED);
            overlapped.hEvent = c.CreateEventW(null, 1, 0, null);
            if (overlapped.hEvent == null) return error.TestPipeEventFailed;
            defer _ = c.CloseHandle(overlapped.hEvent);
            var transferred: c.DWORD = 0;
            if (c.ReadFile(self.server, bytes[offset..].ptr, @intCast(bytes.len - offset), &transferred, &overlapped) == 0) {
                if (c.GetLastError() != c.ERROR_IO_PENDING) return error.TestPipeReadFailed;
                if (c.WaitForSingleObject(overlapped.hEvent, self.io_timeout_ms) != c.WAIT_OBJECT_0) {
                    _ = c.CancelIoEx(self.server, &overlapped);
                    _ = c.GetOverlappedResult(self.server, &overlapped, &transferred, 1);
                    return error.TestPipeReadTimedOut;
                }
                if (c.GetOverlappedResult(self.server, &overlapped, &transferred, 0) == 0)
                    return error.TestPipeReadFailed;
            }
            if (transferred == 0) return error.TestPipeClosed;
            offset += transferred;
        }
    }

    fn readFrame(self: *NegotiationPipeFixture) ![]u8 {
        var header: [4]u8 = undefined;
        try self.readAll(&header);
        const length = try Wire.decodedLength(header, .v2);
        const frame = try std.testing.allocator.alloc(u8, length);
        errdefer std.testing.allocator.free(frame);
        try self.readAll(frame);
        return frame;
    }

    fn reply(self: *NegotiationPipeFixture, frame: []const u8) !void {
        const header = try Wire.frameLength(frame, .v2);
        try writeAll(self.server, &header);
        try writeAll(self.server, frame);
    }

    fn expectLog(self: *NegotiationPipeFixture, detail: []const u8) !void {
        const log = try self.temporary.dir.readFileAlloc(std.testing.allocator, "graphcode-windows.log", 16 * 1024);
        defer std.testing.allocator.free(log);
        try std.testing.expect(std.mem.indexOf(u8, log, "event=daemon-negotiation") != null);
        try std.testing.expect(std.mem.indexOf(u8, log, detail) != null);
    }
};

fn waitForNegotiationState(client: *DaemonClient, state: Wire.ConnectionState, timeout_ms: i64) !void {
    const deadline = nowMilliseconds() + timeout_ms;
    while (client.connectionState() != state) {
        if (nowMilliseconds() >= deadline) {
            std.debug.print("expected {s}; observed {s}: {s}\n", .{
                @tagName(state), @tagName(client.connectionState()), client.statusText(),
            });
            return error.TestNegotiationStateTimedOut;
        }
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
}

test "negotiation cancel boundary retains a completed header and correlates the intact response exactly once" {
    var fixture = try NegotiationPipeFixture.init();
    defer fixture.deinit();
    var client = try DaemonClient.initForTesting(std.testing.allocator);
    defer client.deinit();
    defer client.closeHandleOnly();
    client.connect();
    client.attemptConnection(nowMilliseconds());
    try fixture.accept();
    const hello = try fixture.readFrame();
    defer std.testing.allocator.free(hello);
    try fixture.reply("{\"version\":2,\"kind\":\"hello\",\"selectedVersion\":2}");
    try std.testing.expect(client.pumpIncoming());
    try std.testing.expectEqual(Wire.ConnectionState.connected, client.connectionState());

    const request_id = "00000000-0000-4000-8000-000000000042".*;
    client.sendCommandOnWorker("{\"listRecentProjects\":{}}", request_id, .recent_projects);
    const request = try fixture.readFrame();
    defer std.testing.allocator.free(request);
    try std.testing.expectEqualStrings(&request_id, Wire.topLevelString(request, "requestID").?);
    const response = "{\"version\":2,\"kind\":\"response\",\"requestID\":\"00000000-0000-4000-8000-000000000042\",\"success\":true}";
    const Boundary = struct {
        server: c.HANDLE,
        header: [4]u8,
        read_started: std.Thread.ResetEvent = .{},
        forced: bool = false,
        write_error: ?anyerror = null,

        fn writeHeader(self: *@This()) void {
            self.read_started.wait();
            writeAll(self.server, &self.header) catch |err| {
                self.write_error = err;
            };
        }

        fn wait(context: ?*anyopaque, event: c.HANDLE, milliseconds: c.DWORD) c.DWORD {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (self.forced) return c.WaitForSingleObject(event, milliseconds);
            self.forced = true;
            self.read_started.set();
            const result = c.WaitForSingleObject(event, 5_000);
            // The actual pending read has completed; force cancellation to lose the race.
            return if (result == c.WAIT_OBJECT_0) c.WAIT_TIMEOUT else result;
        }
    };
    var boundary = Boundary{ .server = fixture.server, .header = try Wire.frameLength(response, .v2) };
    const writer = try std.Thread.spawn(.{}, Boundary.writeHeader, .{&boundary});
    const pumped = client.pumpIncomingWithWait(.{ .context = &boundary, .wait = Boundary.wait });
    boundary.read_started.set();
    writer.join();
    if (boundary.write_error) |err| return err;
    try std.testing.expect(pumped);
    try std.testing.expect(boundary.forced);
    try std.testing.expectEqual(@as(?usize, response.len), client.frame_buffer.expected_length);
    try std.testing.expectEqual(@as(usize, 0), client.frame_buffer.length);
    try std.testing.expectEqual(@as(usize, 1), client.pending_request_count);
    try std.testing.expectEqual(@as(usize, 0), client.inbound_count);

    try writeAll(fixture.server, response);
    try std.testing.expect(client.pumpIncoming());
    try std.testing.expectEqual(Wire.ProtocolMode.v2, client.protocolMode());
    try std.testing.expectEqual(Wire.ConnectionState.connected, client.connectionState());
    try std.testing.expectEqual(@as(usize, 0), client.pending_request_count);
    try std.testing.expectEqual(@as(usize, 1), client.inbound_count);
    try std.testing.expectEqualStrings(response, client.inbound[client.inbound_head]);
    try std.testing.expectEqual(@as(?usize, null), client.frame_buffer.expected_length);
    try std.testing.expectEqual(@as(usize, 0), client.frame_buffer.length);
    client.poll();
    try std.testing.expect(client.isIdle());
}

test "negotiation cancel boundary with aborted zero-byte read preserves the connection and next hello" {
    var fixture = try NegotiationPipeFixture.init();
    defer fixture.deinit();
    var client = try DaemonClient.initForTesting(std.testing.allocator);
    defer client.deinit();
    defer client.closeHandleOnly();
    client.connect();
    client.attemptConnection(nowMilliseconds());
    try fixture.accept();
    const hello = try fixture.readFrame();
    defer std.testing.allocator.free(hello);
    try std.testing.expect(client.pumpIncoming());
    try std.testing.expectEqual(Wire.ConnectionState.negotiating, client.connectionState());
    try std.testing.expectEqual(@as(?usize, null), client.frame_buffer.expected_length);
    try std.testing.expectEqual(@as(usize, 0), client.frame_buffer.length);
    try fixture.reply("{\"version\":2,\"kind\":\"hello\",\"selectedVersion\":2}");
    try std.testing.expect(client.pumpIncoming());
    try std.testing.expectEqual(Wire.ProtocolMode.v2, client.protocolMode());
    try std.testing.expectEqual(Wire.ConnectionState.connected, client.connectionState());
}

test "negotiation cancel boundary surfaces a terminal read error instead of treating it as no data" {
    var fixture = try NegotiationPipeFixture.init();
    defer fixture.deinit();
    var client = try DaemonClient.initForTesting(std.testing.allocator);
    defer client.deinit();
    defer client.closeHandleOnly();
    client.connect();
    client.attemptConnection(nowMilliseconds());
    try fixture.accept();
    const hello = try fixture.readFrame();
    defer std.testing.allocator.free(hello);
    const Boundary = struct {
        fn wait(context: ?*anyopaque, event: c.HANDLE, _: c.DWORD) c.DWORD {
            const current: *NegotiationPipeFixture = @ptrCast(@alignCast(context.?));
            if (c.CloseHandle(current.server) == 0) return c.WAIT_FAILED;
            current.server = c.INVALID_HANDLE_VALUE;
            const result = c.WaitForSingleObject(event, 5_000);
            return if (result == c.WAIT_OBJECT_0) c.WAIT_TIMEOUT else result;
        }
    };
    try std.testing.expect(!client.pumpIncomingWithWait(.{ .context = &fixture, .wait = Boundary.wait }));
    try std.testing.expectEqual(Wire.ConnectionState.reconnecting, client.connectionState());
    try std.testing.expectEqualStrings("daemon frame read failed", client.statusText());
    try std.testing.expectEqual(@as(usize, 0), client.frame_buffer.length);
}

test "negotiation cancel boundary joins a pending read before surfacing a wait failure" {
    var fixture = try NegotiationPipeFixture.init();
    defer fixture.deinit();
    var client = try DaemonClient.initForTesting(std.testing.allocator);
    defer client.deinit();
    defer client.closeHandleOnly();
    client.connect();
    client.attemptConnection(nowMilliseconds());
    try fixture.accept();
    const hello = try fixture.readFrame();
    defer std.testing.allocator.free(hello);
    const Boundary = struct {
        fn wait(_: ?*anyopaque, _: c.HANDLE, _: c.DWORD) c.DWORD {
            return c.WAIT_FAILED;
        }
    };
    try std.testing.expect(!client.pumpIncomingWithWait(.{ .wait = Boundary.wait }));
    try std.testing.expectEqual(Wire.ConnectionState.reconnecting, client.connectionState());
    try std.testing.expectEqualStrings("daemon read wait failed", client.statusText());
    try std.testing.expectEqual(c.INVALID_HANDLE_VALUE, client.pipe);
}

test "negotiation slow v2 hello after 2500 ms stays v2 and serves a correlated request" {
    const hello_delay_ms = 2_500;
    const negotiation_budget_ms = 4 * hello_delay_ms;
    const completion_budget_ms = 2 * hello_delay_ms;
    var fixture = try NegotiationPipeFixture.init();
    defer fixture.deinit();
    fixture.io_timeout_ms = completion_budget_ms;
    var client = try DaemonClient.initForTesting(std.testing.allocator);
    defer {
        if (client.worker == null) client.closeHandleOnly();
        client.deinit();
    }
    client.connect();
    client.attemptConnection(nowMilliseconds());
    // Only this test's deadline changes; loaded CI scheduling is not protocol time.
    try std.testing.expectEqual(@as(i64, 5_000), client.negotiation_deadline_ms - client.negotiation_started_ms);
    client.negotiation_deadline_ms = client.negotiation_started_ms + negotiation_budget_ms;
    try fixture.accept();
    const hello = try fixture.readFrame();
    defer std.testing.allocator.free(hello);
    try std.testing.expectEqualStrings("hello", Wire.topLevelString(hello, "kind").?);
    try client.start();
    std.Thread.sleep(hello_delay_ms * std.time.ns_per_ms);
    try std.testing.expectEqual(Wire.ConnectionState.negotiating, client.connectionState());
    try std.testing.expectEqual(Wire.ProtocolMode.v2, client.protocolMode());
    try fixture.reply("{\"version\":2,\"kind\":\"hello\",\"selectedVersion\":2}");
    try waitForNegotiationState(&client, .connected, completion_budget_ms);
    const request = client.sendReadProjectGraph("C:\\negotiation-fixture") orelse return error.TestRequestNotQueued;
    const command = try fixture.readFrame();
    defer std.testing.allocator.free(command);
    try std.testing.expectEqualStrings(&request.request_id, Wire.topLevelString(command, "requestID").?);
    try std.testing.expectEqualStrings("request", Wire.topLevelString(command, "kind").?);
    const response = try std.fmt.allocPrint(std.testing.allocator,
        "{{\"version\":2,\"kind\":\"response\",\"requestID\":\"{s}\",\"success\":true}}", .{request.request_id});
    defer std.testing.allocator.free(response);
    try fixture.reply(response);
    const deadline = nowMilliseconds() + completion_budget_ms;
    while (!client.isIdle()) {
        client.poll();
        if (nowMilliseconds() >= deadline) return error.TestRequestNotCompleted;
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    try std.testing.expectEqual(Wire.ProtocolMode.v2, client.protocolMode());
    try std.testing.expectEqual(@as(u64, 1), client.connectionGeneration());
    try std.testing.expect(!client.hasReconnected());
}

test "negotiation genuine v1 reply falls back and keeps reason elapsed time and log after connecting" {
    var fixture = try NegotiationPipeFixture.init();
    defer fixture.deinit();
    var client = try DaemonClient.initForTesting(std.testing.allocator);
    defer {
        if (client.worker == null) client.closeHandleOnly();
        client.deinit();
    }
    client.connect();
    client.attemptConnection(nowMilliseconds());
    try fixture.accept();
    const hello = try fixture.readFrame();
    defer std.testing.allocator.free(hello);
    std.Thread.sleep(30 * std.time.ns_per_ms);
    try fixture.reply("{\"errorOccurred\":{\"_0\":\"unknown command\"}}");
    try std.testing.expect(client.pumpIncoming());
    try std.testing.expectEqual(Wire.ProtocolMode.v1, client.protocolMode());
    const detail = client.statusText();
    try std.testing.expect(std.mem.indexOf(u8, detail, "v2 -> v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "v1-shaped reply") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, " ms") != null);
    try std.testing.expect(client.fallback_notice.?.elapsed_ms >= 30);
    try std.testing.expect(client.fallback_notice.?.elapsed_ms <= @as(u64, @intCast(nowMilliseconds() - client.negotiation_started_ms)));
    try fixture.expectLog(detail);
    try fixture.restart();
    client.attemptConnection(nowMilliseconds());
    try fixture.accept();
    try std.testing.expectEqual(Wire.ConnectionState.connected, client.connectionState());
    try std.testing.expectEqual(Wire.ProtocolMode.v1, client.protocolMode());
    try std.testing.expect(std.mem.indexOf(u8, client.statusText(), "v1-shaped reply") != null);
    try client.start();
    client.sendListProjects();
    const command = try fixture.readFrame();
    defer std.testing.allocator.free(command);
    try std.testing.expectEqualStrings("{\"listRecentProjects\":{}}", command);
    try fixture.reply("{\"recentProjectsListed\":{\"_0\":[]}}");
    const deadline = nowMilliseconds() + 2_000;
    while (!client.isIdle()) {
        client.poll();
        if (nowMilliseconds() >= deadline) return error.TestLegacyRequestNotCompleted;
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
}

test "negotiation no reply is bounded visible and never selects v1" {
    var fixture = try NegotiationPipeFixture.init();
    defer fixture.deinit();
    var client = try DaemonClient.initForTesting(std.testing.allocator);
    defer {
        if (client.worker == null) client.closeHandleOnly();
        client.deinit();
    }
    client.connect();
    client.attemptConnection(nowMilliseconds());
    try fixture.accept();
    const hello = try fixture.readFrame();
    defer std.testing.allocator.free(hello);
    client.retry_delay_ms = 4_000;
    const start = nowMilliseconds();
    try client.start();
    while (client.connectionState() == .negotiating) {
        if (nowMilliseconds() - start > 6_000) return error.TestHelloWaitNotBounded;
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    try std.testing.expectEqual(Wire.ProtocolMode.v2, client.protocolMode());
    try std.testing.expect(nowMilliseconds() - start >= 4_900);
    try std.testing.expect(std.mem.indexOf(u8, client.statusText(), "v2 hello timed out") != null);
    try std.testing.expect(std.mem.indexOf(u8, client.statusText(), "retrying v2") != null);
    try fixture.expectLog("retrying v2");
}

test "negotiation explicit v1 selection and unsupported version refusal report distinct reasons" {
    var fixture = try NegotiationPipeFixture.init();
    defer fixture.deinit();
    const frames = [_][]const u8{
        "{\"version\":2,\"kind\":\"hello\",\"selectedVersion\":1}",
        "{\"version\":2,\"kind\":\"error\",\"error\":{\"code\":\"unsupportedVersion\",\"message\":\"no supported version\"}}",
    };
    const reasons = [_][]const u8{ "daemon selected v1", "daemon refused v2 (unsupportedVersion)" };
    for (frames, reasons) |frame, reason| {
        var client = try DaemonClient.initForTesting(std.testing.allocator);
        defer client.deinit();
        client.state = .negotiating;
        client.negotiation_started_ms = nowMilliseconds() - 75;
        client.negotiation_deadline_ms = client.negotiation_started_ms + DaemonClient.negotiation_timeout_ms;
        try std.testing.expect(client.handleFrame(frame));
        try std.testing.expectEqual(Wire.ProtocolMode.v1, client.protocolMode());
        try std.testing.expect(client.fallback_notice.?.elapsed_ms >= 75);
        try std.testing.expect(std.mem.indexOf(u8, client.statusText(), reason) != null);
        try fixture.expectLog(reason);
    }
}

test "negotiation invalid unrelated or nested replies cannot select legacy framing" {
    const frames = [_][]const u8{
        "not json",
        "{}",
        "{\"kind\":\"event\",\"version\":2,\"event\":{\"graphChanged\":{}}}",
        "{\"version\":2,\"kind\":\"error\",\"error\":{\"code\":\"malformedEnvelope\",\"message\":\"invalid hello\"}}",
        "{\"version\":2,\"kind\":\"hello\",\"selectedVersion\":3}",
        "{\"version\":2,\"kind\":\"hello\",\"selectedVersion\":12}",
        "{\"version\":2,\"kind\":\"hello\",\"event\":{\"selectedVersion\":2}}",
        "{\"version\":2,\"kind\":\"event\",\"event\":{\"kind\":\"hello\",\"selectedVersion\":2}}",
        "{\"unknown\":{\"_0\":\"not a daemon event\"}}",
    };
    for (frames) |frame| {
        var client = try DaemonClient.initForTesting(std.testing.allocator);
        defer client.deinit();
        client.state = .negotiating;
        try std.testing.expect(!client.handleFrame(frame));
        try std.testing.expectEqual(Wire.ProtocolMode.v2, client.protocolMode());
        try std.testing.expectEqual(Wire.ConnectionState.protocol_error, client.connectionState());
        try std.testing.expect(!client.fallback_to_v1);
    }
}

test "negotiation accepts whitespace in an actual v2 hello without fallback" {
    var client = try DaemonClient.initForTesting(std.testing.allocator);
    defer client.deinit();
    client.state = .negotiating;
    try std.testing.expect(client.handleFrame("{ \"version\" : 2, \"kind\" : \"hello\", \"selectedVersion\" : 2 }"));
    try std.testing.expectEqual(Wire.ProtocolMode.v2, client.protocolMode());
    try std.testing.expectEqual(Wire.ConnectionState.connected, client.connectionState());
}

test "negotiation successful v2 reconnect clears the previous fallback notice" {
    var fixture = try NegotiationPipeFixture.init();
    defer fixture.deinit();
    var client = try DaemonClient.initForTesting(std.testing.allocator);
    defer client.deinit();
    client.state = .negotiating;
    client.negotiation_started_ms = nowMilliseconds();
    try std.testing.expect(client.handleFrame("{\"version\":2,\"kind\":\"hello\",\"selectedVersion\":1}"));
    try std.testing.expect(client.fallback_notice != null);
    client.prepareV2Negotiation();
    client.state = .negotiating;
    try std.testing.expect(client.handleFrame("{\"version\":2,\"kind\":\"hello\",\"selectedVersion\":2}"));
    try std.testing.expect(client.fallback_notice == null);
    try std.testing.expect(!client.fallback_to_v1);
    try std.testing.expectEqualStrings("Connected · protocol v2", client.statusText());
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

test "daemon startup endpoint is available before the rendezvous secret exists" {
    const allocator = std.testing.allocator;
    const old_pipe = std.process.getEnvVarOwned(allocator, "GRAPHCODE_DAEMON_PIPE") catch null;
    const old_support = std.process.getEnvVarOwned(allocator, "GRAPHCODE_SUPPORT_DIR") catch null;
    defer {
        setTestEnvironment("GRAPHCODE_DAEMON_PIPE", old_pipe);
        setTestEnvironment("GRAPHCODE_SUPPORT_DIR", old_support);
        if (old_pipe) |value| allocator.free(value);
        if (old_support) |value| allocator.free(value);
    }
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const support = try temporary.dir.realpathAlloc(allocator, ".");
    defer allocator.free(support);
    setTestEnvironment("GRAPHCODE_DAEMON_PIPE", null);
    setTestEnvironment("GRAPHCODE_SUPPORT_DIR", support);

    var client = try DaemonClient.init(allocator);
    defer client.deinit();

    try std.testing.expectError(error.EndpointSecretMissing, client.currentEndpointName(allocator));

    const lock_name = try client.currentDaemonLockName(allocator);
    defer allocator.free(lock_name);
    try std.testing.expect(lock_name.len != 0);

    const startup_endpoint = try client.currentDaemonStartupEndpoint(allocator);
    defer allocator.free(startup_endpoint);
    try std.testing.expect(std.mem.startsWith(u8, startup_endpoint, "\\\\.\\pipe\\graphcode-startup-"));
    const startup_endpoint_again = try client.currentDaemonStartupEndpoint(allocator);
    defer allocator.free(startup_endpoint_again);
    try std.testing.expectEqualStrings(startup_endpoint, startup_endpoint_again);

    try temporary.dir.writeFile(.{
        .sub_path = ".graphcode-rendezvous.secret",
        .data = "0123456789abcdef0123456789abcdef",
    });
    const real_endpoint = try client.currentEndpointName(allocator);
    defer allocator.free(real_endpoint);
    try std.testing.expect(!std.mem.eql(u8, real_endpoint, startup_endpoint));

    setTestEnvironment("GRAPHCODE_DAEMON_PIPE", "\\\\.\\pipe\\graphcode-test-override");
    const overridden = try client.currentDaemonStartupEndpoint(allocator);
    defer allocator.free(overridden);
    try std.testing.expectEqualStrings("\\\\.\\pipe\\graphcode-test-override", overridden);
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

fn startupEndpointName(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "GRAPHCODE_DAEMON_PIPE")) |override| {
        return override;
    } else |_| {}

    const support = try supportDirectory(allocator);
    defer allocator.free(support);
    return endpointNameFor(allocator, "", support) catch |err| switch (err) {
        error.EndpointSecretMissing => startupEndpointNameFor(allocator, support),
        else => err,
    };
}

/// Stable missing endpoint used only while reserving daemon startup.
fn startupEndpointNameFor(allocator: std.mem.Allocator, support: []const u8) ![]u8 {
    const sid = try currentSID(allocator);
    defer allocator.free(sid);
    const support_identity = normalizedSupportPath(allocator, support) catch
        return error.EndpointHashFailed;
    defer allocator.free(support_identity);
    const support_hash = sha256Hex(allocator, support_identity) catch
        return error.EndpointHashFailed;
    defer allocator.free(support_hash);
    return std.fmt.allocPrint(
        allocator,
        "\\\\.\\pipe\\graphcode-startup-{s}-{s}",
        .{ sid, support_hash[0..24] },
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

/// Lock name for the daemon that owns `support_directory`. Derived exactly as the Swift
/// daemon derives it, so this addresses another workspace's daemon, not only our own.
pub fn daemonLockNameFor(allocator: std.mem.Allocator, support_directory: []const u8) ![]u8 {
    const normalized = try normalizedSupportPath(allocator, support_directory);
    defer allocator.free(normalized);
    const support_hash = try sha256Hex(allocator, normalized);
    defer allocator.free(support_hash);
    const sid = try currentSID(allocator);
    defer allocator.free(sid);
    return std.fmt.allocPrint(
        allocator,
        "Global\\graphcode-daemon-{s}-{s}",
        .{ sid, support_hash[0..20] },
    );
}

pub fn daemonLockName(allocator: std.mem.Allocator) ![]u8 {
    const support = try supportDirectory(allocator);
    defer allocator.free(support);
    return daemonLockNameFor(allocator, support);
}

/// Name of the per-user scheduled task that Tools\windows\PackageRuntime.ps1
/// (`Get-TaskIdentity`) registers for the daemon that owns `support_directory`:
/// `GraphCode\graphcoded-` plus the first 32 hex digits of SHA-256 over
/// `<SID>|<lowercased full path without a trailing backslash>`.
pub fn daemonTaskNameFor(allocator: std.mem.Allocator, support_directory: []const u8) ![]u8 {
    const normalized = try normalizedSupportPath(allocator, support_directory);
    defer allocator.free(normalized);
    for (normalized) |*byte| {
        if (byte.* == '/') byte.* = '\\';
    }
    const trimmed = std.mem.trimRight(u8, normalized, "\\");
    const sid = try currentSID(allocator);
    defer allocator.free(sid);
    const identity = try std.fmt.allocPrint(allocator, "{s}|{s}", .{ sid, trimmed });
    defer allocator.free(identity);
    const hash = try sha256Hex(allocator, identity);
    defer allocator.free(hash);
    return std.fmt.allocPrint(allocator, "GraphCode\\graphcoded-{s}", .{hash[0..32]});
}

pub fn daemonTaskName(allocator: std.mem.Allocator) ![]u8 {
    const support = try supportDirectory(allocator);
    defer allocator.free(support);
    return daemonTaskNameFor(allocator, support);
}

test "daemon task name follows the installer's identity for any spelling of the support path" {
    const allocator = std.testing.allocator;
    const sid = try currentSID(allocator);
    defer allocator.free(sid);
    const identity = try std.fmt.allocPrint(allocator, "{s}|c:\\fixture\\.graphcode", .{sid});
    defer allocator.free(identity);
    const hash = try sha256Hex(allocator, identity);
    defer allocator.free(hash);
    const expected = try std.fmt.allocPrint(allocator, "GraphCode\\graphcoded-{s}", .{hash[0..32]});
    defer allocator.free(expected);
    for ([_][]const u8{
        "C:\\Fixture\\.graphcode",
        "C:\\Fixture\\.graphcode\\",
        "c:/fixture/./.graphcode",
    }) |spelling| {
        const name = try daemonTaskNameFor(allocator, spelling);
        defer allocator.free(name);
        try std.testing.expectEqualStrings(expected, name);
    }
    const other = try daemonTaskNameFor(allocator, "C:\\Fixture\\.graphcode-other");
    defer allocator.free(other);
    try std.testing.expect(!std.mem.eql(u8, expected, other));
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
