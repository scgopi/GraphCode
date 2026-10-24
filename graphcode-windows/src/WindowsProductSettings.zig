const std = @import("std");
const CanvasInput = @import("CanvasInput.zig");
const Win32 = @import("Win32.zig");
const c = Win32.c;
const Dpi = @import("Dpi.zig");
const AppFont = @import("AppFont.zig");
const SheetFramework = @import("SheetFramework.zig");
const TemplateLibrary = @import("TemplateLibrary.zig");
const NativeDialogs = @import("WindowsNativeDialogs.zig");
const Clipboard = @import("Clipboard.zig");

pub const Settings = struct {
    allocator: std.mem.Allocator,
    default_backend: []u8,
    default_model: []u8,
    claude_permissions: []u8,
    copilot_permissions: []u8,
    codex_approvals: []u8,
    open_code_permissions: []u8,
    pi_project_trust: []u8,
    copilot_preferred_version: []u8,
    activity: bool = false,
    briefing: bool = true,
    beta: bool = false,
    auto_selects_model: bool = false,
    summarises_loops: bool = false,
    summary_uses_model: bool = false,
    visualises_summaries: bool = false,
    daemon_heartbeat: bool = false,
    keeps_pc_awake: bool = false,
    mailroom: bool = true,
    ends_resolved_sessions_after_minutes: u16 = 10,

    pub fn init(allocator: std.mem.Allocator) !Settings {
        return parse(allocator, &.{});
    }

    pub fn deinit(self: *Settings) void {
        self.allocator.free(self.default_backend);
        self.allocator.free(self.default_model);
        self.allocator.free(self.claude_permissions);
        self.allocator.free(self.copilot_permissions);
        self.allocator.free(self.codex_approvals);
        self.allocator.free(self.open_code_permissions);
        self.allocator.free(self.pi_project_trust);
        self.allocator.free(self.copilot_preferred_version);
        self.* = undefined;
    }

    pub fn clone(self: Settings, allocator: std.mem.Allocator) !Settings {
        var values = self.fields();
        var ends_buffer: [16]u8 = undefined;
        values[18] = try std.fmt.bufPrint(&ends_buffer, "{d}", .{self.ends_resolved_sessions_after_minutes});
        return parse(allocator, &values);
    }

    pub fn fields(self: Settings) [19][]const u8 {
        return .{
            self.default_backend,                                    self.default_model,                           self.claude_permissions,
            self.copilot_permissions,                                self.codex_approvals,                         if (self.activity) "on" else "off",
            if (self.briefing) "on" else "off",                      if (self.beta) "on" else "off",               if (self.auto_selects_model) "on" else "off",
            self.open_code_permissions,                              self.pi_project_trust,                        self.copilot_preferred_version,
            if (self.summarises_loops) "on" else "off",              if (self.summary_uses_model) "on" else "off", if (self.visualises_summaries) "on" else "off",
            if (self.daemon_heartbeat) "on" else "off",              if (self.keeps_pc_awake) "on" else "off",     if (self.mailroom) "on" else "off",
            minutesValue(self.ends_resolved_sessions_after_minutes),
        };
    }

    pub fn parse(allocator: std.mem.Allocator, values: []const []const u8) !Settings {
        const backend = if (values.len > 0 and values[0].len != 0) values[0] else "claudeCode";
        const model = if (values.len > 1 and values[1].len != 0) values[1] else "standard";
        const claude = if (values.len > 2 and values[2].len != 0) values[2] else "auto";
        const copilot = if (values.len > 3 and values[3].len != 0) values[3] else "allowEverything";
        const codex = if (values.len > 4 and values[4].len != 0) values[4] else "yolo";
        const open_code = if (values.len > 9 and values[9].len != 0) values[9] else "auto";
        const pi = if (values.len > 10 and values[10].len != 0) values[10] else "approve";
        const version = if (values.len > 11) values[11] else "";
        const ends_after = if (values.len > 18 and values[18].len != 0)
            std.fmt.parseUnsigned(u16, values[18], 10) catch return error.InvalidSettingValue
        else
            10;
        if (!isOneOf(backend, &.{ "claudeCode", "copilotCLI", "codex", "openCode", "pi" }) or
            !isOneOf(model, &.{ "fast", "standard", "capable" }) or
            !isOneOf(claude, &.{ "manual", "acceptEdits", "auto", "dontAsk", "bypassPermissions" }) or
            !isOneOf(copilot, &.{ "ask", "allowTools", "allowEverything", "yoloAutopilot" }) or
            !isOneOf(codex, &.{ "ask", "workspace", "unsandboxed", "yolo" }) or
            !isOneOf(open_code, &.{ "ask", "auto" }) or
            !isOneOf(pi, &.{ "approve", "ask" }))
            return error.InvalidSettingValue;
        return .{
            .allocator = allocator,
            .default_backend = try allocator.dupe(u8, backend),
            .default_model = try allocator.dupe(u8, model),
            .claude_permissions = try allocator.dupe(u8, claude),
            .copilot_permissions = try allocator.dupe(u8, copilot),
            .codex_approvals = try allocator.dupe(u8, codex),
            .open_code_permissions = try allocator.dupe(u8, open_code),
            .pi_project_trust = try allocator.dupe(u8, pi),
            .copilot_preferred_version = try allocator.dupe(u8, version),
            .activity = values.len > 5 and std.mem.eql(u8, values[5], "on"),
            .briefing = values.len <= 6 or std.mem.eql(u8, values[6], "on"),
            .beta = values.len > 7 and std.mem.eql(u8, values[7], "on"),
            .auto_selects_model = values.len > 8 and std.mem.eql(u8, values[8], "on"),
            .summarises_loops = values.len > 12 and std.mem.eql(u8, values[12], "on"),
            .summary_uses_model = values.len > 13 and std.mem.eql(u8, values[13], "on"),
            .visualises_summaries = values.len > 14 and std.mem.eql(u8, values[14], "on"),
            .daemon_heartbeat = values.len > 15 and std.mem.eql(u8, values[15], "on"),
            .keeps_pc_awake = values.len > 16 and std.mem.eql(u8, values[16], "on"),
            .mailroom = values.len <= 17 or std.mem.eql(u8, values[17], "on"),
            .ends_resolved_sessions_after_minutes = ends_after,
        };
    }
};

fn minutesValue(value: u16) []const u8 {
    return switch (value) {
        0 => "0",
        1 => "1",
        10 => "10",
        60 => "60",
        else => "10",
    };
}

fn isOneOf(value: []const u8, choices: []const []const u8) bool {
    for (choices) |choice| if (std.mem.eql(u8, value, choice)) return true;
    return false;
}

