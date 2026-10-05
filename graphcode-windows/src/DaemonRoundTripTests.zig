const std = @import("std");
const DaemonClientModule = @import("DaemonClient.zig");
const DaemonClient = DaemonClientModule.DaemonClient;
const Forms = @import("Forms.zig");
const GraphModel = @import("GraphModel.zig");
const SketchPromotion = @import("SketchPromotion.zig");
const Wire = @import("Wire.zig");
const Win32 = @import("Win32.zig");
const c = Win32.c;

const allocator = std.testing.allocator;
const sketch_id = "A1111111-1111-4111-8111-111111111111";
const details_id = "B2222222-2222-4222-8222-222222222222";

test "daemon round-trip support helper derives scoped global lock name" {
    const lock_name = try DaemonClientModule.daemonLockNameFor(allocator, "C:\\graphcode-roundtrip-support");
    defer allocator.free(lock_name);
    try std.testing.expect(std.mem.startsWith(u8, lock_name, "Global\\graphcode-daemon-"));
}

test "real daemon mutations survive restart" {
    const phase = try envOwned("GRAPHCODE_DAEMON_ROUNDTRIP_PHASE");
    defer allocator.free(phase);
    const support = try envOwned("GRAPHCODE_SUPPORT_DIR");
    defer allocator.free(support);
    const project_path = try envOwned("GRAPHCODE_DAEMON_ROUNDTRIP_PROJECT");
    defer allocator.free(project_path);
    const expected_edge_id = if (std.mem.eql(u8, phase, "create"))
        null
    else
        try envOwned("GRAPHCODE_DAEMON_ROUNDTRIP_EDGE_ID");
    defer if (expected_edge_id) |id| allocator.free(id);

    try expectDaemonMutex(support, true);
    if (std.mem.eql(u8, phase, "create")) {
        try createFixture(project_path);
    } else if (std.mem.eql(u8, phase, "mutate")) {
        try mutateFixture(project_path, expected_edge_id.?);
    } else if (std.mem.eql(u8, phase, "verify")) {
        try verifyFixture(project_path, expected_edge_id.?);
    } else {
        return error.InvalidDaemonRoundTripPhase;
    }
}

test "real daemon lifetime mutex is absent after shutdown" {
    const support = try envOwned("GRAPHCODE_SUPPORT_DIR");
    defer allocator.free(support);
    try expectDaemonMutex(support, false);
}

const Probe = struct {
    model: GraphModel.Model,
    response_count: usize = 0,
    last_success: ?bool = null,
    last_kind: Wire.EventKind = .unknown,
    invalid_response: bool = false,
    model_error: bool = false,
    last_request_id: [36]u8 = undefined,
    last_request_id_len: usize = 0,
    last_response_path: [512]u8 = undefined,
    last_response_path_len: usize = 0,

    fn init() Probe {
        return .{ .model = GraphModel.Model.init(allocator) };
    }

    fn receive(context: ?*anyopaque, frame_ptr: [*]const u8, length: usize) callconv(.c) void {
        const self: *Probe = @ptrCast(@alignCast(context orelse return));
        const frame = frame_ptr[0..length];
        if (Wire.responseRequestID(frame)) |request_id| {
            self.response_count += 1;
            self.last_kind = Wire.eventKind(frame);
            self.last_request_id_len = @min(request_id.len, self.last_request_id.len);
            @memcpy(self.last_request_id[0..self.last_request_id_len], request_id[0..self.last_request_id_len]);
            self.last_response_path_len = 0;
            if (Wire.copyGraphChangedProjectPath(std.heap.page_allocator, frame) catch null) |path| {
                defer std.heap.page_allocator.free(path);
                self.last_response_path_len = @min(path.len, self.last_response_path.len);
                @memcpy(self.last_response_path[0..self.last_response_path_len], path[0..self.last_response_path_len]);
            }
            const parsed = std.json.parseFromSlice(
                std.json.Value,
                std.heap.page_allocator,
                frame,
                .{},
            ) catch {
                self.invalid_response = true;
                return;
            };
            defer parsed.deinit();
            if (parsed.value != .object) {
                self.invalid_response = true;
                return;
            }
            const kind = parsed.value.object.get("kind") orelse {
                self.invalid_response = true;
                return;
            };
            if (kind != .string or !std.mem.eql(u8, kind.string, "response")) {
                self.invalid_response = true;
                return;
            }
            if (parsed.value.object.get("success")) |success| {
                if (success != .bool or !success.bool) {
                    self.invalid_response = true;
                    return;
                }
            }
            if (self.last_kind != .graph_changed) {
                self.invalid_response = true;
                return;
            }
            self.last_success = true;
        }
        _ = self.model.updateFromFrame(frame) catch {
            self.model_error = true;
        };
    }
};

