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
        const backend = if (values.len > 0 and values[0].len != 0) values[0] else "claudeCode";
        const model = if (values.len > 1 and values[1].len != 0) values[1] else "standard";
        const claude = if (values.len > 2 and values[2].len != 0) values[2] else "auto";
        const copilot = if (values.len > 3 and values[3].len != 0) values[3] else "allowEverything";
        const codex = if (values.len > 4 and values[4].len != 0) values[4] else "workspace";
        if (!isOneOf(backend, &.{ "claudeCode", "copilotCLI", "codex" }) or
            !isOneOf(model, &.{ "fast", "standard", "capable" }) or
            !isOneOf(claude, &.{ "manual", "acceptEdits", "auto", "dontAsk", "bypassPermissions" }) or
            !isOneOf(copilot, &.{ "ask", "allowTools", "allowEverything" }) or
            !isOneOf(codex, &.{ "ask", "workspace", "unsandboxed" }))
            return error.InvalidSettingValue;
        return .{
            .allocator = allocator,
            .default_backend = try allocator.dupe(u8, backend),
            .default_model = try allocator.dupe(u8, model),
            .claude_permissions = try allocator.dupe(u8, claude),
            .copilot_permissions = try allocator.dupe(u8, copilot),
            .codex_approvals = try allocator.dupe(u8, codex),
            .activity = values.len > 5 and std.mem.eql(u8, values[5], "on"),
            .briefing = values.len <= 6 or std.mem.eql(u8, values[6], "on"),
            .beta = values.len > 7 and std.mem.eql(u8, values[7], "on"),
            .auto_selects_model = values.len > 8 and std.mem.eql(u8, values[8], "on"),
        };
    }
};

fn isOneOf(value: []const u8, choices: []const []const u8) bool {
    for (choices) |choice| if (std.mem.eql(u8, value, choice)) return true;
    return false;
}

pub const Store = struct {
    allocator: std.mem.Allocator,
    path: []u8,

    pub fn init(allocator: std.mem.Allocator) !Store {
        const base = resolveSupportDirectory(allocator) catch blk: {
            const profile = try std.process.getEnvVarOwned(allocator, "USERPROFILE");
            const result = try std.fs.path.join(allocator, &.{ profile, ".graphcode" });
            allocator.free(profile);
            break :blk result;
        };
        defer allocator.free(base);
        try std.fs.cwd().makePath(base);
        const path = try std.fs.path.join(allocator, &.{ base, "settings.json" });
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
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const value = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), data, .{});
        if (value != .object) return error.SettingsRootMustBeObject;
        const stringValue = struct {
            fn get(object: std.json.ObjectMap, name: []const u8, fallback: []const u8) []const u8 {
                return if (object.get(name)) |item| if (item == .string) item.string else fallback else fallback;
            }
            fn boolean(object: std.json.ObjectMap, name: []const u8, fallback: bool) bool {
                return if (object.get(name)) |item| if (item == .bool) item.bool else fallback else fallback;
            }
        };
        const object = value.object;
        return Settings.parse(self.allocator, &.{
            stringValue.get(object, "defaultBackend", "claudeCode"),
            stringValue.get(object, "defaultModelTier", "standard"),
            stringValue.get(object, "claudePermissionMode", "auto"),
            stringValue.get(object, "copilotPermissions", "allowEverything"),
            stringValue.get(object, "codexApprovals", "workspace"),
            if (stringValue.boolean(object, "showsActivityStrip", false)) "on" else "off",
            if (stringValue.boolean(object, "briefsSessionsAboutTheGraph", true)) "on" else "off",
            if (stringValue.boolean(object, "betaUpdates", false)) "on" else "off",
            if (stringValue.boolean(object, "autoSelectsModel", false)) "on" else "off",
        });
    }

    pub fn save(self: Store, settings: Settings) !void {
        const existing = std.fs.cwd().readFileAlloc(self.allocator, self.path, 1024 * 1024) catch null;
        defer if (existing) |data| self.allocator.free(data);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();
        var value = if (existing) |data|
            try std.json.parseFromSliceLeaky(std.json.Value, arena_allocator, data, .{})
        else
            try std.json.parseFromSliceLeaky(std.json.Value, arena_allocator, "{}", .{});
        if (value != .object) return error.SettingsRootMustBeObject;
        try value.object.ensureTotalCapacity(value.object.count() + 9);
        try value.object.put("defaultBackend", .{ .string = settings.default_backend });
        try value.object.put("defaultModelTier", .{ .string = settings.default_model });
        try value.object.put("claudePermissionMode", .{ .string = settings.claude_permissions });
        try value.object.put("copilotPermissions", .{ .string = settings.copilot_permissions });
        try value.object.put("codexApprovals", .{ .string = settings.codex_approvals });
        try value.object.put("briefsSessionsAboutTheGraph", .{ .bool = settings.briefing });
        try value.object.put("autoSelectsModel", .{ .bool = settings.auto_selects_model });
        try value.object.put("showsActivityStrip", .{ .bool = settings.activity });
        try value.object.put("betaUpdates", .{ .bool = settings.beta });
        const data = try std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(value, .{})});
        defer self.allocator.free(data);
        const temp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp-{d}", .{ self.path, std.time.nanoTimestamp() });
        defer self.allocator.free(temp_path);
        var file = try std.fs.cwd().createFile(temp_path, .{ .truncate = true });
        try file.writeAll(data);
        file.close();
        try atomicReplace(self.allocator, temp_path, self.path);
    }
};

