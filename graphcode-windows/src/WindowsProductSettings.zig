const std = @import("std");
const CanvasInput = @import("CanvasInput.zig");
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
        const settings = Settings.parse(self.allocator, &.{
            stringValue.get(object, "defaultBackend", "claudeCode"),
            stringValue.get(object, "defaultModelTier", "standard"),
            stringValue.get(object, "claudePermissionMode", "auto"),
            stringValue.get(object, "copilotPermissions", "allowEverything"),
            stringValue.get(object, "codexApprovals", "workspace"),
            if (stringValue.boolean(object, "showsActivityStrip", false)) "on" else "off",
            if (stringValue.boolean(object, "briefsSessionsAboutTheGraph", true)) "on" else "off",
            if (stringValue.boolean(object, "betaUpdates", false)) "on" else "off",
            if (stringValue.boolean(object, "autoSelectsModel", false)) "on" else "off",
        }) catch |err| {
            self.load_failed = true;
            return err;
        };
        self.load_failed = false;
        return settings;
    }

    pub fn save(self: Store, settings: Settings) !void {
        if (self.load_failed) return error.SettingsLoadFailed;
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

pub fn open(parent_address: usize, allocator: std.mem.Allocator, current: Settings) !?Settings {
    const parent = windowHandle(parent_address);
    if (settings_active) return error.SettingsAlreadyOpen;
    try registerSettingsClass();
    settings_state = .{
        .allocator = allocator,
        .backend = choiceIndex(current.default_backend, backend_values[0..]),
        .model = choiceIndex(current.default_model, model_values[0..]),
        .claude = choiceIndex(current.claude_permissions, claude_values[0..]),
        .copilot = choiceIndex(current.copilot_permissions, copilot_values[0..]),
        .codex = choiceIndex(current.codex_approvals, codex_values[0..]),
        .activity = current.activity,
        .briefing = current.briefing,
        .beta = current.beta,
        .auto_model = current.auto_selects_model,
    };
    settings_active = true;

    var frame = c.RECT{ .left = 0, .top = 0, .right = settings_width, .bottom = settings_height };
    const style = c.WS_OVERLAPPED | c.WS_CAPTION | c.WS_SYSMENU;
    const ex_style = c.WS_EX_DLGMODALFRAME | c.WS_EX_CONTROLPARENT;
    _ = c.AdjustWindowRectEx(&frame, style, 0, ex_style);
    const width = frame.right - frame.left;
    const height = frame.bottom - frame.top;
    var owner: c.RECT = undefined;
    _ = c.GetWindowRect(parent, &owner);
    const hwnd = c.CreateWindowExW(
        ex_style,
        settings_class.ptr,
        settings_title.ptr,
        style,
        owner.left + @divTrunc((owner.right - owner.left) - width, 2),
        owner.top + @divTrunc((owner.bottom - owner.top) - height, 2),
        width,
        height,
        parent,
        null,
        c.GetModuleHandleW(null),
        null,
    ) orelse {
        settings_active = false;
        return error.SettingsCreationFailed;
    };
    const safe_hwnd = windowHandle(@intFromPtr(hwnd.?));
    createSettingsControls(safe_hwnd);
    _ = c.EnableWindow(parent, 0);
    _ = c.ShowWindow(hwnd, c.SW_SHOW);
    _ = c.SetForegroundWindow(hwnd);
    _ = c.SetFocus(hwnd);
    var message: c.MSG = undefined;
    while (!settings_state.closed) {
        const code = c.GetMessageW(&message, null, 0, 0);
        if (code <= 0) {
            settings_state.closed = true;
            break;
        }
        if (message.message == c.WM_KEYDOWN and message.wParam == c.VK_RETURN) {
            settings_state.accepted = true;
            settings_state.closed = true;
            continue;
        }
        if (message.message == c.WM_KEYDOWN and message.wParam == c.VK_ESCAPE) {
            settings_state.closed = true;
            continue;
        }
        if (c.IsDialogMessageW(hwnd, &message) == 0) {
            _ = c.TranslateMessage(&message);
            _ = c.DispatchMessageW(&message);
        }
    }
    const accepted = settings_state.accepted;
    _ = c.DestroyWindow(hwnd);
    _ = c.EnableWindow(parent, 1);
    _ = c.SetActiveWindow(parent);
    settings_active = false;
    if (!accepted) return null;
    return @as(?Settings, try Settings.parse(allocator, &.{
        backend_values[settings_state.backend],
        model_values[settings_state.model],
        claude_values[settings_state.claude],
        copilot_values[settings_state.copilot],
        codex_values[settings_state.codex],
        if (settings_state.activity) "on" else "off",
        if (settings_state.briefing) "on" else "off",
        if (settings_state.beta) "on" else "off",
        if (settings_state.auto_model) "on" else "off",
    }));
}

const backend_values = [_][]const u8{ "claudeCode", "copilotCLI", "codex" };
const model_values = [_][]const u8{ "fast", "standard", "capable" };
const claude_values = [_][]const u8{ "manual", "acceptEdits", "auto", "dontAsk", "bypassPermissions" };
const copilot_values = [_][]const u8{ "ask", "allowTools", "allowEverything" };
const codex_values = [_][]const u8{ "ask", "workspace", "unsandboxed" };
const backend_labels = [_][]const u8{ "Claude Code", "Copilot CLI", "Codex" };
const model_labels = [_][]const u8{ "Fast", "Standard", "Capable" };
const claude_labels = [_][]const u8{ "Ask every time", "Accept file edits", "Auto (recommended)", "Don't ask", "Bypass all checks" };
const copilot_labels = [_][]const u8{ "Ask every time", "Allow tools only", "YOLO (recommended)" };
const codex_labels = [_][]const u8{ "Ask when unsure", "Workspace (recommended)", "No sandbox" };
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
const save_id = 6184;
const cancel_id = 6192;

const SettingsDialogState = struct {
    allocator: std.mem.Allocator,
    backend: usize,
    model: usize,
    claude: usize,
    copilot: usize,
    codex: usize,
    activity: bool,
    briefing: bool,
    beta: bool,
    auto_model: bool,
    accepted: bool = false,
    closed: bool = false,
    controls: [9]c.HWND = @splat(null),
    explanations: [9]c.HWND = @splat(null),
};

const settings_class = std.unicode.utf8ToUtf16LeStringLiteral("GraphCodeProductSettings");
const settings_title = std.unicode.utf8ToUtf16LeStringLiteral("GraphCode Settings");
const settings_width: i32 = 620;
const settings_height: i32 = 830;
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
    klass.hCursor = c.LoadCursorW(null, @ptrFromInt(32512));
    klass.hbrBackground = null;
    if (c.RegisterClassW(&klass) == 0 and c.GetLastError() != c.ERROR_CLASS_ALREADY_EXISTS)
        return error.SettingsClassRegistrationFailed;
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
            if (applySettingsClick(point.x, point.y)) _ = c.InvalidateRect(safe_hwnd, null, 0);
            return 0;
        },
        c.WM_COMMAND => {
            const command: u16 = @truncate(wparam);
            switch (command) {
                save_id => {
                    settings_state.accepted = true;
                    settings_state.closed = true;
                },
                cancel_id => settings_state.closed = true,
                backend_id => settings_state.backend = (settings_state.backend + 1) % backend_values.len,
                claude_id => settings_state.claude = (settings_state.claude + 1) % claude_values.len,
                copilot_id => settings_state.copilot = (settings_state.copilot + 1) % copilot_values.len,
                codex_id => settings_state.codex = (settings_state.codex + 1) % codex_values.len,
                model_id => settings_state.model = (settings_state.model + 1) % model_values.len,
                auto_model_id => settings_state.auto_model = !settings_state.auto_model,
                activity_id => settings_state.activity = !settings_state.activity,
                briefing_id => settings_state.briefing = !settings_state.briefing,
                beta_id => settings_state.beta = !settings_state.beta,
                else => return c.DefWindowProcW(safe_hwnd, message, wparam, lparam),
            }
            updateSettingsControls();
            _ = c.InvalidateRect(safe_hwnd, null, 0);
            return 0;
        },
        c.WM_CTLCOLORSTATIC => {
            const hdc = deviceContext(wparam);
            _ = c.SetTextColor(hdc, settingsRgb(190, 190, 198));
            _ = c.SetBkMode(hdc, c.TRANSPARENT);
            return @intCast(@intFromPtr(c.GetStockObject(c.NULL_BRUSH)));
        },
        c.WM_KEYDOWN => {
            if (wparam == c.VK_ESCAPE) {
                settings_state.closed = true;
                return 0;
            }
            if (wparam == c.VK_RETURN) {
                settings_state.accepted = true;
                settings_state.closed = true;
                return 0;
            }
        },
        c.WM_CLOSE => {
            settings_state.closed = true;
            return 0;
        },
        else => {},
    }
    return c.DefWindowProcW(safe_hwnd, message, wparam, lparam);
}

