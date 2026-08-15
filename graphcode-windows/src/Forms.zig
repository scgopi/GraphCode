const std = @import("std");
const GraphModel = @import("GraphModel.zig");

pub const NodeDraft = struct {
    title: []const u8,
    loop_type: []const u8 = "turnBased",
};

pub const EdgeDraft = struct {
    from: []const u8,
    to: []const u8,
    kind: []const u8 = "handoff",
};

pub const Settings = struct {
    daemon_pipe: []const u8 = "",
    support_directory: []const u8 = "",
    reconnect_automatically: bool = true,
};

pub const FormError = error{
    EmptyTitle,
    MissingSource,
    MissingTarget,
    SameEndpoint,
    UnsupportedLoopType,
    UnsupportedEdgeKind,
};

pub fn validateNode(draft: NodeDraft) FormError!void {
    if (std.mem.trim(u8, draft.title, " \t\r\n").len == 0) return error.EmptyTitle;
    if (!std.mem.eql(u8, draft.loop_type, "turnBased") and
        !std.mem.eql(u8, draft.loop_type, "timeBased") and
        !std.mem.eql(u8, draft.loop_type, "goalBased"))
        return error.UnsupportedLoopType;
}

pub fn validateEdge(draft: EdgeDraft) FormError!void {
    if (draft.from.len == 0) return error.MissingSource;
    if (draft.to.len == 0) return error.MissingTarget;
    if (std.mem.eql(u8, draft.from, draft.to)) return error.SameEndpoint;
    if (!std.mem.eql(u8, draft.kind, "handoff") and
        !std.mem.eql(u8, draft.kind, "message") and
        !std.mem.eql(u8, draft.kind, "spawn"))
        return error.UnsupportedEdgeKind;
}

pub fn jumpTo(nodes: []const GraphModel.Node, query: []const u8, current: ?usize) ?usize {
    if (nodes.len == 0) return null;
    const needle = std.mem.trim(u8, query, " \t\r\n");
    if (needle.len == 0) return current orelse 0;
    const start = (current orelse nodes.len - 1) + 1;
    var offset: usize = 0;
    while (offset < nodes.len) : (offset += 1) {
        const index = (start + offset) % nodes.len;
        if (containsIgnoreCase(nodes[index].title, needle) or
            containsIgnoreCase(nodes[index].id, needle))
            return index;
    }
    return null;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var equal = true;
        for (needle, 0..) |byte, index| {
            if (std.ascii.toLower(haystack[start + index]) != std.ascii.toLower(byte)) {
                equal = false;
                break;
            }
        }
        if (equal) return true;
    }
    return false;
}

pub const ContextCommand = enum {
    create_node,
    edit_node,
    create_edge,
    open_node,
    stop_node,
    delete_node,
    jump,
    settings,
};

test "node and edge forms reject invalid drafts explicitly" {
    try std.testing.expectError(error.EmptyTitle, validateNode(.{ .title = " \n" }));
    try std.testing.expectError(error.SameEndpoint, validateEdge(.{ .from = "a", .to = "a" }));
    try std.testing.expectError(error.UnsupportedEdgeKind, validateEdge(.{ .from = "a", .to = "b", .kind = "bad" }));
}

test "jump navigation wraps and matches title or id case insensitively" {
    const nodes = [_]GraphModel.Node{
        .{ .id = @constCast("node-a"), .title = @constCast("Alpha"), .loop_type = @constCast(""), .state = @constCast(""), .activity = @constCast(""), .presence = @constCast("") },
        .{ .id = @constCast("node-b"), .title = @constCast("Beta"), .loop_type = @constCast(""), .state = @constCast(""), .activity = @constCast(""), .presence = @constCast("") },
    };
    try std.testing.expectEqual(@as(?usize, 1), jumpTo(&nodes, "be", 0));
    try std.testing.expectEqual(@as(?usize, 0), jumpTo(&nodes, "NODE-A", 1));
}
