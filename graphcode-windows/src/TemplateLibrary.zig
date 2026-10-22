const std = @import("std");
const Forms = @import("Forms.zig");
const NewLoopSheet = @import("NewLoopSheet.zig");

/// Windows reads the same human-editable markdown files as GraphcodeKit:
/// project templates take precedence over the per-user library.
pub const Template = struct {
    id: []u8,
    name: []u8,
    body: []u8,
    shape: []u8,
    done_check: ?[]u8 = null,
    cadence: ?[]u8 = null,
    pauses_before_writes_only: ?bool = null,
    branch: ?[]u8 = null,
    metric: ?[]u8 = null,
    backend: ?[]u8 = null,
    graph_json: ?[]u8 = null,

    pub fn deinit(self: *Template, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.body);
        allocator.free(self.shape);
        inline for (.{ "done_check", "cadence", "branch", "metric", "backend", "graph_json" }) |field|
            if (@field(self, field)) |value| allocator.free(value);
    }
};

pub const Library = struct {
    templates: std.array_list.Managed(Template),

    pub fn init(allocator: std.mem.Allocator) Library {
        return .{ .templates = std.array_list.Managed(Template).init(allocator) };
    }

    pub fn deinit(self: *Library) void {
        for (self.templates.items) |*template| template.deinit(self.templates.allocator);
        self.templates.deinit();
    }
};

pub fn load(allocator: std.mem.Allocator, project_path: []const u8) !Library {
    var library = Library.init(allocator);
    errdefer library.deinit();
    if (isFilesystemProject(project_path)) {
        const project = try projectDirectory(allocator, project_path);
        defer allocator.free(project);
        try loadDirectory(&library, project);
    }
    const home = try homeDirectory(allocator);
    defer allocator.free(home);
    try loadDirectory(&library, home);
    return library;
}

pub fn apply(draft: *Forms.NodeDraft, template: Template, allocator: std.mem.Allocator) !void {
    const shape = normalizeShape(template.shape);
    try replace(allocator, &draft.loop_type, shape);
    if (std.mem.eql(u8, shape, "proactive") and std.mem.trim(u8, draft.title, " \t\r\n").len == 0)
        try replace(allocator, &draft.title, template.name);
    try applyFields(draft, template, allocator, replace);
}

/// Applies to a draft returned by NativeForms, whose editable values are all
/// allocator-owned. This preserves other in-progress form edits without leaking
/// the values that the selected template replaces.
pub fn applyOwned(draft: *Forms.NodeDraft, template: Template, allocator: std.mem.Allocator) !void {
    const shape = normalizeShape(template.shape);
    try replaceOwned(allocator, &draft.loop_type, shape);
    if (std.mem.eql(u8, shape, "proactive") and std.mem.trim(u8, draft.title, " \t\r\n").len == 0)
        try replaceOwned(allocator, &draft.title, template.name);
    try applyFields(draft, template, allocator, replaceOwned);
}

fn applyFields(
    draft: *Forms.NodeDraft,
    template: Template,
    allocator: std.mem.Allocator,
    replaceFn: anytype,
) !void {
    const shape = normalizeShape(template.shape);
    if (std.mem.eql(u8, shape, "goalBased")) {
        try replaceFn(allocator, &draft.goal_summary, template.body);
    } else if (std.mem.eql(u8, shape, "timeBased")) {
        try replaceFn(allocator, &draft.trigger_prompt, template.body);
        if (template.cadence) |cadence|
            draft.heartbeat_interval_seconds = try NewLoopSheet.cadenceSeconds(cadence, "");
    } else if (std.mem.eql(u8, shape, "proactive")) {
        if (template.graph_json) |graph| try replaceFn(allocator, &draft.subgraph_json, graph);
    } else {
        try replaceFn(allocator, &draft.first_instruction, template.body);
    }
    if (template.done_check) |value| try replaceFn(allocator, &draft.goal_predicate, value);
    if (template.metric) |value| try replaceFn(allocator, &draft.metric_command, value);
    if (template.backend) |value| try replaceOptionalBackend(draft, allocator, value, replaceFn);
    if (template.pauses_before_writes_only) |value| draft.pauses_before_writes_only = value;
    try replaceFn(allocator, &draft.created_from_template_id, template.id);
    if (std.mem.eql(u8, shape, "timeBased") or std.mem.eql(u8, shape, "proactive")) {
        try replaceFn(allocator, &draft.template_follow_id, template.id);
        try replaceFn(allocator, &draft.template_follow_name, template.name);
        draft.template_follow_missing = false;
    } else {
        try replaceFn(allocator, &draft.template_follow_id, "");
        try replaceFn(allocator, &draft.template_follow_name, "");
        draft.template_follow_missing = false;
    }
}

