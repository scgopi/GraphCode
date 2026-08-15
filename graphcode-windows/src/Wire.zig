const std = @import("std");

pub const current_version: u8 = 2;
pub const supported_versions = [_]u8{ 1, 2 };
pub const v2_max_payload: usize = 1_048_576;
pub const legacy_max_payload: usize = 2 * 1_048_576;

pub const ProtocolMode = enum {
    v1,
    v2,
};

pub const ConnectionState = enum {
    disconnected,
    connecting,
    negotiating,
    connected,
    reconnecting,
    unavailable,
    protocol_error,
};

pub const EventKind = enum {
    recent_projects,
    graph_changed,
    error_occurred,
    unknown,
};

pub const CommandKind = enum {
    list_recent_projects,
    restore_open_projects,
    open_global_graph,
    open_project,
    close_project,
    graph_command,
};

pub fn commandName(kind: CommandKind) []const u8 {
    return switch (kind) {
        .list_recent_projects => "listRecentProjects",
        .restore_open_projects => "restoreOpenProjects",
        .open_global_graph => "openGlobalGraph",
        .open_project => "openProject",
        .close_project => "closeProject",
        .graph_command => "graphCommand",
    };
}

pub fn graphCommandName(kind: []const u8) []const u8 {
    return kind;
}

pub fn frameLength(data: []const u8, mode: ProtocolMode) ![4]u8 {
    if (data.len > (if (mode == .v2) v2_max_payload else legacy_max_payload)) {
        return error.PayloadTooLarge;
    }
    const length: u32 = @intCast(data.len);
    return .{
        @intCast((length >> 24) & 0xff),
        @intCast((length >> 16) & 0xff),
        @intCast((length >> 8) & 0xff),
        @intCast(length & 0xff),
    };
}

pub fn decodedLength(header: [4]u8, mode: ProtocolMode) !usize {
    const length: usize =
        (@as(usize, header[0]) << 24) | (@as(usize, header[1]) << 16) | (@as(usize, header[2]) << 8) | @as(usize, header[3]);
    const limit = if (mode == .v2) v2_max_payload else legacy_max_payload;
    if (length > limit) return error.PayloadTooLarge;
    return length;
}

pub fn looksLikeV2(data: []const u8) bool {
    return std.mem.indexOf(u8, data, "\"version\"") != null or
        std.mem.indexOf(u8, data, "\"kind\"") != null;
}

pub fn responseRequestID(data: []const u8) ?[]const u8 {
    return jsonString(data, "requestID");
}

pub fn eventKind(data: []const u8) EventKind {
    if (std.mem.indexOf(u8, data, "\"recentProjectsListed\"") != null) {
        return .recent_projects;
    }
    if (std.mem.indexOf(u8, data, "\"graphChanged\"") != null) {
        return .graph_changed;
    }
    if (std.mem.indexOf(u8, data, "\"errorOccurred\"") != null or
        std.mem.indexOf(u8, data, "\"error\"") != null)
    {
        return .error_occurred;
    }
    return .unknown;
}

pub fn v2Hello(
    allocator: std.mem.Allocator,
    client_id: []const u8,
    resume_from: ?u64,
    subscription_path: []const u8,
) ![]u8 {
    const subscription = if (subscription_path.len == 0)
        try allocator.dupe(u8, "")
    else blk: {
        const quoted_path = try quoteJson(allocator, subscription_path);
        defer allocator.free(quoted_path);
        break :blk try std.mem.concat(allocator, u8, &.{
            ",\"subscription\":{\"projectPaths\":[",
            quoted_path,
            "]}",
        });
    };
    defer allocator.free(subscription);
    if (resume_from) |cursor| {
        const cursor_text = try std.fmt.allocPrint(allocator, "{d}", .{cursor});
        defer allocator.free(cursor_text);
        return std.mem.concat(allocator, u8, &.{
            "{\"version\":2,\"kind\":\"hello\",\"supportedVersions\":[1,2],\"clientID\":\"",
            client_id,
            "\",\"resumeFrom\":",
            cursor_text,
            subscription,
            "}",
        });
    }
    return std.mem.concat(allocator, u8, &.{
        "{\"version\":2,\"kind\":\"hello\",\"supportedVersions\":[1,2],\"clientID\":\"",
        client_id,
        "\"",
        subscription,
        "}",
    });
}