pub const Store = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    load_failed: bool = false,

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

    pub fn load(self: *Store) !Settings {
        const data = std.fs.cwd().readFileAlloc(self.allocator, self.path, 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => {
                self.load_failed = false;
                return Settings.init(self.allocator);
            },
            else => {
                self.load_failed = true;
                return err;
            },
        };
        defer self.allocator.free(data);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const value = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), data, .{}) catch |err| {
            self.load_failed = true;
            return err;
        };
        if (value != .object) {
            self.load_failed = true;
            return error.SettingsRootMustBeObject;
        }
        const stringValue = struct {
            fn get(object: std.json.ObjectMap, name: []const u8, fallback: []const u8) []const u8 {
                return if (object.get(name)) |item| if (item == .string) item.string else fallback else fallback;
            }
            fn boolean(object: std.json.ObjectMap, name: []const u8, fallback: bool) bool {
                return if (object.get(name)) |item| if (item == .bool) item.bool else fallback else fallback;
            }
        };
        const object = value.object;
        var ends_buffer: [16]u8 = undefined;
        const ends_text = integerSettingText(object, "endsResolvedSessionsAfterMinutes", 10, &ends_buffer);
        const settings = Settings.parse(self.allocator, &.{
            stringValue.get(object, "defaultBackend", "claudeCode"),
            stringValue.get(object, "defaultModelTier", "standard"),
            stringValue.get(object, "claudePermissionMode", "auto"),
            stringValue.get(object, "copilotPermissions", "allowEverything"),
            stringValue.get(object, "codexApprovals", "yolo"),
            if (stringValue.boolean(object, "showsActivityStrip", false)) "on" else "off",
            if (stringValue.boolean(object, "briefsSessionsAboutTheGraph", true)) "on" else "off",
            if (stringValue.boolean(object, "betaUpdates", false)) "on" else "off",
            if (stringValue.boolean(object, "autoSelectsModel", false)) "on" else "off",
            stringValue.get(object, "openCodePermissions", "auto"),
            stringValue.get(object, "piProjectTrust", "approve"),
            stringValue.get(object, "copilotPreferredVersion", ""),
            if (stringValue.boolean(object, "summarisesLoops", false)) "on" else "off",
            if (stringValue.boolean(object, "summaryUsesModel", false)) "on" else "off",
            if (stringValue.boolean(object, "visualisesSummaries", false)) "on" else "off",
            if (stringValue.boolean(object, "daemonHeartbeatEnabled", false)) "on" else "off",
            if (stringValue.boolean(object, "keepsMacAwakeWhileLoopsRun", false)) "on" else "off",
            if (stringValue.boolean(object, "mailroomEnabled", true)) "on" else "off",
            ends_text,
        }) catch |err| {
            self.load_failed = true;
            return err;
        };
        self.load_failed = false;
        return settings;
    }

    pub fn save(self: Store, settings: Settings) !void {
        if (self.load_failed) return error.SettingsLoadFailed;
        const existing = std.fs.cwd().readFileAlloc(self.allocator, self.path, 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        defer if (existing) |data| self.allocator.free(data);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();
        var value = if (existing) |data|
            try std.json.parseFromSliceLeaky(std.json.Value, arena_allocator, data, .{})
        else
            try std.json.parseFromSliceLeaky(std.json.Value, arena_allocator, "{}", .{});
        if (value != .object) return error.SettingsRootMustBeObject;
        try value.object.ensureTotalCapacity(value.object.count() + 19);
        try value.object.put("defaultBackend", .{ .string = settings.default_backend });
        try value.object.put("defaultModelTier", .{ .string = settings.default_model });
        try value.object.put("claudePermissionMode", .{ .string = settings.claude_permissions });
        try value.object.put("copilotPermissions", .{ .string = settings.copilot_permissions });
        try value.object.put("codexApprovals", .{ .string = settings.codex_approvals });
        try value.object.put("openCodePermissions", .{ .string = settings.open_code_permissions });
        try value.object.put("piProjectTrust", .{ .string = settings.pi_project_trust });
        try value.object.put("copilotPreferredVersion", .{ .string = settings.copilot_preferred_version });
        try value.object.put("briefsSessionsAboutTheGraph", .{ .bool = settings.briefing });
        try value.object.put("autoSelectsModel", .{ .bool = settings.auto_selects_model });
        try value.object.put("showsActivityStrip", .{ .bool = settings.activity });
        try value.object.put("betaUpdates", .{ .bool = settings.beta });
        try value.object.put("summarisesLoops", .{ .bool = settings.summarises_loops });
        try value.object.put("summaryUsesModel", .{ .bool = settings.summary_uses_model });
        try value.object.put("visualisesSummaries", .{ .bool = settings.visualises_summaries });
        try value.object.put("daemonHeartbeatEnabled", .{ .bool = settings.daemon_heartbeat });
        try value.object.put("keepsMacAwakeWhileLoopsRun", .{ .bool = settings.keeps_pc_awake });
        try value.object.put("mailroomEnabled", .{ .bool = settings.mailroom });
        try value.object.put("endsResolvedSessionsAfterMinutes", .{ .integer = settings.ends_resolved_sessions_after_minutes });
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

fn integerSettingText(object: std.json.ObjectMap, name: []const u8, fallback: u16, buffer: *[16]u8) []const u8 {
    const item = object.get(name) orelse return minutesValue(fallback);
    if (item != .integer or item.integer < 0 or item.integer > std.math.maxInt(u16))
        return minutesValue(fallback);
    return std.fmt.bufPrint(buffer, "{d}", .{item.integer}) catch minutesValue(fallback);
}

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
        return if (suffix.len == 0) allocator.dupe(u8, home) else std.fs.path.join(allocator, &.{ home, suffix });
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
    openCodePermissions: ?[]const u8 = null,
    piProjectTrust: ?[]const u8 = null,
    copilotPreferredVersion: ?[]const u8 = null,
    summarisesLoops: ?bool = null,
    summaryUsesModel: ?bool = null,
    visualisesSummaries: ?bool = null,
    daemonHeartbeatEnabled: ?bool = null,
    keepsMacAwakeWhileLoopsRun: ?bool = null,
    mailroomEnabled: ?bool = null,
    endsResolvedSessionsAfterMinutes: ?u16 = null,
};

pub const ChangeCallback = *const fn (context: ?*anyopaque, settings: *const Settings) void;

pub fn open(
    parent_address: usize,
    allocator: std.mem.Allocator,
    store: *Store,
    current: Settings,
    project_paths: []const []const u8,
    context: ?*anyopaque,
    on_change: ?ChangeCallback,
) !void {
    const parent = windowHandle(parent_address);
    if (settings_active) return error.SettingsAlreadyOpen;
    try registerSettingsClass();
    var owned_settings = try current.clone(allocator);
    errdefer owned_settings.deinit();
    var templates = try TemplateLibrary.loadForSettings(allocator, project_paths);
    errdefer templates.deinit();
    settings_state = .{
        .allocator = allocator,
        .store = store,
        .settings = owned_settings,
        .templates = templates,
        .project_paths = project_paths,
        .context = context,
        .on_change = on_change,
        .backend = choiceIndex(current.default_backend, backend_values[0..]),
        .model = choiceIndex(current.default_model, model_values[0..]),
        .claude = choiceIndex(current.claude_permissions, claude_values[0..]),
        .copilot = choiceIndex(current.copilot_permissions, copilot_values[0..]),
        .codex = choiceIndex(current.codex_approvals, codex_values[0..]),
        .open_code = choiceIndex(current.open_code_permissions, open_code_values[0..]),
        .pi = choiceIndex(current.pi_project_trust, pi_values[0..]),
        .ends_after = choiceIndex(minutesValue(current.ends_resolved_sessions_after_minutes), ends_after_values[0..]),
        .activity = current.activity,
        .briefing = current.briefing,
        .beta = current.beta,
        .auto_model = current.auto_selects_model,
        .summarises = current.summarises_loops,
        .summary_model = current.summary_uses_model,
        .visualises = current.visualises_summaries,
        .heartbeat = current.daemon_heartbeat,
        .awake = current.keeps_pc_awake,
        .mailroom = current.mailroom,
        .preferred_version_editor = current.copilot_preferred_version.len != 0,
        .dark_mode = appsUseDarkMode(),
    };
    owned_settings = undefined;
    templates = undefined;
    settings_active = true;
    defer {
        releaseSettingsBrushes();
        settings_state.settings.deinit();
        settings_state.templates.deinit();
        settings_active = false;
    }

    settings_state.dpi = Dpi.normalize(Win32.dpiForWindow(parent));
    var host: SheetFramework.Host = .{};
    defer host.deinit();
    try createSettingsSheet(&host, parent);
    try host.runModal();
    if (settings_state.failure) |failure| return failure;
}

const backend_values = [_][]const u8{ "claudeCode", "copilotCLI", "codex", "openCode", "pi" };
const model_values = [_][]const u8{ "fast", "standard", "capable" };
const claude_values = [_][]const u8{ "manual", "acceptEdits", "auto", "dontAsk", "bypassPermissions" };
const copilot_values = [_][]const u8{ "ask", "allowTools", "allowEverything", "yoloAutopilot" };
const codex_values = [_][]const u8{ "ask", "workspace", "unsandboxed", "yolo" };
const open_code_values = [_][]const u8{ "ask", "auto" };
const pi_values = [_][]const u8{ "approve", "ask" };
const ends_after_values = [_][]const u8{ "1", "10", "60", "0" };
const backend_labels = [_][]const u8{ "Claude Code", "Copilot CLI", "Codex", "OpenCode", "Pi" };
const model_labels = [_][]const u8{ "Fast", "Standard", "Capable" };
const claude_labels = [_][]const u8{ "Ask every time", "Accept file edits", "Auto (recommended)", "Don't ask", "Bypass all checks" };
const copilot_labels = [_][]const u8{ "Ask every time", "Allow tools only", "YOLO (recommended)", "YOLO + Autopilot" };
const codex_labels = [_][]const u8{ "Ask when unsure", "Workspace (recommended)", "No sandbox", "YOLO (recommended)" };
const open_code_labels = [_][]const u8{ "Ask every time", "Auto-approve (recommended)" };
const pi_labels = [_][]const u8{ "Trust the project (recommended)", "Ask every time" };
const ends_after_labels = [_][]const u8{ "After 1 minute", "After 10 minutes", "After 1 hour", "Never" };
const claude_explanations = [_][]const u8{
    "The CLI's own default. An unattended loop will wait at the first prompt forever while the graph reports it as running.",
    "File edits go through; other tools still ask.",
    "Approves the ordinary work of a coding session and keeps its guardrails.",
    "Stops asking, without removing the checks themselves.",
    "Every permission check is skipped. A loop can do anything you can.",
};
const copilot_explanations = [_][]const u8{
    "Copilot's own default. An unattended loop will wait at the first prompt.",
    "Tools run without confirmation, but URL access and paths beyond the granted directories still prompt.",
    "Copilot's --yolo: tools, paths, and URLs all approved — what an unattended loop needs.",
};
const codex_explanations = [_][]const u8{
    "Codex's own default. An unattended loop will wait at the first prompt.",
    "Runs without asking, and may write inside the project it was given.",
    "Skips every approval and the sandbox entirely — a loop can do anything you can, anywhere.",
    "Codex's --dangerously-bypass-approvals-and-sandbox: a loop can do anything you can, anywhere.",
};
const open_code_explanations = [_][]const u8{
    "OpenCode's own default. An unattended loop will wait at the first prompt.",
    "OpenCode's --auto: everything your own opencode.json doesn't deny is approved — what an unattended loop needs.",
};
const pi_explanations = [_][]const u8{
    "pi's --approve loads project-local extensions, skills and settings without a trust prompt.",
    "pi's own default. A project with .pi resources waits at the trust prompt.",
};

const backend_id = 6112;
const claude_id = 6120;
const copilot_id = 6128;
const codex_id = 6136;
const model_id = 6144;
const auto_model_id = 6152;
const activity_id = 6160;
const briefing_id = 6168;
const beta_id = 6176;
const cancel_id = 6192;
const summarises_id = 6200;
const summary_model_id = 6201;
const visualises_id = 6202;
const heartbeat_id = 6203;
const awake_id = 6204;
const mailroom_id = 6205;
const ends_after_id = 6206;
const open_code_id = 6207;
const pi_id = 6208;
const preferred_mode_id = 6209;
const preferred_version_id = 6210;
const copy_command_id = 6211;
const template_list_id = 6212;
const template_edit_id = 6213;
const template_reveal_id = 6214;
const template_delete_id = 6215;
const nav_base_id = 6220;

const SettingsPane = enum(u8) {
    general,
    claude,
    codex,
    copilot,
    open_code,
    pi,
    templates,
};

const pane_labels = [_][]const u8{
    "General",
    "Claude Code",
    "Codex",
    "Copilot CLI",
    "OpenCode",
    "Pi",
    "Templates",
};

const SettingsDialogState = struct {
    allocator: std.mem.Allocator,
    store: *Store = undefined,
    settings: Settings = undefined,
    templates: TemplateLibrary.Library = undefined,
    project_paths: []const []const u8 = &.{},
    context: ?*anyopaque = null,
    on_change: ?ChangeCallback = null,
    backend: usize,
    model: usize,
    claude: usize,
    copilot: usize,
    codex: usize,
    open_code: usize = 1,
    pi: usize = 0,
    ends_after: usize = 1,
    activity: bool,
    briefing: bool,
    beta: bool,
    auto_model: bool,
    summarises: bool = false,
    summary_model: bool = false,
    visualises: bool = false,
    heartbeat: bool = false,
    awake: bool = false,
    mailroom: bool = true,
    preferred_version_editor: bool = false,
    ends_after_dirty: bool = false,
    pane: SettingsPane = .general,
    closed: bool = false,
    failure: ?anyerror = null,
    controls: [25]c.HWND = @splat(null),
    explanations: [16]c.HWND = @splat(null),
    navigation: [pane_labels.len]c.HWND = @splat(null),
    host: ?*SheetFramework.Host = null,
    content_root: c.HWND = null,
    panel_brush: c.HBRUSH = null,
    field_brush: c.HBRUSH = null,
    button_brush: c.HBRUSH = null,
    dark_mode: bool = false,
    dpi: u32 = Dpi.base_dpi,
};

const settings_class = std.unicode.utf8ToUtf16LeStringLiteral("GraphCodeProductSettings");
const settings_title = std.unicode.utf8ToUtf16LeStringLiteral("GraphCode Settings");
const settings_width: i32 = 760;
const settings_height: i32 = 640;
const settings_content_height: i32 = 990;
var settings_active = false;
var settings_state: SettingsDialogState = undefined;

fn choiceIndex(value: []const u8, choices: []const []const u8) usize {
    for (choices, 0..) |choice, index| if (std.mem.eql(u8, value, choice)) return index;
    return 0;
}

fn registerSettingsClass() !void {
    var klass: c.WNDCLASSW = std.mem.zeroes(c.WNDCLASSW);
    klass.lpfnWndProc = @ptrCast(&settingsWindowProc);
    klass.hInstance = c.GetModuleHandleW(null);
    klass.lpszClassName = settings_class.ptr;
    klass.hCursor = c.LoadCursorW(null, Win32.resourceIdentifier(32512));
    klass.hbrBackground = null;
    if (c.RegisterClassW(&klass) == 0 and c.GetLastError() != c.ERROR_CLASS_ALREADY_EXISTS)
        return error.SettingsClassRegistrationFailed;
}

fn createSettingsSheet(host: *SheetFramework.Host, parent: c.HWND) !void {
    try ensureSettingsBrushes();
    try host.init(parent, .{
        .layout_input = .{
            .owner = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
            .dpi = settings_state.dpi,
            .desired_width = settings_width,
            .minimum_width = 640,
            .heights = .{ .minimum = 520, .ideal = settings_height, .maximum = 920 },
            .content_extent = settings_content_height,
            .footer_height = 0,
        },
        .context = &settings_state,
        .on_layout = &layoutSettingsSheet,
        .on_message = &settingsSheetMessage,
    });
    if (c.SetWindowTextW(host.hwnd, settings_title.ptr) == 0) return error.SettingsCreationFailed;
    applySettingsWindowTheme(host.hwnd);
    const style: usize = @bitCast(c.GetWindowLongPtrW(host.hwnd, c.GWL_STYLE));
    _ = c.SetWindowLongPtrW(
        host.hwnd,
        c.GWL_STYLE,
        @bitCast(style | c.WS_CAPTION | c.WS_SYSMENU | c.WS_THICKFRAME),
    );
    _ = c.SetWindowPos(
        host.hwnd,
        null,
        0,
        0,
        0,
        0,
        c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOZORDER | c.SWP_NOACTIVATE | c.SWP_FRAMECHANGED,
    );
    settings_state.host = host;
    settings_state.content_root = c.CreateWindowExW(
        c.WS_EX_CONTROLPARENT,
        settings_class.ptr,
        null,
        c.WS_CHILD | c.WS_VISIBLE | c.WS_CLIPCHILDREN,
        0,
        0,
        0,
        0,
        host.viewport,
        null,
        c.GetModuleHandleW(null),
        null,
    ) orelse return error.SettingsCreationFailed;
    createSettingsControls(settings_state.content_root);
    applySettingsControlThemes();
    const actions = settingsFooterActions(host.hwnd, settings_state.dpi);
    try host.configureFooter(&actions);
    try host.relayout();
    _ = c.SetFocus(settings_state.navigation[0]);
}

fn ensureSettingsBrushes() !void {
    const palette = settingsPalette();
    if (settings_state.panel_brush == null)
        settings_state.panel_brush = c.CreateSolidBrush(palette.background);
    if (settings_state.field_brush == null)
        settings_state.field_brush = c.CreateSolidBrush(palette.field);
    if (settings_state.button_brush == null)
        settings_state.button_brush = c.CreateSolidBrush(palette.button);
    if (settings_state.panel_brush == null or settings_state.field_brush == null or settings_state.button_brush == null)
        return error.SettingsBrushCreationFailed;
}

const SettingsPalette = struct {
    background: u32,
    text: u32,
    muted: u32,
    field: u32,
    button: u32,
};

fn settingsPalette() SettingsPalette {
    if (settings_state.dark_mode) return .{
        .background = settingsRgb(35, 35, 38),
        .text = settingsRgb(245, 245, 247),
        .muted = settingsRgb(150, 150, 158),
        .field = settingsRgb(49, 49, 54),
        .button = settingsRgb(60, 60, 66),
    };
    return .{
        .background = c.GetSysColor(c.COLOR_WINDOW),
        .text = c.GetSysColor(c.COLOR_WINDOWTEXT),
        .muted = c.GetSysColor(c.COLOR_GRAYTEXT),
        .field = c.GetSysColor(c.COLOR_WINDOW),
        .button = c.GetSysColor(c.COLOR_BTNFACE),
    };
}

fn appsUseDarkMode() bool {
    var current_user: c.HKEY = null;
    if (c.RegOpenCurrentUser(c.KEY_QUERY_VALUE, &current_user) != c.ERROR_SUCCESS or current_user == null)
        return false;
    defer _ = c.RegCloseKey(current_user);
    var light_theme: c.DWORD = 1;
    var size: c.DWORD = @sizeOf(c.DWORD);
    const status = c.RegGetValueW(
        current_user,
        std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize").ptr,
        std.unicode.utf8ToUtf16LeStringLiteral("AppsUseLightTheme").ptr,
        c.RRF_RT_REG_DWORD,
        null,
        &light_theme,
        &size,
    );
    return status == c.ERROR_SUCCESS and light_theme == 0;
}

fn applySettingsWindowTheme(hwnd: c.HWND) void {
    const module = c.LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("dwmapi.dll").ptr) orelse return;
    defer _ = c.FreeLibrary(module);
    const address = c.GetProcAddress(module, "DwmSetWindowAttribute") orelse return;
    const Function = *const fn (c.HWND, c.DWORD, *const anyopaque, c.DWORD) callconv(.winapi) c.HRESULT;
    const function: Function = @ptrCast(address);
    var enabled: c.BOOL = @intFromBool(settings_state.dark_mode);
    _ = function(hwnd, 20, &enabled, @sizeOf(c.BOOL));
}