fn replaceOptionalBackend(draft: *Forms.NodeDraft, allocator: std.mem.Allocator, value: []const u8, replaceFn: anytype) !void {
    if (draft.backend) |current| {
        var target = current;
        try replaceFn(allocator, &target, value);
        draft.backend = target;
    } else {
        draft.backend = try allocator.dupe(u8, value);
    }
}

pub fn fromDraft(allocator: std.mem.Allocator, name: []const u8, draft: Forms.NodeDraft) !Template {
    const body = switch (draft.loop_type[0]) {
        'g' => draft.goal_summary,
        't' => if (std.mem.eql(u8, draft.loop_type, "timeBased")) draft.trigger_prompt else draft.first_instruction,
        'p', 'c' => draft.title,
        else => draft.first_instruction,
    };
    if (std.mem.trim(u8, name, " \t\r\n").len == 0 or std.mem.trim(u8, body, " \t\r\n").len == 0)
        return error.InvalidTemplate;
    return .{
        .id = try randomId(allocator),
        .name = try allocator.dupe(u8, name),
        .body = try allocator.dupe(u8, body),
        .shape = try allocator.dupe(u8, shapeWord(draft.loop_type)),
        .done_check = try duplicateOptional(allocator, draft.goal_predicate),
        .cadence = if (std.mem.eql(u8, draft.loop_type, "timeBased"))
            if (draft.heartbeat_interval_seconds) |seconds| try NewLoopSheet.cadenceText(allocator, seconds) else null
        else
            null,
        .metric = try duplicateOptional(allocator, draft.metric_command),
        .backend = if (draft.backend) |backend| try duplicateOptional(allocator, backend) else null,
        .graph_json = try duplicateOptional(allocator, draft.subgraph_json),
        .pauses_before_writes_only = if (std.mem.eql(u8, draft.loop_type, "turnBased"))
            draft.pauses_before_writes_only
        else
            null,
    };
}

pub fn save(allocator: std.mem.Allocator, template: Template) !void {
    const directory = try homeDirectory(allocator);
    defer allocator.free(directory);
    try std.fs.cwd().makePath(directory);
    const file_name = try fileName(allocator, template.name);
    defer allocator.free(file_name);
    const path = try std.fs.path.join(allocator, &.{ directory, file_name });
    defer allocator.free(path);
    var header = std.array_list.Managed(u8).init(allocator);
    defer header.deinit();
    try header.writer().print("---\nid: {s}\nname: {s}\nshape: {s}\n", .{ template.id, template.name, template.shape });
    if (template.done_check) |value| try header.writer().print("done-check: {s}\n", .{value});
    if (template.cadence) |value| try header.writer().print("cadence: {s}\n", .{value});
    if (template.pauses_before_writes_only == true) try header.appendSlice("pauses-before-writes-only: true\n");
    if (template.branch) |value| try header.writer().print("branch: {s}\n", .{value});
    if (template.metric) |value| try header.writer().print("metric: {s}\n", .{value});
    if (template.backend) |value| try header.writer().print("backend: {s}\n", .{value});
    if (template.graph_json) |value| try header.writer().print("graph: {s}\n", .{value});
    try header.appendSlice("---\n");
    const contents = try std.fmt.allocPrint(allocator, "{s}{s}\n", .{ header.items, template.body });
    defer allocator.free(contents);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = contents });
}

pub fn filterMatches(template: Template, query: []const u8) bool {
    return query.len == 0 or containsIgnoreCase(template.name, query) or containsIgnoreCase(template.body, query);
}