pub fn v2Request(
    allocator: std.mem.Allocator,
    request_id: []const u8,
    command_json: []const u8,
) ![]u8 {
    return std.mem.concat(allocator, u8, &.{
        "{\"version\":2,\"kind\":\"request\",\"requestID\":\"",
        request_id,
        "\",\"command\":",
        command_json,
        "}",
    });
}

pub fn v1Command(allocator: std.mem.Allocator, command_json: []const u8) ![]u8 {
    return allocator.dupe(u8, command_json);
}

pub fn commandListRecentProjects(allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8, "{\"listRecentProjects\":{}}");
}

pub fn commandRestoreOpenProjects(allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8, "{\"restoreOpenProjects\":{}}");
}

pub fn commandOpenGlobalGraph(allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8, "{\"openGlobalGraph\":{}}");
}

pub fn commandOpenProject(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const quoted_path = try quoteJson(allocator, path);
    defer allocator.free(quoted_path);
    return std.mem.concat(allocator, u8, &.{
        "{\"openProject\":{\"path\":",
        quoted_path,
        "}}",
    });
}

pub fn commandGraphCreateNode(
    allocator: std.mem.Allocator,
    project_path: []const u8,
    title: []const u8,
    node_id: []const u8,
) ![]u8 {
    const quoted_path = try quoteJson(allocator, project_path);
    defer allocator.free(quoted_path);
    const quoted_title = try quoteJson(allocator, title);
    defer allocator.free(quoted_title);
    const quoted_id = try quoteJson(allocator, node_id);
    defer allocator.free(quoted_id);
    return std.mem.concat(allocator, u8, &.{
        "{\"graphCommand\":{\"projectPath\":",
        quoted_path,
        ",\"command\":{\"createNode\":{\"_0\":{\"id\":",
        quoted_id,
        ",\"title\":",
        quoted_title,
        ",\"loopType\":\"turnBased\",\"checkDescription\":null,\"triggerPrompt\":null,\"firstInstruction\":\"Work on the requested Windows shell task.\",\"pausesBeforeWritesOnly\":false,\"goal\":null,\"backend\":\"claudeCode\",\"modelTier\":null,\"worktree\":null,\"subGraph\":null,\"createdBy\":null}}}}}",
    });
}

pub fn commandGraphNodeAction(
    allocator: std.mem.Allocator,
    project_path: []const u8,
    node_id: []const u8,
    action: []const u8,
    text: ?[]const u8,
) ![]u8 {
    const quoted_path = try quoteJson(allocator, project_path);
    defer allocator.free(quoted_path);
    const quoted_node = try quoteJson(allocator, node_id);
    defer allocator.free(quoted_node);
    if (std.mem.eql(u8, action, "messageNode")) {
        const quoted_text = try quoteJson(allocator, text orelse "");
        defer allocator.free(quoted_text);
        return std.mem.concat(allocator, u8, &.{
            "{\"graphCommand\":{\"projectPath\":",
            quoted_path,
            ",\"command\":{\"messageNode\":{\"_0\":",
            quoted_node,
            ",\"text\":",
            quoted_text,
            ",\"from\":null}}}}",
        });
    }

    if (std.mem.eql(u8, action, "stopNode")) {
        return std.mem.concat(allocator, u8, &.{
            "{\"graphCommand\":{\"projectPath\":",
            quoted_path,
            ",\"command\":{\"stopNode\":{\"_0\":",
            quoted_node,
            "}}}}",
        });
    }
    return error.UnsupportedGraphAction;
}

pub fn commandGraphRenameNode(
    allocator: std.mem.Allocator,
    project_path: []const u8,
    node_id: []const u8,
    title: []const u8,
) ![]u8 {
    const quoted_path = try quoteJson(allocator, project_path);
    defer allocator.free(quoted_path);
    const quoted_node = try quoteJson(allocator, node_id);
    defer allocator.free(quoted_node);
    const quoted_title = try quoteJson(allocator, title);
    defer allocator.free(quoted_title);
    return std.mem.concat(allocator, u8, &.{
        "{\"graphCommand\":{\"projectPath\":",   quoted_path,
        ",\"command\":{\"renameNode\":{\"_0\":", quoted_node,
        ",\"title\":",                           quoted_title,
        "}}}}",
    });
}