fn applySettingsControlThemes() void {
    const module = c.LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("uxtheme.dll").ptr) orelse return;
    defer _ = c.FreeLibrary(module);
    const address = c.GetProcAddress(module, "SetWindowTheme") orelse return;
    const Function = *const fn (c.HWND, ?[*:0]const u16, ?[*:0]const u16) callconv(.winapi) c.HRESULT;
    const function: Function = @ptrCast(address);
    const theme = if (settings_state.dark_mode)
        std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer").ptr
    else
        null;
    for (settings_state.navigation) |control| {
        if (control != null) _ = function(control, theme, null);
    }
    for (settings_state.controls) |control| {
        if (control != null) _ = function(control, theme, null);
    }
}

fn releaseSettingsBrushes() void {
    if (settings_state.button_brush != null) _ = c.DeleteObject(settings_state.button_brush);
    if (settings_state.field_brush != null) _ = c.DeleteObject(settings_state.field_brush);
    if (settings_state.panel_brush != null) _ = c.DeleteObject(settings_state.panel_brush);
    settings_state.button_brush = null;
    settings_state.field_brush = null;
    settings_state.panel_brush = null;
}

fn layoutSettingsSheet(context: ?*anyopaque, layout: SheetFramework.Layout) !void {
    const state: *SettingsDialogState = @ptrCast(@alignCast(context.?));
    if (state.host) |host| state.dpi = Dpi.normalize(host.options.layout_input.dpi);
    if (state.content_root == null) return;
    const scrollbar = if (layout.scroll.visible) SheetFramework.Metrics.forDpi(state.dpi).scrollbar_width else 0;
    if (c.MoveWindow(state.content_root, 0, -layout.scroll.offset, @max(0, layout.viewport.width - scrollbar), @max(layout.scroll.extent, layout.viewport.height), 1) == 0)
        return error.SettingsLayoutFailed;
    try layoutSettingsControls(state);
}

fn layoutSettingsControls(state: *SettingsDialogState) !void {
    const font = AppFont.getForDpi(AppFont.control_size, false, state.dpi);
    for (state.controls) |control| if (control != null) {
        _ = c.SendMessageW(control, c.WM_SETFONT, @intFromPtr(font), 1);
        _ = c.ShowWindow(control, c.SW_HIDE);
    };
    for (state.explanations) |control| if (control != null) {
        _ = c.SendMessageW(control, c.WM_SETFONT, @intFromPtr(font), 1);
        _ = c.ShowWindow(control, c.SW_HIDE);
    };
    for (state.navigation, 0..) |control, index| {
        if (control == null) continue;
        _ = c.SendMessageW(control, c.WM_SETFONT, @intFromPtr(font), 1);
        try moveSettingsControl(control, 18, 66 + @as(i32, @intCast(index)) * 42, 176, 34, state.dpi);
        _ = c.ShowWindow(control, c.SW_SHOW);
    }

    switch (state.pane) {
        .general => {
            const rows = [_]struct { index: usize, y: i32 }{
                .{ .index = 0, .y = 74 },   .{ .index = 4, .y = 154 },  .{ .index = 5, .y = 194 },
                .{ .index = 6, .y = 286 },  .{ .index = 9, .y = 356 },  .{ .index = 10, .y = 426 },
                .{ .index = 11, .y = 496 }, .{ .index = 12, .y = 566 }, .{ .index = 13, .y = 636 },
                .{ .index = 14, .y = 706 }, .{ .index = 7, .y = 776 },  .{ .index = 15, .y = 846 },
                .{ .index = 8, .y = 916 },
            };
            for (rows) |row| {
                try moveSettingsControl(state.controls[row.index], 224, row.y, 500, 30, state.dpi);
                _ = c.ShowWindow(state.controls[row.index], c.SW_SHOW);
            }
            const notes = [_]struct { index: usize, y: i32, height: i32 }{
                .{ .index = 0, .y = 108, .height = 32 },  .{ .index = 5, .y = 228, .height = 48 },
                .{ .index = 6, .y = 318, .height = 34 },  .{ .index = 9, .y = 388, .height = 34 },
                .{ .index = 10, .y = 458, .height = 34 }, .{ .index = 11, .y = 528, .height = 34 },
                .{ .index = 12, .y = 598, .height = 34 }, .{ .index = 13, .y = 668, .height = 34 },
                .{ .index = 14, .y = 738, .height = 34 }, .{ .index = 7, .y = 808, .height = 34 },
                .{ .index = 15, .y = 878, .height = 34 }, .{ .index = 8, .y = 948, .height = 34 },
            };
            for (notes) |note| {
                try moveSettingsControl(state.explanations[note.index], 236, note.y, 476, note.height, state.dpi);
                _ = c.ShowWindow(state.explanations[note.index], c.SW_SHOW);
            }
        },
        .claude, .codex, .copilot, .open_code, .pi => {
            const index: usize = switch (state.pane) {
                .claude => 1,
                .codex => 3,
                .copilot => 2,
                .open_code => 16,
                .pi => 17,
                else => unreachable,
            };
            try moveSettingsControl(state.controls[index], 224, 96, 500, 32, state.dpi);
            _ = c.ShowWindow(state.controls[index], c.SW_SHOW);
            try moveSettingsControl(state.explanations[1], 236, 138, 476, 64, state.dpi);
            _ = c.ShowWindow(state.explanations[1], c.SW_SHOW);
            if (state.pane == .copilot) {
                try moveSettingsControl(state.controls[18], 224, 250, 500, 32, state.dpi);
                try moveSettingsControl(state.controls[19], 224, 294, 386, 30, state.dpi);
                try moveSettingsControl(state.controls[20], 620, 294, 104, 30, state.dpi);
                _ = c.ShowWindow(state.controls[18], c.SW_SHOW);
                const specific = settings_state.preferred_version_editor;
                _ = c.ShowWindow(state.controls[19], if (specific) c.SW_SHOW else c.SW_HIDE);
                _ = c.ShowWindow(state.controls[20], if (specific) c.SW_SHOW else c.SW_HIDE);
            }
        },
        .templates => {
            try moveSettingsControl(state.controls[21], 224, 84, 500, 368, state.dpi);
            try moveSettingsControl(state.controls[22], 224, 468, 92, 32, state.dpi);
            try moveSettingsControl(state.controls[23], 326, 468, 92, 32, state.dpi);
            try moveSettingsControl(state.controls[24], 428, 468, 92, 32, state.dpi);
            for (state.controls[21..25]) |control| _ = c.ShowWindow(control, c.SW_SHOW);
        },
    }
    if (state.host) |host| {
        for ([_]usize{cancel_id}) |id| {
            const button = c.GetDlgItem(host.hwnd, @intCast(id));
            if (button != null) _ = c.SendMessageW(button, c.WM_SETFONT, @intFromPtr(font), 1);
        }
    }
}