fn loadDirectory(library: *Library, directory: []const u8) !void {
    var dir = std.fs.cwd().openDir(directory, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.AccessDenied => return,
        else => return err,
    };
    defer dir.close();
    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".md")) continue;
        const text = try dir.readFileAlloc(library.templates.allocator, entry.name, 64 * 1024);
        defer library.templates.allocator.free(text);
        const template = parse(library.templates.allocator, text) catch continue;
        if (containsID(library.templates.items, template.id)) {
            var duplicate = template;
            duplicate.deinit(library.templates.allocator);
            continue;
        }
        try library.templates.append(template);
    }
}

fn parse(allocator: std.mem.Allocator, text: []const u8) !Template {
    if (!std.mem.startsWith(u8, text, "---\n")) return error.InvalidTemplate;
    const end = std.mem.indexOfPos(u8, text, 4, "---\n") orelse return error.InvalidTemplate;
    const header = text[4..end];
    const body = std.mem.trim(u8, text[end + 4 ..], " \t\r\n");
    const id = headerValue(header, "id") orelse return error.InvalidTemplate;
    const name = headerValue(header, "name") orelse return error.InvalidTemplate;
    const shape = headerValue(header, "shape") orelse "turn";
    if (body.len == 0 or !validShape(shape)) return error.InvalidTemplate;
    return .{
        .id = try allocator.dupe(u8, id),
        .name = try allocator.dupe(u8, name),
        .body = try allocator.dupe(u8, body),
        .shape = try allocator.dupe(u8, shape),
        .done_check = try duplicateHeaderValue(allocator, header, "done-check"),
        .cadence = try duplicateHeaderValue(allocator, header, "cadence"),
        .pauses_before_writes_only = if (headerValue(header, "pauses-before-writes-only")) |value|
            std.ascii.eqlIgnoreCase(value, "true")
        else
            null,
        .branch = try duplicateHeaderValue(allocator, header, "branch"),
        .metric = try duplicateHeaderValue(allocator, header, "metric"),
        .backend = try duplicateHeaderValue(allocator, header, "backend"),
        .graph_json = try duplicateHeaderValue(allocator, header, "graph"),
    };
}

fn duplicateHeaderValue(allocator: std.mem.Allocator, header: []const u8, key: []const u8) !?[]u8 {
    const value = headerValue(header, key) orelse return null;
    if (value.len == 0) return null;
    return try unwrapQuoted(allocator, value);
}

fn unwrapQuoted(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    if (value.len < 2 or
        !((value[0] == '"' and value[value.len - 1] == '"') or
            (value[0] == '\'' and value[value.len - 1] == '\'')))
        return allocator.dupe(u8, value);
    const inner = value[1 .. value.len - 1];
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();
    var index: usize = 0;
    while (index < inner.len) : (index += 1) {
        if (inner[index] == '\\' and index + 1 < inner.len and inner[index + 1] == '"') {
            try output.append('"');
            index += 1;
        } else {
            try output.append(inner[index]);
        }
    }
    return output.toOwnedSlice();
}

fn duplicateOptional(allocator: std.mem.Allocator, value: []const u8) !?[]u8 {
    if (std.mem.trim(u8, value, " \t\r\n").len == 0) return null;
    return try allocator.dupe(u8, value);
}

fn headerValue(header: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, header, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, key) or line.len <= key.len or line[key.len] != ':') continue;
        return std.mem.trim(u8, line[key.len + 1 ..], " \t\r\n");
    }
    return null;
}

fn homeDirectory(allocator: std.mem.Allocator) ![]u8 {
    const base = std.process.getEnvVarOwned(allocator, "LOCALAPPDATA") catch
        return std.process.getEnvVarOwned(allocator, "APPDATA");
    defer allocator.free(base);
    return std.fs.path.join(allocator, &.{ base, "GraphCode", "templates" });
}

fn projectDirectory(allocator: std.mem.Allocator, project_path: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ project_path, ".graphcode", "templates" });
}

fn isFilesystemProject(project_path: []const u8) bool {
    return std.mem.indexOf(u8, project_path, "://") == null;
}

fn containsID(templates: []const Template, id: []const u8) bool {
    for (templates) |template| if (std.mem.eql(u8, template.id, id)) return true;
    return false;
}

