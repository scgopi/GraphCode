const std = @import("std");
const NativeDialogs = @import("WindowsNativeDialogs.zig");
const c = @import("Win32.zig").c;

pub const Settings = struct {
    default_backend: []const u8 = "claudeCode",
    default_model: []const u8 = "standard",
    claude_permissions: []const u8 = "auto",
    copilot_permissions: []const u8 = "allowEverything",
    activity: bool = false,
    briefing: bool = true,
    beta: bool = false,

    pub fn fields(self: Settings) [7][]const u8 {
        return .{
            self.default_backend, self.default_model, self.claude_permissions,
            self.copilot_permissions, if (self.activity) "on" else "off",
            if (self.briefing) "on" else "off", if (self.beta) "on" else "off",
        };
    }

    pub fn parse(values: []const []const u8) Settings {
        return .{
            .default_backend = if (values.len > 0) values[0] else "claudeCode",
            .default_model = if (values.len > 1) values[1] else "standard",
            .claude_permissions = if (values.len > 2) values[2] else "auto",
            .copilot_permissions = if (values.len > 3) values[3] else "allowEverything",
            .activity = values.len > 4 and std.mem.eql(u8, values[4], "on"),
            .briefing = values.len <= 5 or std.mem.eql(u8, values[5], "on"),
            .beta = values.len > 6 and std.mem.eql(u8, values[6], "on"),
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

    pub fn load(self: Store) Settings {
        const data = std.fs.cwd().readFileAlloc(self.allocator, self.path, 16 * 1024) catch return .{};
        // Settings values borrow this process-lifetime snapshot. The UI replaces the
        // snapshot only when the app exits, avoiding dangling slices after load.
        var settings = Settings{};
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            const pair = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = line[0..pair];
            const value = std.mem.trim(u8, line[pair + 1 ..], " \r");
            if (std.mem.eql(u8, key, "backend")) settings.default_backend = value;
            if (std.mem.eql(u8, key, "model")) settings.default_model = value;
            if (std.mem.eql(u8, key, "claudePermissions")) settings.claude_permissions = value;
            if (std.mem.eql(u8, key, "copilotPermissions")) settings.copilot_permissions = value;
            if (std.mem.eql(u8, key, "activity")) settings.activity = std.mem.eql(u8, value, "on");
            if (std.mem.eql(u8, key, "briefing")) settings.briefing = !std.mem.eql(u8, value, "off");
            if (std.mem.eql(u8, key, "beta")) settings.beta = std.mem.eql(u8, value, "on");
        }
        return settings;
    }

    pub fn save(self: Store, settings: Settings) !void {
        var file = try std.fs.cwd().createFile(self.path, .{ .truncate = true });
        defer file.close();
        const fields = settings.fields();
        const data = try std.fmt.allocPrint(self.allocator,
            "backend={s}\nmodel={s}\nclaudePermissions={s}\ncopilotPermissions={s}\nactivity={s}\nbriefing={s}\nbeta={s}\n",
            .{ fields[0], fields[1], fields[2], fields[3], fields[4], fields[5], fields[6] },
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
    }, &fields);
    var values = result orelse return null;
    defer values.deinit(allocator);
    return Settings.parse(values.values[0..values.count]);
}

test "settings round trip preserves product choices and defaults" {
    const settings = Settings{
        .default_backend = "copilotCLI",
        .default_model = "capable",
        .claude_permissions = "bypassPermissions",
        .copilot_permissions = "ask",
        .activity = true,
        .briefing = false,
        .beta = true,
    };
    const fields = settings.fields();
    const parsed = Settings.parse(&fields);
    try std.testing.expectEqualStrings("copilotCLI", parsed.default_backend);
    try std.testing.expect(parsed.activity);
    try std.testing.expect(!parsed.briefing);
    try std.testing.expect(parsed.beta);
}