fn moveSettingsControl(control: c.HWND, x: i32, y: i32, width: i32, height: i32, dpi: u32) !void {
    if (control == null) return;
    if (c.MoveWindow(control, Dpi.scale(x, dpi), Dpi.scale(y, dpi), Dpi.scale(width, dpi), Dpi.scale(height, dpi), 1) == 0)
        return error.SettingsLayoutFailed;
}

fn footerTextWidth(hwnd: c.HWND, dpi: u32, text: []const u16, fallback: i32) i32 {
    const hdc = c.GetDC(hwnd);
    if (hdc == null) return Dpi.scale(fallback, dpi);
    defer _ = c.ReleaseDC(hwnd, hdc);
    const old_font = AppFont.selectForDpi(hdc, AppFont.control_size, false);
    defer _ = c.SelectObject(hdc, old_font);
    var size: c.SIZE = undefined;
    if (c.GetTextExtentPoint32W(hdc, text.ptr, @intCast(text.len), &size) == 0)
        return Dpi.scale(fallback, dpi);
    return size.cx;
}

fn settingsFooterActions(hwnd: c.HWND, dpi: u32) [0]SheetFramework.FooterAction {
    _ = hwnd;
    _ = dpi;
    return .{};
}

fn closeSettings() void {
    settings_state.closed = true;
    if (settings_state.host) |host| host.requestClose();
}

fn handleSettingsCommand(command: u16) bool {
    if (command >= nav_base_id and command < nav_base_id + pane_labels.len) {
        setSettingsPane(@enumFromInt(command - nav_base_id));
        return true;
    }
    switch (command) {
        c.IDCANCEL, cancel_id => closeSettings(),
        backend_id => settings_state.backend = (settings_state.backend + 1) % backend_values.len,
        claude_id => settings_state.claude = (settings_state.claude + 1) % claude_values.len,
        copilot_id => settings_state.copilot = (settings_state.copilot + 1) % copilot_values.len,
        codex_id => settings_state.codex = (settings_state.codex + 1) % codex_values.len,
        open_code_id => settings_state.open_code = (settings_state.open_code + 1) % open_code_values.len,
        pi_id => settings_state.pi = (settings_state.pi + 1) % pi_values.len,
        model_id => settings_state.model = (settings_state.model + 1) % model_values.len,
        ends_after_id => {
            settings_state.ends_after = (settings_state.ends_after + 1) % ends_after_values.len;
            settings_state.ends_after_dirty = true;
        },
        auto_model_id => settings_state.auto_model = !settings_state.auto_model,
        activity_id => settings_state.activity = !settings_state.activity,
        briefing_id => settings_state.briefing = !settings_state.briefing,
        beta_id => settings_state.beta = !settings_state.beta,
        summarises_id => settings_state.summarises = !settings_state.summarises,
        summary_model_id => {
            if (settings_state.summarises) settings_state.summary_model = !settings_state.summary_model;
        },
        visualises_id => {
            if (settings_state.summarises) settings_state.visualises = !settings_state.visualises;
        },
        heartbeat_id => settings_state.heartbeat = !settings_state.heartbeat,
        awake_id => settings_state.awake = !settings_state.awake,
        mailroom_id => settings_state.mailroom = !settings_state.mailroom,
        preferred_mode_id => {
            settings_state.preferred_version_editor = !settings_state.preferred_version_editor;
            if (!settings_state.preferred_version_editor) {
                replaceSetting(&settings_state.settings.copilot_preferred_version, "") catch return failSettings(error.OutOfMemory);
                persistSettings() catch |err| return failSettings(err);
            }
            updateSettingsControls();
            layoutSettingsControls(&settings_state) catch |err| return failSettings(err);
            return true;
        },
        preferred_version_id => {
            const value = settingsControlText(settings_state.controls[19]) catch return failSettings(error.SettingsValueReadFailed);
            defer settings_state.allocator.free(value);
            replaceSetting(&settings_state.settings.copilot_preferred_version, std.mem.trim(u8, value, " \t\r\n")) catch
                return failSettings(error.OutOfMemory);
        },
        copy_command_id => {
            const command_text = copilotInstallCommand(settings_state.allocator, settings_state.settings.copilot_preferred_version) catch
                return failSettings(error.OutOfMemory);
            defer settings_state.allocator.free(command_text);
            Clipboard.writeText(settings_state.host.?.hwnd, settings_state.allocator, command_text) catch
                return failSettings(error.ClipboardWriteFailed);
            return true;
        },
        template_edit_id => return editSelectedTemplate(),
        template_reveal_id => return revealSelectedTemplate(),
        template_delete_id => return deleteSelectedTemplate(),
        else => return false,
    }
    updateSettingsControls();
    persistSettings() catch |err| return failSettings(err);
    if (settings_state.content_root != null) _ = c.InvalidateRect(settings_state.content_root, null, 0);
    return true;
}

fn failSettings(failure: anyerror) bool {
    settings_state.failure = failure;
    closeSettings();
    return true;
}

fn setSettingsPane(pane: SettingsPane) void {
    settings_state.pane = pane;
    if (settings_state.host) |host| {
        host.setContentExtent(if (pane == .general) settings_content_height else 540) catch |err| {
            _ = failSettings(err);
            return;
        };
    }
    updateSettingsControls();
    layoutSettingsControls(&settings_state) catch |err| {
        _ = failSettings(err);
        return;
    };
    if (settings_state.content_root != null) _ = c.InvalidateRect(settings_state.content_root, null, 1);
}

fn persistSettings() !void {
    try replaceSetting(&settings_state.settings.default_backend, backend_values[settings_state.backend]);
    try replaceSetting(&settings_state.settings.default_model, model_values[settings_state.model]);
    try replaceSetting(&settings_state.settings.claude_permissions, claude_values[settings_state.claude]);
    try replaceSetting(&settings_state.settings.copilot_permissions, copilot_values[settings_state.copilot]);
    try replaceSetting(&settings_state.settings.codex_approvals, codex_values[settings_state.codex]);
    try replaceSetting(&settings_state.settings.open_code_permissions, open_code_values[settings_state.open_code]);
    try replaceSetting(&settings_state.settings.pi_project_trust, pi_values[settings_state.pi]);
    settings_state.settings.activity = settings_state.activity;
    settings_state.settings.briefing = settings_state.briefing;
    settings_state.settings.beta = settings_state.beta;
    settings_state.settings.auto_selects_model = settings_state.auto_model;
    settings_state.settings.summarises_loops = settings_state.summarises;
    settings_state.settings.summary_uses_model = settings_state.summary_model;
    settings_state.settings.visualises_summaries = settings_state.visualises;
    settings_state.settings.daemon_heartbeat = settings_state.heartbeat;
    settings_state.settings.keeps_pc_awake = settings_state.awake;
    settings_state.settings.mailroom = settings_state.mailroom;
    if (settings_state.ends_after_dirty)
        settings_state.settings.ends_resolved_sessions_after_minutes =
            std.fmt.parseUnsigned(u16, ends_after_values[settings_state.ends_after], 10) catch return error.InvalidSettingValue;
    try settings_state.store.save(settings_state.settings);
    if (settings_state.on_change) |callback| callback(settings_state.context, &settings_state.settings);
}

fn replaceSetting(target: *[]u8, value: []const u8) !void {
    const replacement = try settings_state.allocator.dupe(u8, value);
    settings_state.allocator.free(target.*);
    target.* = replacement;
}

fn copilotInstallCommand(allocator: std.mem.Allocator, version_value: []const u8) ![]u8 {
    const version = std.mem.trim(u8, version_value, " \t\r\n");
    if (version.len == 0) return allocator.dupe(u8, "");
    return std.fmt.allocPrint(allocator, "npm install -g '@github/copilot@{s}'", .{version});
}

fn selectedTemplateIndex() ?usize {
    const list = settings_state.controls[21];
    if (list == null) return null;
    const selected = c.SendMessageW(list, c.LB_GETCURSEL, 0, 0);
    if (selected == c.LB_ERR or selected < 0) return null;
    const index: usize = @intCast(selected);
    return if (index < settings_state.templates.templates.items.len) index else null;
}