fn normalizeShape(shape: []const u8) []const u8 {
    if (std.mem.eql(u8, shape, "main") or std.mem.eql(u8, shape, "sketch")) return "sketch";
    if (std.mem.eql(u8, shape, "goal") or std.mem.eql(u8, shape, "goalBased")) return "goalBased";
    if (std.mem.eql(u8, shape, "timed") or std.mem.eql(u8, shape, "timeBased")) return "timeBased";
    if (std.mem.eql(u8, shape, "composite") or std.mem.eql(u8, shape, "proactive")) return "proactive";
    return "turnBased";
}

fn shapeWord(loop_type: []const u8) []const u8 {
    if (std.mem.eql(u8, loop_type, "sketch")) return "main";
    if (std.mem.eql(u8, loop_type, "goalBased")) return "goal";
    if (std.mem.eql(u8, loop_type, "timeBased")) return "timed";
    if (std.mem.eql(u8, loop_type, "proactive") or std.mem.eql(u8, loop_type, "composite")) return "composite";
    return "turn";
}

fn validShape(shape: []const u8) bool {
    return std.mem.eql(u8, shape, "main") or std.mem.eql(u8, shape, "sketch") or
        std.mem.eql(u8, shape, "turn") or std.mem.eql(u8, shape, "turnBased") or
        std.mem.eql(u8, shape, "goal") or std.mem.eql(u8, shape, "goalBased") or
        std.mem.eql(u8, shape, "timed") or std.mem.eql(u8, shape, "timeBased") or
        std.mem.eql(u8, shape, "composite") or std.mem.eql(u8, shape, "proactive");
}

fn replace(allocator: std.mem.Allocator, target: *[]const u8, value: []const u8) !void {
    const copy = try allocator.dupe(u8, value);
    target.* = copy;
}

fn replaceOwned(allocator: std.mem.Allocator, target: *[]const u8, value: []const u8) !void {
    const copy = try allocator.dupe(u8, value);
    allocator.free(target.*);
    target.* = copy;
}

fn randomId(allocator: std.mem.Allocator) ![]u8 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    return std.fmt.allocPrint(allocator, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        bytes[0], bytes[1], bytes[2],  bytes[3],  bytes[4],  bytes[5],  bytes[6],  bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15],
    });
}

fn fileName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    defer result.deinit();
    for (name) |byte| {
        if (std.ascii.isAlphanumeric(byte)) try result.append(std.ascii.toLower(byte)) else if (byte == ' ' or byte == '-') try result.append('-');
    }
    while (result.items.len != 0 and result.items[result.items.len - 1] == '-') _ = result.pop();
    if (result.items.len == 0) try result.appendSlice("template");
    try result.appendSlice(".md");
    return result.toOwnedSlice();
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |offset| {
        if (std.ascii.eqlIgnoreCase(haystack[offset .. offset + needle.len], needle)) return true;
    }
    return false;
}

test "template application deterministically maps prompt and shape to a draft" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var draft = Forms.NodeDraft{
        .title = try allocator.dupe(u8, ""),
        .loop_type = try allocator.dupe(u8, "turnBased"),
        .first_instruction = try allocator.dupe(u8, "old"),
        .goal_summary = try allocator.dupe(u8, ""),
        .trigger_prompt = try allocator.dupe(u8, ""),
    };
    const template = Template{
        .id = try allocator.dupe(u8, "template-id"),
        .name = try allocator.dupe(u8, "Ship checklist"),
        .body = try allocator.dupe(u8, "Verify the release."),
        .shape = try allocator.dupe(u8, "goal"),
    };
    try apply(&draft, template, allocator);
    try std.testing.expectEqualStrings("goalBased", draft.loop_type);
    try std.testing.expectEqualStrings("", draft.title);
    try std.testing.expectEqualStrings("Verify the release.", draft.goal_summary);
}

test "template search matches names and prompt text without case sensitivity" {
    const template = Template{
        .id = @constCast("id"),
        .name = @constCast("Release review"),
        .body = @constCast("Inspect the diff"),
        .shape = @constCast("turn"),
    };
    try std.testing.expect(filterMatches(template, "REVIEW"));
    try std.testing.expect(filterMatches(template, "diff"));
    try std.testing.expect(!filterMatches(template, "deploy"));
}

