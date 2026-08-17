const std = @import("std");
const NativeDialogs = @import("WindowsNativeDialogs.zig");
const c = @import("Win32.zig").c;

pub const Settings = struct {
    allocator: std.mem.Allocator,
    default_backend: []u8,
    default_model: []u8,
    claude_permissions: []u8,
    copilot_permissions: []u8,
    codex_approvals: []u8,
    activity: bool = false,
    briefing: bool = true,
    beta: bool = false,
    auto_selects_model: bool = false,

    pub fn init(allocator: std.mem.Allocator) !Settings {
        return parse(allocator, &.{});
    }

    pub fn deinit(self: *Settings) void {
        self.allocator.free(self.default_backend);
        self.allocator.free(self.default_model);
        self.allocator.free(self.claude_permissions);
        self.allocator.free(self.copilot_permissions);
        self.allocator.free(self.codex_approvals);
        self.* = undefined;
    }

    pub fn fields(self: Settings) [9][]const u8 {
        return .{
            self.default_backend, self.default_model, self.claude_permissions,
            self.copilot_permissions, self.codex_approvals,
            if (self.activity) "on" else "off", if (self.briefing) "on" else "off",
            if (self.beta) "on" else "off", if (self.auto_selects_model) "on" else "off",
        };
    }

    pub fn parse(allocator: std.mem.Allocator, values: []const []const u8) !Settings {
        return .{
            .allocator = allocator,
            .default_backend = try allocator.dupe(u8, if (values.len > 0 and values[0].len != 0) values[0] else "claudeCode"),
            .default_model = try allocator.dupe(u8, if (values.len > 1 and values[1].len != 0) values[1] else "standard"),
            .claude_permissions = try allocator.dupe(u8, if (values.len > 2 and values[2].len != 0) values[2] else "auto"),
            .copilot_permissions = try allocator.dupe(u8, if (values.len > 3 and values[3].len != 0) values[3] else "allowEverything"),
            .codex_approvals = try allocator.dupe(u8, if (values.len > 4 and values[4].len != 0) values[4] else "workspace"),
            .activity = values.len > 5 and std.mem.eql(u8, values[5], "on"),
            .briefing = values.len <= 6 or std.mem.eql(u8, values[6], "on"),
            .beta = values.len > 7 and std.mem.eql(u8, values[7], "on"),
            .auto_selects_model = values.len > 8 and std.mem.eql(u8, values[8], "on"),
        };
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    path: []u8,

    pub fn init(allocator: std.mem.Allocator) !Store {
        const base = std.process.getEnvVarOwned(allocator, "LOCALAPPDATA") catch
            try std.process.getEnvVarOwned(allocator, "USERPROFILE");
        defer allocator.free(base);
        const dir = try std.fs.path.join(allocator, &.{ base, "GraphCode" });
        errdefer allocator.free(dir);
        try std.fs.cwd().makePath(dir);
        const path = try std.fs.path.join(allocator, &.{ dir, "settings.ini" });
        allocator.free(dir);
        return .{ .allocator = allocator, .path = path };
    }

    pub fn deinit(self: *Store) void {
        self.allocator.free(self.path);
        self.* = undefined;
    }

    pub fn load(self: Store) !Settings {
        const data = std.fs.cwd().readFileAlloc(self.allocator, self.path, 16 * 1024) catch
            return Settings.init(self.allocator);
        defer self.allocator.free(data);
        var values: [9][]const u8 = undefined;
        values = .{ "", "", "", "", "", "", "", "", "" };
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            const pair = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = line[0..pair];
            const value = std.mem.trim(u8, line[pair + 1 ..], " \r");
            if (std.mem.eql(u8, key, "backend")) values[0] = value;
            if (std.mem.eql(u8, key, "model")) values[1] = value;
            if (std.mem.eql(u8, key, "claudePermissions")) values[2] = value;
            if (std.mem.eql(u8, key, "copilotPermissions")) values[3] = value;
            if (std.mem.eql(u8, key, "codexApprovals")) values[4] = value;
            if (std.mem.eql(u8, key, "activity")) values[5] = value;
            if (std.mem.eql(u8, key, "briefing")) values[6] = value;
            if (std.mem.eql(u8, key, "beta")) values[7] = value;
            if (std.mem.eql(u8, key, "autoSelectsModel")) values[8] = value;
        }
        return Settings.parse(self.allocator, &values);
    }

    pub fn save(self: Store, settings: Settings) !void {
        var file = try std.fs.cwd().createFile(self.path, .{ .truncate = true });
        defer file.close();
        const fields = settings.fields();
        const data = try std.fmt.allocPrint(self.allocator,
            "backend={s}\nmodel={s}\nclaudePermissions={s}\ncopilotPermissions={s}\ncodexApprovals={s}\nactivity={s}\nbriefing={s}\nbeta={s}\nautoSelectsModel={s}\n",
            .{ fields[0], fields[1], fields[2], fields[3], fields[4], fields[5], fields[6], fields[7], fields[8] },
        );
        defer self.allocator.free(data);
        try file.writeAll(data);
    }
};

pub fn open(parent: c.HWND, allocator: std.mem.Allocator, current: Settings) !?Settings {
    const fields = current.fields();
    const result = try NativeDialogs.text(parent, allocator, "GraphCode product settings", &.{
        "Default backend", "Default model tier", "Claude permissions", "Copilot permissions",
        "Activity strip (on/off)", "Graph briefing (on/off)", "Beta updates (on/off)",
        "Codex approvals", "Pick models automatically",
    }, &fields);
    var values = result orelse return null;
    defer values.deinit(allocator);
    return try Settings.parse(allocator, values.values[0..values.count]);
}

test "settings round trip preserves product choices and defaults" {
    var settings = try Settings.parse(std.testing.allocator, &.{
        "copilotCLI", "capable", "bypassPermissions", "ask", "workspace", "on", "off", "on", "on",
    });
    defer settings.deinit();
    const fields = settings.fields();
    var parsed = try Settings.parse(std.testing.allocator, &fields);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("copilotCLI", parsed.default_backend);
    try std.testing.expect(parsed.activity);
    try std.testing.expect(!parsed.briefing);
    try std.testing.expect(parsed.beta);
}