fn editSelectedTemplate() bool {
    const index = selectedTemplateIndex() orelse return true;
    const template = settings_state.templates.templates.items[index];
    const result = NativeDialogs.textWithDescription(
        settings_state.host.?.hwnd,
        settings_state.allocator,
        "Edit Template",
        "Changes apply to this markdown template. Timed and composite followers pick them up on their next run.",
        &.{ "Name", "Shape", "Brief", "Done check", "Cadence", "Measured by", "Branch", "Pause only before writes (true/false)" },
        &.{
            template.name,
            template.shape,
            template.body,
            template.done_check orelse "",
            template.cadence orelse "",
            template.metric orelse "",
            template.branch orelse "",
            if (template.pauses_before_writes_only == true) "true" else "false",
        },
    ) catch |err| return failSettings(err);
    if (result == null) return true;
    var values = result.?;
    defer values.deinit(settings_state.allocator);
    const name = std.mem.trim(u8, values.values[0], " \t\r\n");
    const shape = std.mem.trim(u8, values.values[1], " \t\r\n");
    const body = std.mem.trim(u8, values.values[2], " \t\r\n");
    if (name.len == 0 or body.len == 0 or !validTemplateShape(shape)) return failSettings(error.InvalidTemplate);
    const goal_shape = std.mem.eql(u8, shape, "goal") or std.mem.eql(u8, shape, "goalBased");
    const timed_shape = std.mem.eql(u8, shape, "timed") or std.mem.eql(u8, shape, "timeBased");
    const turn_shape = std.mem.eql(u8, shape, "turn") or std.mem.eql(u8, shape, "turnBased");
    var edited = TemplateLibrary.Template{
        .id = settings_state.allocator.dupe(u8, template.id) catch return failSettings(error.OutOfMemory),
        .name = settings_state.allocator.dupe(u8, name) catch return failSettings(error.OutOfMemory),
        .body = settings_state.allocator.dupe(u8, body) catch return failSettings(error.OutOfMemory),
        .shape = settings_state.allocator.dupe(u8, shape) catch return failSettings(error.OutOfMemory),
        .done_check = if (goal_shape) duplicateTrimmed(values.values[3]) catch return failSettings(error.OutOfMemory) else null,
        .cadence = if (timed_shape) duplicateTrimmed(values.values[4]) catch return failSettings(error.OutOfMemory) else null,
        .metric = if (goal_shape) duplicateTrimmed(values.values[5]) catch return failSettings(error.OutOfMemory) else null,
        .branch = duplicateTrimmed(values.values[6]) catch return failSettings(error.OutOfMemory),
        .pauses_before_writes_only = if (turn_shape)
            std.ascii.eqlIgnoreCase(std.mem.trim(u8, values.values[7], " \t\r\n"), "true")
        else
            null,
        .backend = if (template.backend) |value| settings_state.allocator.dupe(u8, value) catch return failSettings(error.OutOfMemory) else null,
        .graph_json = if (template.graph_json) |value| settings_state.allocator.dupe(u8, value) catch return failSettings(error.OutOfMemory) else null,
        .source_path = if (template.source_path) |value| settings_state.allocator.dupe(u8, value) catch return failSettings(error.OutOfMemory) else null,
        .is_project = template.is_project,
    };
    defer edited.deinit(settings_state.allocator);
    TemplateLibrary.update(settings_state.allocator, edited, template) catch |err| return failSettings(err);
    reloadTemplates() catch |err| return failSettings(err);
    return true;
}

fn duplicateTrimmed(value: []const u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    return if (trimmed.len == 0) null else try settings_state.allocator.dupe(u8, trimmed);
}

fn validTemplateShape(value: []const u8) bool {
    const shape = std.mem.trim(u8, value, " \t\r\n");
    return isOneOf(shape, &.{ "main", "goal", "timed", "turn", "composite", "sketch", "goalBased", "timeBased", "turnBased", "proactive" });
}

fn revealSelectedTemplate() bool {
    const index = selectedTemplateIndex() orelse return true;
    const path = TemplateLibrary.pathForTemplate(settings_state.allocator, settings_state.templates.templates.items[index]) catch |err|
        return failSettings(err);
    defer settings_state.allocator.free(path);
    const result = std.process.Child.run(.{
        .allocator = settings_state.allocator,
        .argv = &.{ "explorer.exe", "/select,", path },
        .max_output_bytes = 4096,
    }) catch |err| return failSettings(err);
    settings_state.allocator.free(result.stdout);
    settings_state.allocator.free(result.stderr);
    return true;
}

fn deleteSelectedTemplate() bool {
    const index = selectedTemplateIndex() orelse return true;
    const template = settings_state.templates.templates.items[index];
    const path = template.source_path orelse return failSettings(error.TemplateOriginMissing);
    const message = std.fmt.allocPrint(
        settings_state.allocator,
        "This removes {s}. Loops following it keep running on the brief they last read.",
        .{path},
    ) catch return failSettings(error.OutOfMemory);
    defer settings_state.allocator.free(message);
    const title = std.fmt.allocPrint(settings_state.allocator, "Delete “{s}”?", .{template.name}) catch
        return failSettings(error.OutOfMemory);
    defer settings_state.allocator.free(title);
    const confirmed = NativeDialogs.confirm(settings_state.host.?.hwnd, settings_state.allocator, .{
        .title = title,
        .body = message,
        .primary_action = .{ .label = "Delete template", .role = .destructive, .is_default = true },
    }) catch |err| return failSettings(err);
    if (!confirmed) return true;
    TemplateLibrary.delete(template) catch |err| return failSettings(err);
    reloadTemplates() catch |err| return failSettings(err);
    return true;
}

fn reloadTemplates() !void {
    var replacement = try TemplateLibrary.loadForSettings(settings_state.allocator, settings_state.project_paths);
    errdefer replacement.deinit();
    settings_state.templates.deinit();
    settings_state.templates = replacement;
    populateTemplateList();
}

fn settingsSheetMessage(context: ?*anyopaque, hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM, result: *c.LRESULT) bool {
    _ = context;
    switch (message) {
        c.WM_SETTINGCHANGE, c.WM_SYSCOLORCHANGE => {
            refreshSettingsAppearance(hwnd) catch |err| {
                _ = failSettings(err);
            };
            result.* = 0;
            return true;
        },
        c.WM_DRAWITEM => {
            result.* = drawFooterItem(settings_state.host.?, lparam);
            return true;
        },
        c.WM_COMMAND => {
            if (!handleSettingsCommand(@truncate(wparam))) return false;
            result.* = 0;
            return true;
        },
        c.WM_CLOSE => {
            closeSettings();
            result.* = 0;
            return true;
        },
        else => return false,
    }
}

fn drawFooterItem(host: *SheetFramework.Host, lparam: c.LPARAM) c.LRESULT {
    const item = Win32.messagePointer(*const c.DRAWITEMSTRUCT, lparam);
    var role = SheetFramework.ActionRole.secondary;
    var return_hint = false;
    for (host.footer_actions[0..host.footer_action_count]) |action| {
        if (action.id != item.CtlID) continue;
        role = action.role;
        return_hint = action.return_hint and action.role.isPrimary();
        break;
    }
    SheetFramework.drawButton(item.hDC, .{ .x = item.rcItem.left, .y = item.rcItem.top, .width = item.rcItem.right - item.rcItem.left, .height = item.rcItem.bottom - item.rcItem.top }, host.options.layout_input.dpi, role, item.itemState & c.ODS_DISABLED == 0, item.itemState & c.ODS_SELECTED != 0) catch return 0;
    var text: [128]u16 = [_]u16{0} ** 128;
    const count = c.GetWindowTextW(item.hwndItem, &text, text.len);
    const old_font = AppFont.selectForDpi(item.hDC, AppFont.control_size, false);
    defer _ = c.SelectObject(item.hDC, old_font);
    _ = c.SetBkMode(item.hDC, c.TRANSPARENT);
    _ = c.SetTextColor(item.hDC, SheetFramework.controlPaintStyle(.button, item.itemState & c.ODS_DISABLED == 0).foreground);
    var bounds = item.rcItem;
    if (return_hint) bounds.right -= SheetFramework.Metrics.forDpi(host.options.layout_input.dpi).return_hint_width;
    _ = c.DrawTextW(item.hDC, &text, count, &bounds, c.DT_CENTER | c.DT_VCENTER | c.DT_SINGLELINE);
    if (return_hint) {
        var hint_bounds = item.rcItem;
        hint_bounds.left = bounds.right;
        _ = c.DrawTextW(item.hDC, std.unicode.utf8ToUtf16LeStringLiteral("\u{21b5}").ptr, 1, &hint_bounds, c.DT_CENTER | c.DT_VCENTER | c.DT_SINGLELINE);
    }
    return 1;
}

fn settingsWindowProc(hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    const safe_hwnd: c.HWND = if (hwnd) |value| windowHandle(@intFromPtr(value)) else null;
    if (!settings_active) return c.DefWindowProcW(safe_hwnd, message, wparam, lparam);
    switch (message) {
        c.WM_NCCREATE => return 1,
        c.WM_CREATE => return 0,
        c.WM_ERASEBKGND => return 1,
        c.WM_PAINT => {
            var state: c.PAINTSTRUCT = undefined;
            const hdc = c.BeginPaint(safe_hwnd, &state);
            paintSettings(hdc);
            _ = c.EndPaint(safe_hwnd, &state);
            return 0;
        },
        c.WM_LBUTTONUP => {
            const point = CanvasInput.decodeMouseMessage(lparam);
            if (applySettingsClick(Dpi.unscale(point.x, settings_state.dpi), Dpi.unscale(point.y, settings_state.dpi))) _ = c.InvalidateRect(safe_hwnd, null, 0);
            return 0;
        },
        c.WM_COMMAND => {
            const command: u16 = @truncate(wparam);
            return if (handleSettingsCommand(command)) 0 else c.DefWindowProcW(safe_hwnd, message, wparam, lparam);
        },
        c.WM_CTLCOLORSTATIC => {
            const hdc = deviceContext(wparam);
            const palette = settingsPalette();
            _ = c.SetTextColor(hdc, palette.text);
            _ = c.SetBkColor(hdc, palette.background);
            _ = c.SetBkMode(hdc, c.OPAQUE);
            return @bitCast(@intFromPtr(settings_state.panel_brush));
        },
        c.WM_CTLCOLOREDIT, c.WM_CTLCOLORLISTBOX => {
            const hdc = deviceContext(wparam);
            const palette = settingsPalette();
            _ = c.SetTextColor(hdc, palette.text);
            _ = c.SetBkColor(hdc, palette.field);
            return @bitCast(@intFromPtr(settings_state.field_brush));
        },
        c.WM_CTLCOLORBTN => {
            const hdc = deviceContext(wparam);
            const palette = settingsPalette();
            _ = c.SetTextColor(hdc, palette.text);
            _ = c.SetBkColor(hdc, palette.button);
            return @bitCast(@intFromPtr(settings_state.button_brush));
        },
        c.WM_SETTINGCHANGE, c.WM_SYSCOLORCHANGE => {
            refreshSettingsAppearance(settings_state.host.?.hwnd) catch |err| {
                _ = failSettings(err);
            };
            return 0;
        },
        c.WM_KEYDOWN => {
            if (wparam == c.VK_ESCAPE) {
                closeSettings();
                return 0;
            }
        },
        c.WM_CLOSE => {
            closeSettings();
            return 0;
        },
        else => {},
    }
    return c.DefWindowProcW(safe_hwnd, message, wparam, lparam);
}