test "timed templates populate the scheduled prompt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var draft = Forms.NodeDraft{
        .title = try allocator.dupe(u8, ""),
        .loop_type = try allocator.dupe(u8, "turnBased"),
        .first_instruction = try allocator.dupe(u8, "old"),
        .goal_summary = try allocator.dupe(u8, ""),
        .trigger_prompt = try allocator.dupe(u8, ""),
    };
    const template = Template{
        .id = try allocator.dupe(u8, "template-id"),
        .name = try allocator.dupe(u8, "Poll"),
        .body = try allocator.dupe(u8, "Check the queue."),
        .shape = try allocator.dupe(u8, "timed"),
    };
    try apply(&draft, template, allocator);
    try std.testing.expectEqualStrings("timeBased", draft.loop_type);
    try std.testing.expectEqualStrings("Check the queue.", draft.trigger_prompt);
    try std.testing.expectEqualStrings("old", draft.first_instruction);
}

test "virtual projects do not produce filesystem template paths" {
    try std.testing.expect(!isFilesystemProject("graphcode://global"));
    try std.testing.expect(!isFilesystemProject("ssh://host/repository"));
    try std.testing.expect(!isFilesystemProject("codespace://workspace/repository"));
    try std.testing.expect(isFilesystemProject("C:\\src\\GraphCode"));
    try std.testing.expect(isFilesystemProject("\\\\server\\share\\GraphCode"));
}

test "new loop: template shapes accept Main and Composite vocabulary" {
    try std.testing.expect(validShape("main"));
    try std.testing.expect(validShape("sketch"));
    try std.testing.expect(validShape("composite"));
    try std.testing.expect(validShape("proactive"));
    try std.testing.expectEqualStrings("sketch", normalizeShape("main"));
    try std.testing.expectEqualStrings("proactive", normalizeShape("composite"));
}

test "new loop: full template settings apply editable draft metadata" {
    const allocator = std.testing.allocator;
    var draft = Forms.NodeDraft{
        .title = try allocator.dupe(u8, ""),
        .loop_type = try allocator.dupe(u8, "turnBased"),
        .first_instruction = try allocator.dupe(u8, ""),
        .goal_summary = try allocator.dupe(u8, ""),
        .goal_predicate = try allocator.dupe(u8, ""),
        .trigger_prompt = try allocator.dupe(u8, ""),
        .metric_command = try allocator.dupe(u8, ""),
        .metric_direction = try allocator.dupe(u8, "maximize"),
        .backend = try allocator.dupe(u8, "claudeCode"),
        .created_from_template_id = try allocator.dupe(u8, ""),
        .template_follow_id = try allocator.dupe(u8, ""),
        .template_follow_name = try allocator.dupe(u8, ""),
    };
    defer draft.deinit(allocator);
    var template = Template{
        .id = try allocator.dupe(u8, "11111111-1111-4111-8111-111111111111"),
        .name = try allocator.dupe(u8, "Nightly review"),
        .body = try allocator.dupe(u8, "/loop daily Review new failures"),
        .shape = try allocator.dupe(u8, "timed"),
        .done_check = try allocator.dupe(u8, "test"),
        .cadence = try allocator.dupe(u8, "6h"),
        .metric = try allocator.dupe(u8, "score"),
        .backend = try allocator.dupe(u8, "copilotCLI"),
    };
    defer template.deinit(allocator);
    try applyOwned(&draft, template, allocator);
    try std.testing.expectEqualStrings("timeBased", draft.loop_type);
    try std.testing.expectEqualStrings("/loop daily Review new failures", draft.trigger_prompt);
    try std.testing.expectEqual(@as(?f64, 21600), draft.heartbeat_interval_seconds);
    try std.testing.expectEqualStrings("test", draft.goal_predicate);
    try std.testing.expectEqualStrings("score", draft.metric_command);
    try std.testing.expectEqualStrings("copilotCLI", draft.backend.?);
    try std.testing.expectEqualStrings(template.id, draft.created_from_template_id);
    try std.testing.expectEqualStrings(template.id, draft.template_follow_id);
}