fn resolveSupportDirectory(allocator: std.mem.Allocator) ![]u8 {
    const raw = std.process.getEnvVarOwned(allocator, "GRAPHCODE_SUPPORT_DIR") catch {
        const home = try std.process.getEnvVarOwned(allocator, "USERPROFILE");
        defer allocator.free(home);
        return std.fs.path.join(allocator, &.{ home, ".graphcode" });
    };
    defer allocator.free(raw);
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len == 0) {
        const home = try std.process.getEnvVarOwned(allocator, "USERPROFILE");
        defer allocator.free(home);
        return std.fs.path.join(allocator, &.{ home, ".graphcode" });
    }
    if (std.mem.eql(u8, value, "~") or std.mem.startsWith(u8, value, "~\\") or std.mem.startsWith(u8, value, "~/")) {
        const home = try std.process.getEnvVarOwned(allocator, "USERPROFILE");
        defer allocator.free(home);
        const suffix = std.mem.trimLeft(u8, value[1..], "/\\");
        return if (suffix.len == 0) allocator.dupe(u8, home)
            else std.fs.path.join(allocator, &.{ home, suffix });
    }
    if (!std.fs.path.isAbsolute(value)) {
        const home = try std.process.getEnvVarOwned(allocator, "USERPROFILE");
        defer allocator.free(home);
        return std.fs.path.join(allocator, &.{ home, value });
    }
    return allocator.dupe(u8, value);
}

fn atomicReplace(allocator: std.mem.Allocator, temp_path: []const u8, target_path: []const u8) !void {
    _ = allocator;
    try std.os.windows.MoveFileEx(
        temp_path,
        target_path,
        std.os.windows.MOVEFILE_REPLACE_EXISTING | std.os.windows.MOVEFILE_WRITE_THROUGH,
    );
}

const Contract = struct {
    defaultBackend: ?[]const u8 = null,
    defaultModelTier: ?[]const u8 = null,
    claudePermissionMode: ?[]const u8 = null,
    copilotPermissions: ?[]const u8 = null,
    codexApprovals: ?[]const u8 = null,
    briefsSessionsAboutTheGraph: ?bool = null,
    autoSelectsModel: ?bool = null,
    showsActivityStrip: ?bool = null,
    betaUpdates: ?bool = null,
};

pub fn open(parent: c.HWND, allocator: std.mem.Allocator, current: Settings) !?Settings {
    const fields = current.fields();
    const result = try NativeDialogs.text(parent, allocator, "GraphCode product settings", &.{
        "Default backend (claudeCode|copilotCLI|codex)",
        "Default model tier (fast|standard|capable)",
        "Claude permissions (manual|acceptEdits|auto|dontAsk|bypassPermissions)",
        "Copilot permissions (ask|allowTools|allowEverything)",
        "Codex approvals (ask|workspace|unsandboxed)",
        "Activity strip (on/off)", "Graph briefing (on/off)",
        "Beta updates (on/off)", "Pick models automatically (on/off)",
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

test "settings save preserves worktree policies and unknown JSON fields" {
    const path = "graphcode-settings-preservation-test.json";
    std.fs.cwd().deleteFile(path) catch {};
    defer std.fs.cwd().deleteFile(path) catch {};
    var file = try std.fs.cwd().createFile(path, .{});
    try file.writeAll("{\"worktreePolicies\":{\"repo\":\"ask\"},\"futureFlag\":true,\"defaultBackend\":\"claudeCode\"}");
    file.close();
    var store = Store{ .allocator = std.testing.allocator, .path = try std.testing.allocator.dupe(u8, path) };
    defer store.deinit();
    var settings = try Settings.parse(std.testing.allocator, &.{ "copilotCLI", "capable", "auto", "ask", "workspace", "on", "on", "off", "on" });
    defer settings.deinit();
    try store.save(settings);
    const saved = try std.fs.cwd().readFileAlloc(std.testing.allocator, path, 4096);
    defer std.testing.allocator.free(saved);
    try std.testing.expect(std.mem.indexOf(u8, saved, "worktreePolicies") != null);
    try std.testing.expect(std.mem.indexOf(u8, saved, "futureFlag") != null);
    try std.testing.expect(std.mem.indexOf(u8, saved, "copilotCLI") != null);
}

test "settings load then save preserves unknown fields and worktree policies" {
    const path = "graphcode-settings-load-save-preservation-test.json";
    std.fs.cwd().deleteFile(path) catch {};
    defer std.fs.cwd().deleteFile(path) catch {};
    var file = try std.fs.cwd().createFile(path, .{});
    try file.writeAll("{\"worktreePolicies\":{\"repo\":\"ask\"},\"future\":{\"enabled\":true},\"defaultBackend\":\"copilotCLI\",\"defaultModelTier\":\"capable\"}");
    file.close();
    var store = Store{ .allocator = std.testing.allocator, .path = try std.testing.allocator.dupe(u8, path) };
    defer store.deinit();
    var settings = try store.load();
    defer settings.deinit();
    try std.testing.expectEqualStrings("copilotCLI", settings.default_backend);
    try std.testing.expectEqualStrings("capable", settings.default_model);
    try store.save(settings);
    const saved = try std.fs.cwd().readFileAlloc(std.testing.allocator, path, 4096);
    defer std.testing.allocator.free(saved);
    try std.testing.expect(std.mem.indexOf(u8, saved, "worktreePolicies") != null);
    try std.testing.expect(std.mem.indexOf(u8, saved, "\"future\"") != null);
}

test "settings reject values outside Swift selector enums" {
    try std.testing.expectError(error.InvalidSettingValue, Settings.parse(std.testing.allocator, &.{
        "not-a-backend", "standard", "auto", "ask", "workspace", "off", "on", "off", "off",
    }));
    try std.testing.expectError(error.InvalidSettingValue, Settings.parse(std.testing.allocator, &.{
        "claudeCode", "not-a-tier", "auto", "ask", "workspace", "off", "on", "off", "off",
    }));
}