fn refreshSettingsAppearance(host: c.HWND) !void {
    settings_state.dark_mode = appsUseDarkMode();
    releaseSettingsBrushes();
    try ensureSettingsBrushes();
    applySettingsWindowTheme(host);
    applySettingsControlThemes();
    if (host != null) _ = c.InvalidateRect(host, null, 1);
    if (settings_state.content_root != null) _ = c.InvalidateRect(settings_state.content_root, null, 1);
}

fn applySettingsClick(x: i32, y: i32) bool {
    _ = x;
    _ = y;
    return false;
}

fn paintSettings(hdc: c.HDC) void {
    const palette = settingsPalette();
    settingsFill(hdc, scaledSettingsRect(0, 0, settings_width, settings_content_height), palette.background);
    settingsText(hdc, "Settings", scaledSettingsRect(18, 20, 194, 54), Dpi.scale(22, settings_state.dpi), palette.text, true);
    settingsText(hdc, "AGENTS", scaledSettingsRect(24, 98, 190, 120), Dpi.scale(10, settings_state.dpi), palette.muted, true);
    settingsText(hdc, pane_labels[@intFromEnum(settings_state.pane)], scaledSettingsRect(224, 24, 724, 58), Dpi.scale(22, settings_state.dpi), palette.text, true);
    if (settings_state.pane == .general) {
        settingsText(hdc, "DEFAULT BACKEND", scaledSettingsRect(224, 54, 500, 72), Dpi.scale(10, settings_state.dpi), palette.muted, true);
        settingsText(hdc, "MODEL", scaledSettingsRect(224, 136, 500, 154), Dpi.scale(10, settings_state.dpi), palette.muted, true);
        settingsText(hdc, "BEHAVIOR", scaledSettingsRect(224, 266, 500, 284), Dpi.scale(10, settings_state.dpi), palette.muted, true);
        settingsText(hdc, "UPDATES", scaledSettingsRect(224, 896, 500, 914), Dpi.scale(10, settings_state.dpi), palette.muted, true);
    } else if (settings_state.pane != .templates) {
        settingsText(hdc, "PERMISSIONS", scaledSettingsRect(224, 72, 500, 90), Dpi.scale(10, settings_state.dpi), palette.muted, true);
        if (settings_state.pane == .copilot)
            settingsText(hdc, "PREFERRED VERSIONS", scaledSettingsRect(224, 226, 500, 244), Dpi.scale(10, settings_state.dpi), palette.muted, true);
    }
}

fn createSettingsControls(hwnd: c.HWND) void {
    for (pane_labels, 0..) |label, index|
        settings_state.navigation[index] = createSettingsControl(
            hwnd,
            "BUTTON",
            label,
            c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.BS_AUTORADIOBUTTON,
            0,
            0,
            0,
            0,
            nav_base_id + index,
        );

    settings_state.controls[0] = createSettingsControl(hwnd, "BUTTON", "", buttonStyle(), 0, 0, 0, 0, backend_id);
    settings_state.controls[1] = createSettingsControl(hwnd, "BUTTON", "", buttonStyle(), 0, 0, 0, 0, claude_id);
    settings_state.controls[2] = createSettingsControl(hwnd, "BUTTON", "", buttonStyle(), 0, 0, 0, 0, copilot_id);
    settings_state.controls[3] = createSettingsControl(hwnd, "BUTTON", "", buttonStyle(), 0, 0, 0, 0, codex_id);
    settings_state.controls[4] = createSettingsControl(hwnd, "BUTTON", "", buttonStyle(), 0, 0, 0, 0, model_id);
    settings_state.controls[5] = createSettingsControl(hwnd, "BUTTON", "Pick a model for each loop", checkStyle(), 0, 0, 0, 0, auto_model_id);
    settings_state.controls[6] = createSettingsControl(hwnd, "BUTTON", "Show the activity strip", checkStyle(), 0, 0, 0, 0, activity_id);
    settings_state.controls[7] = createSettingsControl(hwnd, "BUTTON", "Tell sessions they're part of a graph", checkStyle(), 0, 0, 0, 0, briefing_id);
    settings_state.controls[8] = createSettingsControl(hwnd, "BUTTON", "Get beta releases", checkStyle(), 0, 0, 0, 0, beta_id);
    settings_state.controls[9] = createSettingsControl(hwnd, "BUTTON", "Summarise what loops are doing (experimental)", checkStyle(), 0, 0, 0, 0, summarises_id);
    settings_state.controls[10] = createSettingsControl(hwnd, "BUTTON", "Let a model write the summaries (experimental)", checkStyle(), 0, 0, 0, 0, summary_model_id);
    settings_state.controls[11] = createSettingsControl(hwnd, "BUTTON", "Visualise what loops did (experimental)", checkStyle(), 0, 0, 0, 0, visualises_id);
    settings_state.controls[12] = createSettingsControl(hwnd, "BUTTON", "Daemon heartbeat (experimental)", checkStyle(), 0, 0, 0, 0, heartbeat_id);
    settings_state.controls[13] = createSettingsControl(hwnd, "BUTTON", "Keep this PC awake while loops run (experimental)", checkStyle(), 0, 0, 0, 0, awake_id);
    settings_state.controls[14] = createSettingsControl(hwnd, "BUTTON", "Mailroom", checkStyle(), 0, 0, 0, 0, mailroom_id);
    settings_state.controls[15] = createSettingsControl(hwnd, "BUTTON", "", buttonStyle(), 0, 0, 0, 0, ends_after_id);
    settings_state.controls[16] = createSettingsControl(hwnd, "BUTTON", "", buttonStyle(), 0, 0, 0, 0, open_code_id);
    settings_state.controls[17] = createSettingsControl(hwnd, "BUTTON", "", buttonStyle(), 0, 0, 0, 0, pi_id);
    settings_state.controls[18] = createSettingsControl(hwnd, "BUTTON", "", buttonStyle(), 0, 0, 0, 0, preferred_mode_id);
    settings_state.controls[19] = createSettingsControl(hwnd, "EDIT", settings_state.settings.copilot_preferred_version, editStyle(), 0, 0, 0, 0, preferred_version_id);
    settings_state.controls[20] = createSettingsControl(hwnd, "BUTTON", "Copy", buttonStyle(), 0, 0, 0, 0, copy_command_id);
    settings_state.controls[21] = createSettingsControl(hwnd, "LISTBOX", "", listStyle(), 0, 0, 0, 0, template_list_id);
    settings_state.controls[22] = createSettingsControl(hwnd, "BUTTON", "Edit", buttonStyle(), 0, 0, 0, 0, template_edit_id);
    settings_state.controls[23] = createSettingsControl(hwnd, "BUTTON", "Reveal", buttonStyle(), 0, 0, 0, 0, template_reveal_id);
    settings_state.controls[24] = createSettingsControl(hwnd, "BUTTON", "Delete", buttonStyle(), 0, 0, 0, 0, template_delete_id);

    const explanation_text = [_][]const u8{
        "Which backend a new loop starts on. You can still change it per loop.",
        "",
        "",
        "",
        "",
        "The default model tier is copied into new loops. On, an unpinned loop is routed by its type — a per-loop model always wins.",
        "A strip along the window's bottom lists passes, hand-offs and state changes as they happen.",
        "Lets a loop create more loops when work genuinely splits.",
        "On, Check for Updates offers pre-releases as well as stable releases — newer features, less soak time.",
        "Reads each loop's current work from its own transcript. Costs nothing.",
        "One short call to your backend's CLI per change. The part that costs money.",
        "Draws each finished pass as a flowchart or table — not per change.",
        "The daemon drives timed loops on its own timer. Existing classic loops are not converted.",
        "Keeps the PC awake while loops run without keeping the display on.",
        "One place for graph mail, handoffs and notices. On by default.",
        "Once a loop resolves, its agent process ends after this delay; history and transcript remain.",
    };
    for (explanation_text, 0..) |text, index|
        settings_state.explanations[index] = createSettingsControl(hwnd, "STATIC", text, c.WS_CHILD | c.SS_LEFT, 0, 0, 0, 0, 0);

    populateTemplateList();
    updateSettingsControls();
    layoutSettingsControls(&settings_state) catch |err| {
        settings_state.failure = err;
    };
}

fn buttonStyle() c.DWORD {
    return c.WS_CHILD | c.WS_TABSTOP | c.BS_PUSHBUTTON;
}

fn checkStyle() c.DWORD {
    return c.WS_CHILD | c.WS_TABSTOP | c.BS_AUTOCHECKBOX;
}

fn editStyle() c.DWORD {
    return c.WS_CHILD | c.WS_TABSTOP | c.ES_AUTOHSCROLL;
}

fn listStyle() c.DWORD {
    return c.WS_CHILD | c.WS_TABSTOP | c.WS_VSCROLL | c.LBS_NOTIFY | c.LBS_NOINTEGRALHEIGHT;
}

fn createSettingsControl(hwnd: c.HWND, class_name: []const u8, text: []const u8, style: c.DWORD, x: i32, y: i32, width: i32, height: i32, id: usize) c.HWND {
    const wide_text = settingsWideZ(text) catch return null;
    defer settings_state.allocator.free(wide_text);
    const menu: c.HMENU = if (id == 0) null else Win32.opaquePointerFromInt(c.HMENU, id);
    const wide_class = if (std.mem.eql(u8, class_name, "BUTTON"))
        std.unicode.utf8ToUtf16LeStringLiteral("BUTTON").ptr
    else if (std.mem.eql(u8, class_name, "EDIT"))
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT").ptr
    else if (std.mem.eql(u8, class_name, "LISTBOX"))
        std.unicode.utf8ToUtf16LeStringLiteral("LISTBOX").ptr
    else
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC").ptr;
    const control = c.CreateWindowExW(0, wide_class, wide_text.ptr, style, Dpi.scale(x, settings_state.dpi), Dpi.scale(y, settings_state.dpi), Dpi.scale(width, settings_state.dpi), Dpi.scale(height, settings_state.dpi), hwnd, menu, c.GetModuleHandleW(null), null);
    AppFont.apply(control, AppFont.control_size, false);
    return control;
}