test "new loop: saved timed templates retain heartbeat cadence" {
    const allocator = std.testing.allocator;
    var saved = try fromDraft(allocator, "Report review", .{
        .title = "",
        .loop_type = "timeBased",
        .trigger_prompt = "Review new failures",
        .heartbeat_interval_seconds = 21600,
    });
    defer saved.deinit(allocator);
    try std.testing.expectEqualStrings("Review new failures", saved.body);
    try std.testing.expectEqualStrings("6h", saved.cadence.?);

    var custom = try fromDraft(allocator, "Fast review", .{
        .title = "",
        .loop_type = "timeBased",
        .trigger_prompt = "Review new failures",
        .heartbeat_interval_seconds = 90,
    });
    defer custom.deinit(allocator);
    try std.testing.expectEqualStrings("90s", custom.cadence.?);

    var directive_looking = try fromDraft(allocator, "Literal directive", .{
        .title = "",
        .loop_type = "timeBased",
        .trigger_prompt = "/loop daily Review new failures",
        .heartbeat_interval_seconds = 21600,
    });
    defer directive_looking.deinit(allocator);
    try std.testing.expectEqualStrings("/loop daily Review new failures", directive_looking.body);
    try std.testing.expectEqualStrings("6h", directive_looking.cadence.?);

    for ([_][]const u8{
        "/loop 1h Inspect reports",
        "  /every daily Inspect reports  ",
    }) |prompt| {
        var legacy = try fromDraft(allocator, "Legacy review", .{
            .title = "",
            .loop_type = "timeBased",
            .trigger_prompt = prompt,
        });
        defer legacy.deinit(allocator);
        try std.testing.expectEqualStrings(prompt, legacy.body);
        try std.testing.expectEqual(@as(?[]u8, null), legacy.cadence);
    }
}

test "new loop: composite templates carry their graph and save vocabulary" {
    const allocator = std.testing.allocator;
    var draft = Forms.NodeDraft{
        .title = try allocator.dupe(u8, ""),
        .loop_type = try allocator.dupe(u8, "turnBased"),
        .first_instruction = try allocator.dupe(u8, ""),
        .goal_summary = try allocator.dupe(u8, ""),
        .trigger_prompt = try allocator.dupe(u8, ""),
        .metric_command = try allocator.dupe(u8, ""),
        .metric_direction = try allocator.dupe(u8, "maximize"),
        .created_from_template_id = try allocator.dupe(u8, ""),
        .template_follow_id = try allocator.dupe(u8, ""),
        .template_follow_name = try allocator.dupe(u8, ""),
        .subgraph_json = try allocator.dupe(u8, ""),
    };
    defer draft.deinit(allocator);
    var template = Template{
        .id = try allocator.dupe(u8, "22222222-2222-4222-8222-222222222222"),
        .name = try allocator.dupe(u8, "Release train"),
        .body = try allocator.dupe(u8, "Release train"),
        .shape = try allocator.dupe(u8, "composite"),
        .graph_json = try allocator.dupe(u8, "{\"nodes\":[],\"edges\":[]}"),
    };
    defer template.deinit(allocator);
    try applyOwned(&draft, template, allocator);
    try std.testing.expectEqualStrings("proactive", draft.loop_type);
    try std.testing.expectEqualStrings(template.graph_json.?, draft.subgraph_json);
    var saved = try fromDraft(allocator, "Release train", draft);
    defer saved.deinit(allocator);
    try std.testing.expectEqualStrings("composite", saved.shape);
}

test "new loop: macOS quoted template settings unwrap without losing JSON quotes" {
    var template = try parse(
        std.testing.allocator,
        "---\n" ++
            "id: 33333333-3333-4333-8333-333333333333\n" ++
            "name: Shared routine\n" ++
            "shape: composite\n" ++
            "done-check: \"make test:unit\"\n" ++
            "graph: \"{\\\"nodes\\\":[],\\\"edges\\\":[]}\"\n" ++
            "---\n" ++
            "Run the routine.\n",
    );
    defer template.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("make test:unit", template.done_check.?);
    try std.testing.expectEqualStrings("{\"nodes\":[],\"edges\":[]}", template.graph_json.?);
}