pub fn commandGraphCreateEdge(
    allocator: std.mem.Allocator,
    project_path: []const u8,
    from: []const u8,
    to: []const u8,
    kind: []const u8,
) ![]u8 {
    const quoted_path = try quoteJson(allocator, project_path);
    defer allocator.free(quoted_path);
    const quoted_from = try quoteJson(allocator, from);
    defer allocator.free(quoted_from);
    const quoted_to = try quoteJson(allocator, to);
    defer allocator.free(quoted_to);
    const quoted_kind = try quoteJson(allocator, kind);
    defer allocator.free(quoted_kind);
    return std.mem.concat(allocator, u8, &.{
        "{\"graphCommand\":{\"projectPath\":",                                                                                   quoted_path,
        ",\"command\":{\"createEdge\":{\"from\":",                                                                               quoted_from,
        ",\"to\":",                                                                                                              quoted_to,
        ",\"spec\":{\"kind\":",                                                                                                  quoted_kind,
        ",\"condition\":\"always\",\"payloadTransform\":{\"none\":{}},\"cycleGuard\":null,\"spawnTargetProjectPath\":null}}}}}",
    });
}

pub fn commandGraphDeleteEdge(
    allocator: std.mem.Allocator,
    project_path: []const u8,
    edge_id: []const u8,
) ![]u8 {
    const quoted_path = try quoteJson(allocator, project_path);
    defer allocator.free(quoted_path);
    const quoted_edge = try quoteJson(allocator, edge_id);
    defer allocator.free(quoted_edge);
    return std.mem.concat(allocator, u8, &.{
        "{\"graphCommand\":{\"projectPath\":",   quoted_path,
        ",\"command\":{\"deleteEdge\":{\"_0\":", quoted_edge,
        "}}}}",
    });
}

fn quoteJson(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var size: usize = 2;
    for (value) |byte| {
        size += switch (byte) {
            '"', '\\' => 2,
            0...0x1f => switch (byte) {
                '\n', '\r', '\t', '\x08', '\x0c' => 2,
                else => 6,
            },
            else => 1,
        };
    }
    const quoted = try allocator.alloc(u8, size);
    var cursor: usize = 0;
    quoted[cursor] = '"';
    cursor += 1;
    for (value) |byte| {
        switch (byte) {
            '"' => {
                quoted[cursor] = '\\';
                quoted[cursor + 1] = '"';
                cursor += 2;
            },
            '\\' => {
                quoted[cursor] = '\\';
                quoted[cursor + 1] = '\\';
                cursor += 2;
            },
            0...0x1f => {
                switch (byte) {
                    '\n' => {
                        quoted[cursor] = '\\';
                        quoted[cursor + 1] = 'n';
                        cursor += 2;
                    },
                    '\r' => {
                        quoted[cursor] = '\\';
                        quoted[cursor + 1] = 'r';
                        cursor += 2;
                    },
                    '\t' => {
                        quoted[cursor] = '\\';
                        quoted[cursor + 1] = 't';
                        cursor += 2;
                    },
                    '\x08' => {
                        quoted[cursor] = '\\';
                        quoted[cursor + 1] = 'b';
                        cursor += 2;
                    },
                    '\x0c' => {
                        quoted[cursor] = '\\';
                        quoted[cursor + 1] = 'f';
                        cursor += 2;
                    },
                    else => {
                        const digits = "0123456789abcdef";
                        quoted[cursor] = '\\';
                        quoted[cursor + 1] = 'u';
                        quoted[cursor + 2] = '0';
                        quoted[cursor + 3] = '0';
                        quoted[cursor + 4] = digits[byte >> 4];
                        quoted[cursor + 5] = digits[byte & 0x0f];
                        cursor += 6;
                    },
                }
            },
            else => {
                quoted[cursor] = byte;
                cursor += 1;
            },
        }
    }
    quoted[cursor] = '"';
    return quoted;
}