fn updateSettingsControls() void {
    setSettingsControlText(settings_state.controls[0], "New loops use: ", backend_labels[settings_state.backend]);
    setSettingsControlText(settings_state.controls[1], "Claude Code: ", claude_labels[settings_state.claude]);
    setSettingsControlText(settings_state.controls[2], "Copilot CLI: ", copilot_labels[settings_state.copilot]);
    setSettingsControlText(settings_state.controls[3], "Codex: ", codex_labels[settings_state.codex]);
    setSettingsControlText(settings_state.controls[16], "OpenCode: ", open_code_labels[settings_state.open_code]);
    setSettingsControlText(settings_state.controls[17], "Pi: ", pi_labels[settings_state.pi]);
    setSettingsControlText(settings_state.controls[4], "Default model: ", model_labels[settings_state.model]);
    if (!settings_state.ends_after_dirty and
        !isOneOfMinutes(settings_state.settings.ends_resolved_sessions_after_minutes))
    {
        var label_buffer: [64]u8 = undefined;
        const label = std.fmt.bufPrint(
            &label_buffer,
            "After {d} minutes",
            .{settings_state.settings.ends_resolved_sessions_after_minutes},
        ) catch "Custom";
        setSettingsControlText(settings_state.controls[15], "End a finished loop's session: ", label);
    } else {
        setSettingsControlText(settings_state.controls[15], "End a finished loop's session: ", ends_after_labels[settings_state.ends_after]);
    }
    setSettingsControlText(settings_state.controls[18], "Copilot CLI: ", if (settings_state.preferred_version_editor) "Specific version" else "Default");
    const agent_explanation = switch (settings_state.pane) {
        .claude => claude_explanations[settings_state.claude],
        .copilot => copilot_explanations[settings_state.copilot],
        .codex => codex_explanations[settings_state.codex],
        .open_code => open_code_explanations[settings_state.open_code],
        .pi => pi_explanations[settings_state.pi],
        else => "",
    };
    setSettingsControlText(settings_state.explanations[1], "", agent_explanation);
    setSettingsCheck(settings_state.controls[5], settings_state.auto_model);
    setSettingsCheck(settings_state.controls[6], settings_state.activity);
    setSettingsCheck(settings_state.controls[7], settings_state.briefing);
    setSettingsCheck(settings_state.controls[8], settings_state.beta);
    setSettingsCheck(settings_state.controls[9], settings_state.summarises);
    setSettingsCheck(settings_state.controls[10], settings_state.summary_model);
    setSettingsCheck(settings_state.controls[11], settings_state.visualises);
    setSettingsCheck(settings_state.controls[12], settings_state.heartbeat);
    setSettingsCheck(settings_state.controls[13], settings_state.awake);
    setSettingsCheck(settings_state.controls[14], settings_state.mailroom);
    _ = c.EnableWindow(settings_state.controls[10], @intFromBool(settings_state.summarises));
    _ = c.EnableWindow(settings_state.controls[11], @intFromBool(settings_state.summarises));
    for (settings_state.navigation, 0..) |control, index| {
        setSettingsControlText(control, "", pane_labels[index]);
        setSettingsCheck(control, index == @intFromEnum(settings_state.pane));
    }

    if (settings_state.pane == .copilot) {
        const specific = settings_state.preferred_version_editor;
        _ = c.ShowWindow(settings_state.controls[19], if (specific) c.SW_SHOW else c.SW_HIDE);
        _ = c.ShowWindow(settings_state.controls[20], if (specific) c.SW_SHOW else c.SW_HIDE);
    }
}

fn isOneOfMinutes(value: u16) bool {
    return value == 0 or value == 1 or value == 10 or value == 60;
}

fn populateTemplateList() void {
    const list = settings_state.controls[21];
    if (list == null) return;
    _ = c.SendMessageW(list, c.LB_RESETCONTENT, 0, 0);
    if (settings_state.templates.templates.items.len == 0) {
        const empty = settingsWideZ("No templates yet. Save one from the New Loop dialog (Ctrl+T), or right-click a loop that worked and choose Save as Template….") catch return;
        defer settings_state.allocator.free(empty);
        _ = c.SendMessageW(list, c.LB_ADDSTRING, 0, @bitCast(@intFromPtr(empty.ptr)));
        _ = c.EnableWindow(list, 0);
        for (settings_state.controls[22..25]) |control| _ = c.EnableWindow(control, 0);
        return;
    }
    _ = c.EnableWindow(list, 1);
    for (settings_state.templates.templates.items) |template| {
        const scope = if (template.is_project) " · in project" else "";
        const label = std.fmt.allocPrint(settings_state.allocator, "{s}{s} — {s}", .{ template.name, scope, template.shape }) catch continue;
        defer settings_state.allocator.free(label);
        const wide = settingsWideZ(label) catch continue;
        defer settings_state.allocator.free(wide);
        _ = c.SendMessageW(list, c.LB_ADDSTRING, 0, @bitCast(@intFromPtr(wide.ptr)));
    }
    _ = c.SendMessageW(list, c.LB_SETCURSEL, 0, 0);
    for (settings_state.controls[22..25]) |control| _ = c.EnableWindow(control, 1);
}

fn settingsControlText(hwnd: c.HWND) ![]u8 {
    if (hwnd == null) return error.SettingsControlUnavailable;
    const length = c.GetWindowTextLengthW(hwnd);
    if (length < 0) return error.SettingsValueReadFailed;
    const buffer = try settings_state.allocator.alloc(u16, @as(usize, @intCast(length)) + 1);
    defer settings_state.allocator.free(buffer);
    const copied = c.GetWindowTextW(hwnd, buffer.ptr, @intCast(buffer.len));
    if (copied < 0) return error.SettingsValueReadFailed;
    return std.unicode.utf16LeToUtf8Alloc(settings_state.allocator, buffer[0..@intCast(copied)]);
}

fn setSettingsControlText(hwnd: c.HWND, prefix: []const u8, value: []const u8) void {
    if (hwnd == null) return;
    const text = std.fmt.allocPrint(settings_state.allocator, "{s}{s}", .{ prefix, value }) catch return;
    defer settings_state.allocator.free(text);
    const wide = settingsWideZ(text) catch return;
    defer settings_state.allocator.free(wide);
    _ = c.SetWindowTextW(hwnd, wide.ptr);
}

fn setSettingsCheck(hwnd: c.HWND, checked: bool) void {
    if (hwnd != null) _ = c.SendMessageW(hwnd, c.BM_SETCHECK, if (checked) c.BST_CHECKED else c.BST_UNCHECKED, 0);
}

fn settingsWideZ(value: []const u8) ![]u16 {
    const raw = try std.unicode.utf8ToUtf16LeAlloc(settings_state.allocator, value);
    defer settings_state.allocator.free(raw);
    const result = try settings_state.allocator.alloc(u16, raw.len + 1);
    @memcpy(result[0..raw.len], raw);
    result[raw.len] = 0;
    return result;
}

fn windowHandle(address: usize) c.HWND {
    @setRuntimeSafety(false);
    return @ptrFromInt(address);
}

fn deviceContext(address: usize) c.HDC {
    @setRuntimeSafety(false);
    return @ptrFromInt(address);
}

fn settingsText(hdc: c.HDC, value: []const u8, bounds_value: c.RECT, size: i32, color: u32, bold: bool) void {
    const wide = std.unicode.utf8ToUtf16LeAlloc(settings_state.allocator, value) catch return;
    defer settings_state.allocator.free(wide);
    if (wide.len == 0) return;
    const face = std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI");
    const font = c.CreateFontW(-size, 0, 0, 0, if (bold) c.FW_SEMIBOLD else c.FW_NORMAL, 0, 0, 0, c.DEFAULT_CHARSET, c.OUT_DEFAULT_PRECIS, c.CLIP_DEFAULT_PRECIS, c.CLEARTYPE_QUALITY, c.DEFAULT_PITCH | c.FF_DONTCARE, face.ptr);
    const old_font = if (font != null) c.SelectObject(hdc, font) else null;
    _ = c.SetTextColor(hdc, color);
    _ = c.SetBkMode(hdc, c.TRANSPARENT);
    var bounds = bounds_value;
    const alignment: c_int = if (bounds.right - bounds.left < 150) c.DT_CENTER else c.DT_LEFT | c.DT_END_ELLIPSIS;
    const format: c.UINT = @intCast(c.DT_SINGLELINE | c.DT_VCENTER | alignment);
    _ = c.DrawTextW(hdc, wide.ptr, @intCast(wide.len), &bounds, format);
    if (font != null) {
        _ = c.SelectObject(hdc, old_font);
        _ = c.DeleteObject(font);
    }
}

fn settingsFill(hdc: c.HDC, bounds: c.RECT, color: u32) void {
    const brush = c.CreateSolidBrush(color);
    if (brush == null) return;
    _ = c.FillRect(hdc, &bounds, brush);
    _ = c.DeleteObject(brush);
}

fn settingsRect(left: i32, top: i32, right: i32, bottom: i32) c.RECT {
    return .{ .left = left, .top = top, .right = right, .bottom = bottom };
}

fn scaledSettingsRect(left: i32, top: i32, right: i32, bottom: i32) c.RECT {
    return .{
        .left = Dpi.scale(left, settings_state.dpi),
        .top = Dpi.scale(top, settings_state.dpi),
        .right = Dpi.scale(right, settings_state.dpi),
        .bottom = Dpi.scale(bottom, settings_state.dpi),
    };
}

fn inside(x: i32, y: i32, bounds: c.RECT) bool {
    return x >= bounds.left and x < bounds.right and y >= bounds.top and y < bounds.bottom;
}