fn envOwned(name: []const u8) ![]u8 {
    return std.process.getEnvVarOwned(allocator, name) catch error.MissingDaemonRoundTripEnvironment;
}

fn expectDaemonMutex(support: []const u8, expected: bool) !void {
    const name = try DaemonClientModule.daemonLockNameFor(allocator, support);
    defer allocator.free(name);
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(allocator, name);
    defer allocator.free(wide);
    const mutex = c.OpenMutexW(c.SYNCHRONIZE, 0, wide.ptr);
    if (mutex) |handle| {
        defer _ = c.CloseHandle(handle);
        if (!expected) return error.DaemonMutexStillExistsAfterShutdown;
        std.debug.print("DAEMON_MUTEX: present under production-derived Global name\n", .{});
        return;
    }
    const code = c.GetLastError();
    if (expected) return error.DaemonMutexMissingWhileProcessRuns;
    if (code != c.ERROR_FILE_NOT_FOUND) return error.DaemonMutexProbeFailed;
    std.debug.print("DAEMON_MUTEX: absent after process exit\n", .{});
}

fn connectProject(client: *DaemonClient, probe: *Probe, path: []const u8) !void {
    client.setCallback(Probe.receive, probe);
    client.setSubscription(path);
    client.connect();
    try client.start();
    const connected_deadline = std.time.milliTimestamp() + 10_000;
    while (client.connectionState() != .connected) {
        if (std.time.milliTimestamp() >= connected_deadline) return error.DaemonConnectionTimedOut;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    const before = probe.response_count;
    const token = client.sendOpenProject(path) orelse return error.OpenProjectQueueRejected;
    try waitForAcceptedResponse(client, probe, before);
    try std.testing.expect(!probe.model_error);
    const canonical_path = try std.mem.replaceOwned(u8, allocator, path, "\\", "/");
    defer allocator.free(canonical_path);
    // The shell's folder open sends the picker's backslash spelling; the daemon
    // answers that exact request with its canonical forward-slash spelling.
    try std.testing.expect(std.mem.indexOfScalar(u8, path, '\\') != null);
    try std.testing.expect(std.ascii.eqlIgnoreCase(&token, probe.last_request_id[0..probe.last_request_id_len]));
    try std.testing.expectEqualStrings(canonical_path, probe.last_response_path[0..probe.last_response_path_len]);
    try std.testing.expect(!std.mem.eql(u8, path, canonical_path));
    std.debug.print("DAEMON_OPEN_CANONICAL: request correlated; picker spelling differs from daemon canonical path\n", .{});
    try std.testing.expectEqualStrings(canonical_path, probe.model.currentGraph().?.project.path);
    const expected_name = std.fs.path.basename(canonical_path);
    try std.testing.expect(expected_name.len != 0);
    try std.testing.expectEqualStrings(expected_name, probe.model.currentGraph().?.project.name);
}

fn waitForAcceptedResponse(client: *DaemonClient, probe: *Probe, before: usize) !void {
    const response_deadline = std.time.milliTimestamp() + 10_000;
    while (probe.response_count == before) {
        client.poll();
        if (std.time.milliTimestamp() >= response_deadline) return error.DaemonResponseTimedOut;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    try std.testing.expect(!probe.invalid_response);
    try std.testing.expect(!probe.model_error);
    try std.testing.expectEqual(@as(?bool, true), probe.last_success);
    try std.testing.expectEqual(Wire.EventKind.graph_changed, probe.last_kind);
}

fn createFixture(path: []const u8) !void {
    var probe = Probe.init();
    defer probe.model.deinit();
    var client = try DaemonClient.init(allocator);
    defer client.deinit();
    try connectProject(&client, &probe, path);

    client.sendCreateNodeDraft(path, .{
        .title = "Persistent sketch",
        .loop_type = "sketch",
        .first_instruction = "Keep this node identity through promotion.",
        .node_id = sketch_id,
    });
    try waitForAcceptedResponse(&client, &probe, probe.response_count);
    try expectNode(&probe, sketch_id, "Persistent sketch", "sketch", null);

    client.sendCreateNodeDraft(path, .{
        .title = "Initial details",
        .loop_type = "turnBased",
        .check_description = "Initial verification",
        .first_instruction = "Persist the accepted node details.",
        .node_id = details_id,
    });
    try waitForAcceptedResponse(&client, &probe, probe.response_count);
    try expectNode(&probe, details_id, "Initial details", "turnBased", "Initial verification");

    const edge = Forms.EdgeDraft{
        .from = sketch_id,
        .to = details_id,
        .kind = "spawn",
        .condition = "onFailure",
        .transform_kind = "script",
        .transform_value = "printf 'round trip'",
        .cycle_max_iterations = 7,
        .cycle_until = "test -f done",
        .cycle_stop_after_passes = 3,
        .spawn_target_project_path = try envOwned("GRAPHCODE_DAEMON_ROUNDTRIP_SPAWN_PROJECT"),
    };
    defer allocator.free(edge.spawn_target_project_path);
    client.sendCreateEdgeDraft(path, edge);
    try waitForAcceptedResponse(&client, &probe, probe.response_count);
    try expectEdge(&probe, null, "onFailure", 0);
    std.debug.print("DAEMON_ACCEPTED: node creation and edge creation\n", .{});
}

fn mutateFixture(path: []const u8, expected_edge_id: []const u8) !void {
    var probe = Probe.init();
    defer probe.model.deinit();
    var client = try DaemonClient.init(allocator);
    defer client.deinit();
    try connectProject(&client, &probe, path);
    try expectNode(&probe, sketch_id, "Persistent sketch", "sketch", null);
    try expectNode(&probe, details_id, "Initial details", "turnBased", "Initial verification");
    const initial_edge = try getSingleEdge(&probe);
    const initial_edge_id = try allocator.dupe(u8, initial_edge.id);
    defer allocator.free(initial_edge_id);
    try std.testing.expectEqualStrings(expected_edge_id, initial_edge_id);
    try std.testing.expectEqual(@as(i64, 2), initial_edge.fire_count);
    try expectEdge(&probe, initial_edge_id, "onFailure", 2);

    var before = probe.response_count;
    client.sendUpdateNodeForm(path, details_id, .{
        .check_description = "Updated verification",
    });
    try waitForAcceptedResponse(&client, &probe, before);
    try expectNode(&probe, details_id, "Initial details", "turnBased", "Updated verification");
    std.debug.print("DAEMON_ACCEPTED: node details update\n", .{});

    before = probe.response_count;
    client.sendRenameNode(path, details_id, "Renamed persisted details");
    try waitForAcceptedResponse(&client, &probe, before);
    try expectNode(&probe, details_id, "Renamed persisted details", "turnBased", "Updated verification");

    const edge_index = probe.model.findEdgeIndex(initial_edge_id) orelse return error.EditedEdgeMissing;
    const current_edge = probe.model.currentGraph().?.edges.items[edge_index];
    const expected = Forms.EdgeConfiguration.fromEdge(current_edge);
    var replacement = expected;
    replacement.condition = "onSuccess";
    before = probe.response_count;
    try client.sendUpdateEdge(
        path,
        current_edge.id,
        current_edge.from,
        current_edge.to,
        expected,
        replacement,
        "",
    );
    try waitForAcceptedResponse(&client, &probe, before);
    try expectEdge(&probe, initial_edge_id, "onSuccess", 2);
    std.debug.print("DAEMON_ACCEPTED: edge editing retained count and untouched configuration\n", .{});

    const sketch_index = probe.model.findNodeIndex(sketch_id) orelse return error.SketchMissing;
    if (!probe.model.setSelectedID(sketch_id)) return error.SketchPromotionSelectionMismatch;
    const sketch = probe.model.currentGraph().?.nodes.items[sketch_index];
    if (!std.mem.eql(u8, probe.model.selectedNodeID() orelse "", sketch_id))
        return error.SketchPromotionSelectionMismatch;
    const project_path = probe.model.currentGraph().?.project.path;
    var context = try SketchPromotion.Context.capture(allocator, &probe.model, project_path, "", sketch);
    defer context.deinit(allocator);
    before = probe.response_count;
    if (!try client.sendSketchPromotion(&probe.model, context, .{ .turn = false }))
        return error.PromotionQueueRejected;
    try waitForAcceptedResponse(&client, &probe, before);
    try expectNode(&probe, sketch_id, "Persistent sketch", "turnBased", null);
    std.debug.print("DAEMON_ACCEPTED: sketch promotion retained its node/session identity\n", .{});
}

fn verifyFixture(path: []const u8, expected_edge_id: []const u8) !void {
    var probe = Probe.init();
    defer probe.model.deinit();
    var client = try DaemonClient.init(allocator);
    defer client.deinit();
    try connectProject(&client, &probe, path);
    try expectNode(&probe, sketch_id, "Persistent sketch", "turnBased", null);
    try expectNode(&probe, details_id, "Renamed persisted details", "turnBased", "Updated verification");
    try expectEdge(&probe, expected_edge_id, "onSuccess", 2);
    std.debug.print("DAEMON_RELOAD: all five mutations and edge runtime/configuration survived restart\n", .{});
}

fn expectNode(
    probe: *const Probe,
    id: []const u8,
    title: []const u8,
    loop_type: []const u8,
    check_description: ?[]const u8,
) !void {
    const graph = probe.model.currentGraph() orelse return error.GraphSnapshotMissing;
    const index = probe.model.findNodeIndex(id) orelse return error.ExpectedNodeMissing;
    const node = graph.nodes.items[index];
    try std.testing.expectEqualStrings(id, node.id);
    try std.testing.expectEqualStrings(title, node.title);
    try std.testing.expectEqualStrings(loop_type, node.loop_type);
    try std.testing.expectEqualStrings("claudeCode", node.backend);
    const first_instruction = if (std.mem.eql(u8, id, sketch_id))
        "Keep this node identity through promotion."
    else if (std.mem.eql(u8, id, details_id))
        "Persist the accepted node details."
    else
        return error.UnexpectedNodeIdentity;
    try std.testing.expectEqualStrings(first_instruction, node.first_instruction);
    if (check_description) |description|
        try std.testing.expectEqualStrings(description, node.check_description);
}

fn getSingleEdge(probe: *const Probe) !GraphModel.Edge {
    const graph = probe.model.currentGraph() orelse return error.GraphSnapshotMissing;
    try std.testing.expectEqual(@as(usize, 1), graph.edges.items.len);
    return graph.edges.items[0];
}

fn expectEdge(probe: *const Probe, expected_id: ?[]const u8, condition: []const u8, fire_count: i64) !void {
    const edge = try getSingleEdge(probe);
    if (expected_id) |id| try std.testing.expectEqualStrings(id, edge.id);
    try std.testing.expectEqualStrings(sketch_id, edge.from);
    try std.testing.expectEqualStrings(details_id, edge.to);
    try std.testing.expectEqualStrings("spawn", edge.kind);
    try std.testing.expectEqualStrings(condition, edge.condition);
    try std.testing.expectEqual(fire_count, edge.fire_count);
    try std.testing.expect(edge.cycle_guard != null);
    try std.testing.expectEqual(@as(?i64, 7), edge.cycle_guard.?.max_iterations);
    try std.testing.expectEqualStrings("test -f done", edge.cycle_guard.?.until.?);
    try std.testing.expectEqual(@as(?i64, 3), edge.cycle_guard.?.stop_after_passes_without_improvement);
    try std.testing.expect(edge.payload_transform == .script);
    try std.testing.expectEqualStrings("printf 'round trip'", edge.payload_transform.script);
    const spawn_project = try envOwned("GRAPHCODE_DAEMON_ROUNDTRIP_SPAWN_PROJECT");
    defer allocator.free(spawn_project);
    try std.testing.expectEqualStrings(spawn_project, edge.spawn_target_project_path.?);
}