fn applySettingsClick(x: i32, y: i32) bool {
    if (inside(x, y, settingsRect(476, 780, 584, 818))) {
        settings_state.accepted = true;
        settings_state.closed = true;
        return false;
    }
    if (inside(x, y, settingsRect(374, 780, 466, 818))) {
        settings_state.closed = true;
        return false;
    }
    if (rowHit(x, y, 70)) settings_state.backend = (settings_state.backend + 1) % backend_values.len
    else if (rowHit(x, y, 148)) settings_state.claude = (settings_state.claude + 1) % claude_values.len
    else if (rowHit(x, y, 210)) settings_state.copilot = (settings_state.copilot + 1) % copilot_values.len
    else if (rowHit(x, y, 280)) settings_state.codex = (settings_state.codex + 1) % codex_values.len
    else if (rowHit(x, y, 398)) settings_state.model = (settings_state.model + 1) % model_values.len
    else if (rowHit(x, y, 432)) settings_state.auto_model = !settings_state.auto_model
    else if (rowHit(x, y, 512)) settings_state.activity = !settings_state.activity
    else if (rowHit(x, y, 584)) settings_state.briefing = !settings_state.briefing
    else if (rowHit(x, y, 672)) settings_state.beta = !settings_state.beta
    else return false;
    updateSettingsControls();
    return true;
}