pub fn decodeJsonString(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();
    var index: usize = 0;
    while (index < value.len) {
        if (value[index] != '\\') {
            try result.append(value[index]);
            index += 1;
            continue;
        }
        index += 1;
        if (index >= value.len) return error.MalformedJsonString;
        switch (value[index]) {
            '"', '\\', '/' => try result.append(value[index]),
            'b' => try result.append('\x08'),
            'f' => try result.append('\x0c'),
            'n' => try result.append('\n'),
            'r' => try result.append('\r'),
            't' => try result.append('\t'),
            'u' => {
                if (index + 4 >= value.len) return error.MalformedJsonString;
                const high = try parseHexQuad(value[index + 1 .. index + 5]);
                index += 4;
                var codepoint: u21 = high;
                if (high >= 0xd800 and high <= 0xdbff and
                    index + 6 < value.len and value[index + 1] == '\\' and value[index + 2] == 'u')
                {
                    const low = try parseHexQuad(value[index + 3 .. index + 7]);
                    if (low >= 0xdc00 and low <= 0xdfff) {
                        codepoint = 0x10000 + (@as(u21, high - 0xd800) << 10) + (low - 0xdc00);
                        index += 6;
                    }
                }
                var encoded: [4]u8 = undefined;
                const length = std.unicode.utf8Encode(codepoint, &encoded) catch
                    return error.MalformedJsonString;
                try result.appendSlice(encoded[0..length]);
            },
            else => return error.MalformedJsonString,
        }
        index += 1;
    }
    return result.toOwnedSlice();
}

fn parseHexQuad(bytes: []const u8) !u16 {
    if (bytes.len != 4) return error.MalformedJsonString;
    var value: u16 = 0;
    for (bytes) |byte| {
        value = (value << 4) | (hexDigit(byte) orelse return error.MalformedJsonString);
    }
    return value;
}

fn hexDigit(byte: u8) ?u16 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

pub fn jsonString(data: []const u8, key: []const u8) ?[]const u8 {
    var needle_buffer: [128]u8 = undefined;
    if (key.len + 3 > needle_buffer.len) return null;
    needle_buffer[0] = '"';
    @memcpy(needle_buffer[1 .. key.len + 1], key);
    needle_buffer[key.len + 1] = '"';
    needle_buffer[key.len + 2] = ':';
    const needle = needle_buffer[0 .. key.len + 3];
    const start = std.mem.indexOf(u8, data, needle) orelse return null;
    var cursor = start + needle.len;
    while (cursor < data.len and (data[cursor] == ' ' or data[cursor] == '\t')) : (cursor += 1) {}
    if (cursor >= data.len or data[cursor] != '"') return null;
    cursor += 1;
    const value_start = cursor;
    var escaped = false;
    while (cursor < data.len) : (cursor += 1) {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (data[cursor] == '\\') {
            escaped = true;
            continue;
        }
        if (data[cursor] == '"') return data[value_start..cursor];
    }
    return null;
}

pub fn jsonNumber(data: []const u8, key: []const u8) ?u64 {
    var needle_buffer: [128]u8 = undefined;
    if (key.len + 3 > needle_buffer.len) return null;
    needle_buffer[0] = '"';
    @memcpy(needle_buffer[1 .. key.len + 1], key);
    needle_buffer[key.len + 1] = '"';
    needle_buffer[key.len + 2] = ':';
    const needle = needle_buffer[0 .. key.len + 3];
    const start = std.mem.indexOf(u8, data, needle) orelse return null;
    var cursor = start + needle.len;
    while (cursor < data.len and (data[cursor] == ' ' or data[cursor] == '\t')) : (cursor += 1) {}
    const value_start = cursor;
    while (cursor < data.len and data[cursor] >= '0' and data[cursor] <= '9') : (cursor += 1) {}
    return std.fmt.parseInt(u64, data[value_start..cursor], 10) catch null;
}

pub fn copyErrorMessage(allocator: std.mem.Allocator, data: []const u8) !?[]u8 {
    const raw = jsonString(data, "message") orelse
        (jsonString(data, "errorOccurred") orelse return null);
    return try decodeJsonString(allocator, raw);
}

test "JSON strings round-trip control characters and unicode" {
    const allocator = std.testing.allocator;
    const value = "quote \" slash \\ line\nsnowman ☃";
    const quoted = try quoteJson(allocator, value);
    defer allocator.free(quoted);
    const decoded = try decodeJsonString(allocator, quoted[1 .. quoted.len - 1]);
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings(value, decoded);
}

test "frame limits follow protocol mode" {
    const payload = try std.testing.allocator.alloc(u8, v2_max_payload + 1);
    defer std.testing.allocator.free(payload);
    try std.testing.expectError(error.PayloadTooLarge, frameLength(payload, .v2));
    const header = try frameLength(payload, .v1);
    try std.testing.expectEqual(@as(u8, 1), header[3]);
}