fn settingsRgb(red: u8, green: u8, blue: u8) u32 {
    return @as(u32, red) | (@as(u32, green) << 8) | (@as(u32, blue) << 16);
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

test "large worktree policies survive load and save" {
    const path = "graphcode-settings-large-policy-test.json";
    std.fs.cwd().deleteFile(path) catch {};
    defer std.fs.cwd().deleteFile(path) catch {};
    var policy = std.array_list.Managed(u8).init(std.testing.allocator);
    defer policy.deinit();
    try policy.appendSlice("{\"worktreePolicies\":{\"");
    try policy.appendNTimes('x', 900 * 1024);
    try policy.appendSlice("\":\"ask\"},\"defaultBackend\":\"claudeCode\"}");
    var file = try std.fs.cwd().createFile(path, .{});
    try file.writeAll(policy.items);
    file.close();
    var store = Store{ .allocator = std.testing.allocator, .path = try std.testing.allocator.dupe(u8, path) };
    defer store.deinit();
    var settings = try store.load();
    defer settings.deinit();
    try store.save(settings);
    const saved = try std.fs.cwd().readFileAlloc(std.testing.allocator, path, 1024 * 1024);
    defer std.testing.allocator.free(saved);
    try std.testing.expect(std.mem.indexOf(u8, saved, "worktreePolicies") != null);
    try std.testing.expect(saved.len > 900 * 1024);
}

test "malformed settings surface failure and cannot overwrite without recovery" {
    const path = "graphcode-settings-malformed-test.json";
    std.fs.cwd().deleteFile(path) catch {};
    defer std.fs.cwd().deleteFile(path) catch {};
    var file = try std.fs.cwd().createFile(path, .{});
    try file.writeAll("{not-json");
    file.close();
    var store = Store{ .allocator = std.testing.allocator, .path = try std.testing.allocator.dupe(u8, path) };
    defer store.deinit();
    _ = store.load() catch {};
    var settings = try Settings.init(std.testing.allocator);
    defer settings.deinit();
    try std.testing.expectError(error.SettingsLoadFailed, store.save(settings));
}

test "settings reject values outside Swift selector enums" {
    try std.testing.expectError(error.InvalidSettingValue, Settings.parse(std.testing.allocator, &.{
        "not-a-backend", "standard", "auto", "ask", "workspace", "off", "on", "off", "off",
    }));
    try std.testing.expectError(error.InvalidSettingValue, Settings.parse(std.testing.allocator, &.{
        "claudeCode", "not-a-tier", "auto", "ask", "workspace", "off", "on", "off", "off",
    }));
}

test "purpose-built settings use native controls instead of custom hit rows" {
    try std.testing.expect(!applySettingsClick(100, 100));
    try std.testing.expectEqual(@as(c.DWORD, c.WS_CHILD | c.WS_TABSTOP | c.BS_AUTOCHECKBOX), checkStyle());
    try std.testing.expectEqual(@as(c.DWORD, c.WS_CHILD | c.WS_TABSTOP | c.BS_PUSHBUTTON), buttonStyle());
}

test "settings expose Swift permission labels and consequence copy" {
    try std.testing.expectEqualStrings("Auto (recommended)", claude_labels[2]);
    try std.testing.expectEqualStrings("YOLO (recommended)", copilot_labels[2]);
    try std.testing.expectEqualStrings("Workspace (recommended)", codex_labels[1]);
    try std.testing.expect(std.mem.indexOf(u8, claude_explanations[2], "guardrails") != null);
    try std.testing.expect(std.mem.indexOf(u8, copilot_explanations[2], "tools, paths, and URLs") != null);
    try std.testing.expect(std.mem.indexOf(u8, codex_explanations[1], "write inside the project") != null);
}

test "settings parity: sidebar exposes General five agents and Templates in macOS order" {
    const expected = [_][]const u8{
        "General",
        "Claude Code",
        "Codex",
        "Copilot CLI",
        "OpenCode",
        "Pi",
        "Templates",
    };
    try std.testing.expectEqualSlices([]const u8, expected[0..], pane_labels[0..]);
}

test "settings parity: Copilot permissions include YOLO plus Autopilot" {
    try std.testing.expectEqual(@as(usize, 4), copilot_values.len);
}

test "settings parity: Codex permissions include explicit YOLO default" {
    var settings = try Settings.init(std.testing.allocator);
    defer settings.deinit();
    try std.testing.expectEqual(@as(usize, 4), codex_values.len);
    try std.testing.expectEqualStrings("yolo", settings.codex_approvals);
}

test "settings parity: persisted model includes all General and agent choices" {
    var settings = try Settings.init(std.testing.allocator);
    defer settings.deinit();
    try std.testing.expectEqual(@as(usize, 19), settings.fields().len);
}

test "settings parity: main window has no Save or Cancel footer" {
    const actions = settingsFooterActions(null, Dpi.base_dpi);
    try std.testing.expectEqual(@as(usize, 0), actions.len);
}

test "settings parity: Return does not close the immediate-apply window" {
    settings_state = .{
        .allocator = std.testing.allocator,
        .backend = 0,
        .model = 1,
        .claude = 2,
        .copilot = 2,
        .codex = 1,
        .activity = false,
        .briefing = true,
        .beta = false,
        .auto_model = false,
    };
    try std.testing.expect(!handleSettingsCommand(c.IDOK));
    try std.testing.expect(!settings_state.closed);
}

test "settings parity: initial geometry matches resizable macOS content target" {
    try std.testing.expectEqual(@as(i32, 760), settings_width);
    try std.testing.expect(settings_height >= 520);
}

test "settings parity: OpenCode and Pi defaults match macOS" {
    try std.testing.expect(@hasField(Settings, "open_code_permissions"));
    try std.testing.expect(@hasField(Settings, "pi_project_trust"));
}

test "settings parity: summary visualisation and lifecycle defaults are represented" {
    inline for (.{
        "summarises_loops",
        "summary_uses_model",
        "visualises_summaries",
        "daemon_heartbeat",
        "keeps_pc_awake",
        "mailroom",
        "ends_resolved_sessions_after_minutes",
    }) |field| try std.testing.expect(@hasField(Settings, field));
}

test "settings parity: Copilot preferred version command preserves --yolo spelling" {
    try std.testing.expect(@hasField(Settings, "copilot_preferred_version"));
    try std.testing.expect(std.mem.indexOf(u8, copilot_explanations[2], "--yolo") != null);
}

test "settings parity: arbitrary nonnegative session grace survives cloning" {
    var settings = try Settings.init(std.testing.allocator);
    defer settings.deinit();
    settings.ends_resolved_sessions_after_minutes = 30;
    var cloned = try settings.clone(std.testing.allocator);
    defer cloned.deinit();
    try std.testing.expectEqual(@as(u16, 30), cloned.ends_resolved_sessions_after_minutes);
}

test "settings parity: appearance palette follows app theme selection" {
    settings_state.dark_mode = false;
    const light = settingsPalette();
    settings_state.dark_mode = true;
    const dark = settingsPalette();
    try std.testing.expect(light.background != dark.background);
    try std.testing.expect(light.text != dark.text);
}

fn hiddenSettingsOwner() !c.HWND {
    return c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC").ptr,
        null,
        c.WS_POPUP,
        20,
        20,
        960,
        760,
        null,
        null,
        c.GetModuleHandleW(null),
        null,
    ) orelse error.SettingsCreationFailed;
}

test "dialog framework: product settings uses hidden rounded sheet with overflow viewport" {
    try registerSettingsClass();
    const owner = try hiddenSettingsOwner();
    defer _ = c.DestroyWindow(owner);
    var store = Store{ .allocator = std.testing.allocator, .path = try std.testing.allocator.dupe(u8, "unused-settings.json") };
    defer store.deinit();
    var settings = try Settings.init(std.testing.allocator);
    errdefer settings.deinit();
    var templates = TemplateLibrary.Library.init(std.testing.allocator);
    errdefer templates.deinit();
    settings_state = .{
        .allocator = std.testing.allocator,
        .store = &store,
        .settings = settings,
        .templates = templates,
        .backend = 0,
        .model = 1,
        .claude = 2,
        .copilot = 2,
        .codex = 1,
        .activity = false,
        .briefing = true,
        .beta = false,
        .auto_model = false,
        .dpi = 144,
    };
    settings = undefined;
    templates = undefined;
    defer settings_state.settings.deinit();
    defer settings_state.templates.deinit();
    defer releaseSettingsBrushes();
    settings_active = true;
    defer settings_active = false;
    var host: SheetFramework.Host = .{};
    defer host.deinit();
    try createSettingsSheet(&host, owner);
    try std.testing.expect(c.IsWindowVisible(host.hwnd) == 0);
    try std.testing.expect(c.GetWindowLongPtrW(host.hwnd, c.GWL_STYLE) & c.WS_CAPTION != 0);
    try std.testing.expect(c.GetWindowLongPtrW(host.hwnd, c.GWL_STYLE) & c.WS_THICKFRAME != 0);
    var title: [64]u16 = [_]u16{0} ** 64;
    const title_length = c.GetWindowTextW(host.hwnd, &title, title.len);
    try std.testing.expectEqualSlices(u16, settings_title[0..settings_title.len], title[0..@intCast(title_length)]);
    try std.testing.expect(c.GetParent(settings_state.content_root) == host.viewport);
    try std.testing.expect(c.GetWindowLongPtrW(settings_state.content_root, c.GWL_EXSTYLE) & c.WS_EX_CONTROLPARENT != 0);
    try std.testing.expect(host.current_layout.scroll.visible);
    var viewport: c.RECT = undefined;
    var content: c.RECT = undefined;
    try std.testing.expect(c.GetClientRect(host.viewport, &viewport) != 0);
    try std.testing.expect(c.GetClientRect(settings_state.content_root, &content) != 0);
    try std.testing.expectEqual(
        SheetFramework.Metrics.forDpi(settings_state.dpi).scrollbar_width,
        (viewport.right - viewport.left) - (content.right - content.left),
    );
    for ([_]u32{ 192, 96, 144 }) |dpi| {
        try host.refreshForDpi(dpi);
        try std.testing.expectEqual(dpi, settings_state.dpi);
        try std.testing.expectEqual(
            AppFont.getForDpi(AppFont.control_size, false, dpi),
            Win32.opaquePointerFromInt(c.HFONT, @bitCast(c.SendMessageW(settings_state.controls[0], c.WM_GETFONT, 0, 0))),
        );
        var control_bounds: c.RECT = undefined;
        var content_bounds: c.RECT = undefined;
        try std.testing.expect(c.GetWindowRect(settings_state.controls[0], &control_bounds) != 0);
        try std.testing.expect(c.GetWindowRect(settings_state.content_root, &content_bounds) != 0);
        try std.testing.expectEqual(Dpi.scale(224, dpi), control_bounds.left - content_bounds.left);
    }
    for ([_]u32{ 96, 144, 192 }) |dpi| {
        const actions = settingsFooterActions(host.hwnd, dpi);
        const width = Dpi.scale(settings_width, dpi);
        const footer = try SheetFramework.measureFooter(width, Dpi.scale(64, dpi), dpi, &actions);
        try std.testing.expect(footer.measured_minimum_width <= width);
        for (footer.slice()) |slot| {
            try std.testing.expect(slot.bounds.x >= 0);
            try std.testing.expect(slot.bounds.right() <= width);
        }
        try std.testing.expectEqual(@as(usize, 0), actions.len);
    }
}