fn rowHit(x: i32, y: i32, top: i32) bool {
    return inside(x, y, settingsRect(36, top, 584, top + 48));
}

fn paintSettings(hdc: c.HDC) void {
    settingsFill(hdc, settingsRect(0, 0, settings_width, settings_height), settingsRgb(35, 35, 38));
    settingsText(hdc, "Settings", settingsRect(36, 22, 584, 54), 24, settingsRgb(245, 245, 247), true);
    settingsText(hdc, "DEFAULT BACKEND", settingsRect(36, 52, 260, 68), 10, settingsRgb(135, 135, 142), true);
    settingsText(hdc, "PERMISSIONS", settingsRect(36, 130, 260, 146), 10, settingsRgb(135, 135, 142), true);
    settingsText(hdc, "MODEL", settingsRect(36, 380, 260, 396), 10, settingsRgb(135, 135, 142), true);
    settingsText(hdc, "BEHAVIOR", settingsRect(36, 494, 260, 510), 10, settingsRgb(135, 135, 142), true);
    settingsText(hdc, "UPDATES", settingsRect(36, 654, 260, 670), 10, settingsRgb(135, 135, 142), true);
}

fn createSettingsControls(hwnd: c.HWND) void {
    settings_state.controls[0] = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("BUTTON").ptr,
        std.unicode.utf8ToUtf16LeStringLiteral("New loops use: Claude Code").ptr,
        c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.BS_PUSHBUTTON,
        36,
        70,
        548,
        30,
        hwnd,
        @ptrFromInt(backend_id),
        c.GetModuleHandleW(null),
        null,
    );
    settings_state.explanations[0] = createSettingsControl(hwnd, "STATIC", "Which backend a new loop starts on. You can still change it per loop.", c.WS_CHILD | c.WS_VISIBLE | c.SS_LEFT, 48, 102, 524, 24, 0);

    settings_state.controls[1] = createSettingsControl(hwnd, "BUTTON", "", c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.BS_PUSHBUTTON, 36, 148, 548, 30, claude_id);
    settings_state.explanations[1] = createSettingsControl(hwnd, "STATIC", "", c.WS_CHILD | c.WS_VISIBLE | c.SS_LEFT, 48, 180, 524, 28, 0);
    settings_state.controls[2] = createSettingsControl(hwnd, "BUTTON", "", c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.BS_PUSHBUTTON, 36, 210, 548, 30, copilot_id);
    settings_state.explanations[2] = createSettingsControl(hwnd, "STATIC", "", c.WS_CHILD | c.WS_VISIBLE | c.SS_LEFT, 48, 242, 524, 36, 0);
    settings_state.controls[3] = createSettingsControl(hwnd, "BUTTON", "", c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.BS_PUSHBUTTON, 36, 280, 548, 30, codex_id);
    settings_state.explanations[3] = createSettingsControl(hwnd, "STATIC", "", c.WS_CHILD | c.WS_VISIBLE | c.SS_LEFT, 48, 312, 524, 28, 0);
    settings_state.explanations[4] = createSettingsControl(hwnd, "STATIC", "A loop runs whether or not this window is open, so nobody is there to answer a permission prompt.", c.WS_CHILD | c.WS_VISIBLE | c.SS_LEFT, 48, 342, 524, 34, 0);

    settings_state.controls[4] = createSettingsControl(hwnd, "BUTTON", "", c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.BS_PUSHBUTTON, 36, 398, 548, 30, model_id);
    settings_state.controls[5] = createSettingsControl(hwnd, "BUTTON", "Pick a model for each loop", c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.BS_AUTOCHECKBOX, 44, 432, 532, 26, auto_model_id);
    settings_state.explanations[5] = createSettingsControl(hwnd, "STATIC", "The default model tier is copied into new loops. On, an unpinned loop is routed by its type; a per-loop model always wins.", c.WS_CHILD | c.WS_VISIBLE | c.SS_LEFT, 48, 462, 524, 42, 0);

    settings_state.controls[6] = createSettingsControl(hwnd, "BUTTON", "Show the activity strip", c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.BS_AUTOCHECKBOX, 44, 512, 532, 26, activity_id);
    settings_state.explanations[6] = createSettingsControl(hwnd, "STATIC", "A strip along the window's bottom lists passes, hand-offs, and state changes as they happen. It starts empty after a relaunch.", c.WS_CHILD | c.WS_VISIBLE | c.SS_LEFT, 48, 542, 524, 38, 0);
    settings_state.controls[7] = createSettingsControl(hwnd, "BUTTON", "Tell sessions they're part of a graph", c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.BS_AUTOCHECKBOX, 44, 584, 532, 26, briefing_id);
    settings_state.explanations[7] = createSettingsControl(hwnd, "STATIC", "Lets a loop create more loops when work genuinely splits. Off, a session does its assigned work and never creates anything.", c.WS_CHILD | c.WS_VISIBLE | c.SS_LEFT, 48, 614, 524, 38, 0);

    settings_state.controls[8] = createSettingsControl(hwnd, "BUTTON", "Get beta releases", c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.BS_AUTOCHECKBOX, 44, 672, 532, 26, beta_id);
    settings_state.explanations[8] = createSettingsControl(hwnd, "STATIC", "On, Check for Updates offers pre-releases as well as stable releases — newer features, less soak time. Off, stable releases only.", c.WS_CHILD | c.WS_VISIBLE | c.SS_LEFT, 48, 702, 524, 50, 0);

    _ = createSettingsControl(hwnd, "BUTTON", "Cancel", c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.BS_PUSHBUTTON, 374, 780, 92, 38, cancel_id);
    _ = createSettingsControl(hwnd, "BUTTON", "Save", c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.BS_DEFPUSHBUTTON, 476, 780, 108, 38, save_id);
    updateSettingsControls();
}