test "v2 hello omits subscription for the no-filter case" {
    const allocator = std.testing.allocator;
    const hello = try v2Hello(allocator, "00000000-0000-4000-8000-000000000001", null, "");
    defer allocator.free(hello);
    try std.testing.expectEqualStrings(
        "{\"version\":2,\"kind\":\"hello\",\"supportedVersions\":[1,2],\"clientID\":\"00000000-0000-4000-8000-000000000001\"}",
        hello,
    );
    const subscribed = try v2Hello(
        allocator,
        "00000000-0000-4000-8000-000000000001",
        9,
        "C:\\work\\graph",
    );
    defer allocator.free(subscribed);
    try std.testing.expectEqualStrings(
        "{\"version\":2,\"kind\":\"hello\",\"supportedVersions\":[1,2],\"clientID\":\"00000000-0000-4000-8000-000000000001\",\"resumeFrom\":9,\"subscription\":{\"projectPaths\":[\"C:\\\\work\\\\graph\"]}}",
        subscribed,
    );
}

test "graph commands match Swift Codable associated-value shapes" {
    const allocator = std.testing.allocator;
    const project = "C:\\work\\graph";
    const node = "11111111-1111-4111-8111-111111111111";
    const create = try commandGraphCreateNode(
        allocator,
        project,
        "Windows shell node",
        node,
    );
    defer allocator.free(create);
    try std.testing.expectEqualStrings(
        "{\"graphCommand\":{\"projectPath\":\"C:\\\\work\\\\graph\",\"command\":{\"createNode\":{\"_0\":{\"id\":\"11111111-1111-4111-8111-111111111111\",\"title\":\"Windows shell node\",\"loopType\":\"turnBased\",\"checkDescription\":null,\"triggerPrompt\":null,\"firstInstruction\":\"Work on the requested Windows shell task.\",\"pausesBeforeWritesOnly\":false,\"goal\":null,\"backend\":\"claudeCode\",\"modelTier\":null,\"worktree\":null,\"subGraph\":null,\"createdBy\":null}}}}}",
        create,
    );
    const message = try commandGraphNodeAction(allocator, project, node, "messageNode", "hello");
    defer allocator.free(message);
    try std.testing.expectEqualStrings(
        "{\"graphCommand\":{\"projectPath\":\"C:\\\\work\\\\graph\",\"command\":{\"messageNode\":{\"_0\":\"11111111-1111-4111-8111-111111111111\",\"text\":\"hello\",\"from\":null}}}}",
        message,
    );
    const stop = try commandGraphNodeAction(allocator, project, node, "stopNode", null);
    defer allocator.free(stop);
    try std.testing.expectEqualStrings(
        "{\"graphCommand\":{\"projectPath\":\"C:\\\\work\\\\graph\",\"command\":{\"stopNode\":{\"_0\":\"11111111-1111-4111-8111-111111111111\"}}}}",
        stop,
    );
    try std.testing.expectError(
        error.UnsupportedGraphAction,
        commandGraphNodeAction(allocator, project, node, "deleteNode", null),
    );
    const rename = try commandGraphRenameNode(allocator, project, node, "Renamed");
    defer allocator.free(rename);
    try std.testing.expect(std.mem.indexOf(u8, rename, "\"renameNode\"") != null);
    const edge = try commandGraphCreateEdge(allocator, project, node, "22222222-2222-4222-8222-222222222222", "handoff");
    defer allocator.free(edge);
    try std.testing.expectEqualStrings(
        "{\"graphCommand\":{\"projectPath\":\"C:\\\\work\\\\graph\",\"command\":{\"createEdge\":{\"from\":\"11111111-1111-4111-8111-111111111111\",\"to\":\"22222222-2222-4222-8222-222222222222\",\"spec\":{\"kind\":\"handoff\",\"condition\":\"always\",\"payloadTransform\":{\"none\":{}},\"cycleGuard\":null,\"spawnTargetProjectPath\":null}}}}}",
        edge,
    );
    const delete = try commandGraphDeleteEdge(allocator, project, "33333333-3333-4333-8333-333333333333");
    defer allocator.free(delete);
    try std.testing.expectEqualStrings(
        "{\"graphCommand\":{\"projectPath\":\"C:\\\\work\\\\graph\",\"command\":{\"deleteEdge\":{\"_0\":\"33333333-3333-4333-8333-333333333333\"}}}}",
        delete,
    );
}

test "global overview command uses the daemon command shape" {
    const command = try commandOpenGlobalGraph(std.testing.allocator);
    defer std.testing.allocator.free(command);
    try std.testing.expectEqualStrings("{\"openGlobalGraph\":{}}", command);
}
