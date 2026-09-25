const std = @import("std");
const Forms = @import("Forms.zig");

/// Windows reads the same human-editable markdown files as GraphcodeKit:
/// project templates take precedence over the per-user library.
pub const Template = struct {
    id: []u8,
    name: []u8,
    body: []u8,
    shape: []u8,

    pub fn deinit(self: *Template, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.body);
        allocator.free(self.shape);
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
    try replace(allocator, &draft.title, template.name);
    if (std.mem.eql(u8, shape, "goalBased")) {
        try replace(allocator, &draft.goal_summary, template.body);
    } else if (std.mem.eql(u8, shape, "timeBased")) {
        try replace(allocator, &draft.trigger_prompt, template.body);
    } else {
        try replace(allocator, &draft.first_instruction, template.body);
    }
}

/// Applies to a draft returned by NativeForms, whose editable values are all
/// allocator-owned. This preserves other in-progress form edits without leaking
/// the values that the selected template replaces.
pub fn applyOwned(draft: *Forms.NodeDraft, template: Template, allocator: std.mem.Allocator) !void {
    const shape = normalizeShape(template.shape);
    try replaceOwned(allocator, &draft.loop_type, shape);
    try replaceOwned(allocator, &draft.title, template.name);
    if (std.mem.eql(u8, shape, "goalBased")) {
        try replaceOwned(allocator, &draft.goal_summary, template.body);
    } else if (std.mem.eql(u8, shape, "timeBased")) {
        try replaceOwned(allocator, &draft.trigger_prompt, template.body);
    } else {
        try replaceOwned(allocator, &draft.first_instruction, template.body);
    }
}

pub fn fromDraft(allocator: std.mem.Allocator, name: []const u8, draft: Forms.NodeDraft) !Template {
    const body = switch (draft.loop_type[0]) {
        'g' => draft.goal_summary,
        't' => if (std.mem.eql(u8, draft.loop_type, "timeBased")) draft.trigger_prompt else draft.first_instruction,
        else => draft.first_instruction,
    };
    if (std.mem.trim(u8, name, " \t\r\n").len == 0 or std.mem.trim(u8, body, " \t\r\n").len == 0)
        return error.InvalidTemplate;
    return .{
        .id = try randomId(allocator),
        .name = try allocator.dupe(u8, name),
        .body = try allocator.dupe(u8, body),
        .shape = try allocator.dupe(u8, shapeWord(draft.loop_type)),
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
    const contents = try std.fmt.allocPrint(allocator,
        "---\nid: {s}\nname: {s}\nshape: {s}\n---\n{s}\n",
        .{ template.id, template.name, template.shape, template.body });
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
    };
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
    if (std.mem.eql(u8, shape, "goal") or std.mem.eql(u8, shape, "goalBased")) return "goalBased";
    if (std.mem.eql(u8, shape, "timed") or std.mem.eql(u8, shape, "timeBased")) return "timeBased";
    return "turnBased";
}

fn shapeWord(loop_type: []const u8) []const u8 {
    if (std.mem.eql(u8, loop_type, "goalBased")) return "goal";
    if (std.mem.eql(u8, loop_type, "timeBased")) return "timed";
    return "turn";
}

fn validShape(shape: []const u8) bool {
    return std.mem.eql(u8, shape, "turn") or std.mem.eql(u8, shape, "turnBased") or
        std.mem.eql(u8, shape, "goal") or std.mem.eql(u8, shape, "goalBased") or
        std.mem.eql(u8, shape, "timed") or std.mem.eql(u8, shape, "timeBased");
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
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15],
    });
}

fn fileName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    defer result.deinit();
    for (name) |byte| {
        if (std.ascii.isAlphanumeric(byte)) try result.append(std.ascii.toLower(byte))
        else if (byte == ' ' or byte == '-') try result.append('-');
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
    try std.testing.expectEqualStrings("Ship checklist", draft.title);
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