fn createSettingsControl(hwnd: c.HWND, class_name: []const u8, text: []const u8, style: c.DWORD, x: i32, y: i32, width: i32, height: i32, id: usize) c.HWND {
    const wide_text = settingsWideZ(text) catch return null;
    defer settings_state.allocator.free(wide_text);
    const menu: c.HMENU = if (id == 0) null else @ptrFromInt(id);
    const wide_class = if (std.mem.eql(u8, class_name, "BUTTON"))
        std.unicode.utf8ToUtf16LeStringLiteral("BUTTON").ptr
    else
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC").ptr;
    const control = c.CreateWindowExW(0, wide_class, wide_text.ptr, style, x, y, width, height, hwnd, menu, c.GetModuleHandleW(null), null);
    return control;
}

fn updateSettingsControls() void {
    setSettingsControlText(settings_state.controls[0], "New loops use: ", backend_labels[settings_state.backend]);
    setSettingsControlText(settings_state.controls[1], "Claude Code: ", claude_labels[settings_state.claude]);
    setSettingsControlText(settings_state.controls[2], "Copilot CLI: ", copilot_labels[settings_state.copilot]);
    setSettingsControlText(settings_state.controls[3], "Codex: ", codex_labels[settings_state.codex]);
    setSettingsControlText(settings_state.controls[4], "Default model: ", model_labels[settings_state.model]);
    setSettingsControlText(settings_state.explanations[1], "", claude_explanations[settings_state.claude]);
    setSettingsControlText(settings_state.explanations[2], "", copilot_explanations[settings_state.copilot]);
    setSettingsControlText(settings_state.explanations[3], "", codex_explanations[settings_state.codex]);
    setSettingsCheck(settings_state.controls[5], settings_state.auto_model);
    setSettingsCheck(settings_state.controls[6], settings_state.activity);
    setSettingsCheck(settings_state.controls[7], settings_state.briefing);
    setSettingsCheck(settings_state.controls[8], settings_state.beta);
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

test "purpose-built settings rows cycle choices and toggle behavior" {
    settings_state = .{
        .allocator = std.testing.allocator,
        .backend = 0,
        .model = 0,
        .claude = 0,
        .copilot = 0,
        .codex = 0,
        .activity = false,
        .briefing = true,
        .beta = false,
        .auto_model = false,
    };
    try std.testing.expect(applySettingsClick(100, 100));
    try std.testing.expectEqual(@as(usize, 1), settings_state.backend);
    try std.testing.expect(applySettingsClick(100, 406));
    try std.testing.expectEqual(@as(usize, 1), settings_state.model);
    try std.testing.expect(applySettingsClick(100, 462));
    try std.testing.expect(settings_state.auto_model);
    try std.testing.expect(applySettingsClick(100, 546));
    try std.testing.expect(settings_state.activity);
    try std.testing.expect(applySettingsClick(100, 602));
    try std.testing.expect(!settings_state.briefing);
    try std.testing.expect(applySettingsClick(100, 688));
    try std.testing.expect(settings_state.beta);
}

test "settings expose Swift permission labels and consequence copy" {
    try std.testing.expectEqualStrings("Auto (recommended)", claude_labels[2]);
    try std.testing.expectEqualStrings("YOLO (recommended)", copilot_labels[2]);
    try std.testing.expectEqualStrings("Workspace (recommended)", codex_labels[1]);
    try std.testing.expect(std.mem.indexOf(u8, claude_explanations[2], "guardrails") != null);
    try std.testing.expect(std.mem.indexOf(u8, copilot_explanations[2], "tools, paths, and URLs") != null);
    try std.testing.expect(std.mem.indexOf(u8, codex_explanations[1], "write inside the project") != null);
}
