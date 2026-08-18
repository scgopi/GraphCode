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

pub fn open(parent: c.HWND, allocator: std.mem.Allocator, current: Settings) !?Settings {
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
    const ex_style = c.WS_EX_DLGMODALFRAME;
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
        _ = c.TranslateMessage(&message);
        _ = c.DispatchMessageW(&message);
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
const claude_labels = [_][]const u8{ "Ask every time", "Accept edits", "Automatic", "Don't ask", "Bypass all checks" };
const copilot_labels = [_][]const u8{ "Ask", "Allow tools", "Allow everything" };
const codex_labels = [_][]const u8{ "Ask", "Workspace writes", "Unsandboxed" };

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
};

const settings_class = std.unicode.utf8ToUtf16LeStringLiteral("GraphCodeProductSettings");
const settings_title = std.unicode.utf8ToUtf16LeStringLiteral("GraphCode Settings");
const settings_width: i32 = 620;
const settings_height: i32 = 760;
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
    if (!settings_active) return c.DefWindowProcW(hwnd, message, wparam, lparam);
    switch (message) {
        c.WM_ERASEBKGND => return 1,
        c.WM_PAINT => {
            var state: c.PAINTSTRUCT = undefined;
            const hdc = c.BeginPaint(hwnd, &state);
            paintSettings(hdc);
            _ = c.EndPaint(hwnd, &state);
            return 0;
        },
        c.WM_LBUTTONUP => {
            const point = CanvasInput.decodeMouseMessage(lparam);
            if (applySettingsClick(point.x, point.y)) _ = c.InvalidateRect(hwnd, null, 0);
            return 0;
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
    return c.DefWindowProcW(hwnd, message, wparam, lparam);
}

fn applySettingsClick(x: i32, y: i32) bool {
    if (inside(x, y, settingsRect(476, 708, 584, 746))) {
        settings_state.accepted = true;
        settings_state.closed = true;
        return false;
    }
    if (inside(x, y, settingsRect(374, 708, 466, 746))) {
        settings_state.closed = true;
        return false;
    }
    if (rowHit(x, y, 82)) settings_state.backend = (settings_state.backend + 1) % backend_values.len
    else if (rowHit(x, y, 168)) settings_state.claude = (settings_state.claude + 1) % claude_values.len
    else if (rowHit(x, y, 224)) settings_state.copilot = (settings_state.copilot + 1) % copilot_values.len
    else if (rowHit(x, y, 280)) settings_state.codex = (settings_state.codex + 1) % codex_values.len
    else if (rowHit(x, y, 390)) settings_state.model = (settings_state.model + 1) % model_values.len
    else if (rowHit(x, y, 446)) settings_state.auto_model = !settings_state.auto_model
    else if (rowHit(x, y, 530)) settings_state.activity = !settings_state.activity
    else if (rowHit(x, y, 586)) settings_state.briefing = !settings_state.briefing
    else if (rowHit(x, y, 642)) settings_state.beta = !settings_state.beta
    else return false;
    return true;
}

fn rowHit(x: i32, y: i32, top: i32) bool {
    return inside(x, y, settingsRect(36, top, 584, top + 48));
}

fn paintSettings(hdc: c.HDC) void {
    settingsFill(hdc, settingsRect(0, 0, settings_width, settings_height), settingsRgb(35, 35, 38));
    settingsText(hdc, "Settings", settingsRect(36, 22, 584, 54), 24, settingsRgb(245, 245, 247), true);
    settingsText(hdc, "DEFAULT BACKEND", settingsRect(36, 62, 260, 80), 10, settingsRgb(135, 135, 142), true);
    choiceRow(hdc, 82, "New loops use", backend_labels[settings_state.backend]);
    settingsText(hdc, "Which backend a new loop starts on. You can still change it per loop.", settingsRect(48, 132, 572, 154), 11, settingsRgb(145, 145, 152), false);

    settingsText(hdc, "PERMISSIONS", settingsRect(36, 154, 260, 172), 10, settingsRgb(135, 135, 142), true);
    choiceRow(hdc, 168, "Claude Code", claude_labels[settings_state.claude]);
    choiceRow(hdc, 224, "Copilot CLI", copilot_labels[settings_state.copilot]);
    choiceRow(hdc, 280, "Codex", codex_labels[settings_state.codex]);
    settingsText(hdc, "Loops continue when this window is closed. Avoid modes that wait forever at a permission prompt.", settingsRect(48, 332, 572, 370), 11, settingsRgb(145, 145, 152), false);

    settingsText(hdc, "MODEL", settingsRect(36, 372, 260, 390), 10, settingsRgb(135, 135, 142), true);
    choiceRow(hdc, 390, "Default model", model_labels[settings_state.model]);
    toggleRow(hdc, 446, "Pick a model for each loop", settings_state.auto_model);

    settingsText(hdc, "BEHAVIOR", settingsRect(36, 506, 260, 524), 10, settingsRgb(135, 135, 142), true);
    toggleRow(hdc, 530, "Show the activity strip", settings_state.activity);
    toggleRow(hdc, 586, "Tell sessions they're part of a graph", settings_state.briefing);
    toggleRow(hdc, 642, "Get beta releases", settings_state.beta);

    settingsButton(hdc, settingsRect(374, 708, 466, 746), "Cancel", false);
    settingsButton(hdc, settingsRect(476, 708, 584, 746), "Save", true);
}

fn choiceRow(hdc: c.HDC, top: i32, label: []const u8, value: []const u8) void {
    settingsRounded(hdc, settingsRect(36, top, 584, top + 48), settingsRgb(45, 45, 49), settingsRgb(66, 66, 72), 8);
    settingsText(hdc, label, settingsRect(50, top + 15, 280, top + 36), 13, settingsRgb(232, 232, 236), false);
    settingsText(hdc, value, settingsRect(288, top + 15, 558, top + 36), 12, settingsRgb(90, 174, 255), false);
    settingsText(hdc, "›", settingsRect(556, top + 13, 574, top + 37), 16, settingsRgb(125, 125, 132), false);
}

fn toggleRow(hdc: c.HDC, top: i32, label: []const u8, enabled: bool) void {
    settingsRounded(hdc, settingsRect(36, top, 584, top + 48), settingsRgb(45, 45, 49), settingsRgb(66, 66, 72), 8);
    settingsText(hdc, label, settingsRect(50, top + 15, 470, top + 36), 13, settingsRgb(232, 232, 236), false);
    settingsRounded(hdc, settingsRect(522, top + 12, 566, top + 36), if (enabled) settingsRgb(10, 132, 255) else settingsRgb(82, 82, 88), if (enabled) settingsRgb(10, 132, 255) else settingsRgb(82, 82, 88), 14);
    const knob_left: i32 = if (enabled) 544 else 524;
    settingsRounded(hdc, settingsRect(knob_left, top + 14, knob_left + 20, top + 34), settingsRgb(245, 245, 247), settingsRgb(245, 245, 247), 12);
}

fn settingsButton(hdc: c.HDC, bounds: c.RECT, label: []const u8, primary: bool) void {
    settingsRounded(hdc, bounds, if (primary) settingsRgb(10, 132, 255) else settingsRgb(52, 52, 57), if (primary) settingsRgb(10, 132, 255) else settingsRgb(78, 78, 84), 8);
    settingsText(hdc, label, settingsRect(bounds.left, bounds.top + 10, bounds.right, bounds.bottom - 6), 13, settingsRgb(245, 245, 247), true);
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

fn settingsRounded(hdc: c.HDC, bounds: c.RECT, fill_color: u32, border_color: u32, radius: i32) void {
    const brush = c.CreateSolidBrush(fill_color);
    const pen = c.CreatePen(c.PS_SOLID, 1, border_color);
    if (brush == null or pen == null) return;
    const old_brush = c.SelectObject(hdc, brush);
    const old_pen = c.SelectObject(hdc, pen);
    _ = c.RoundRect(hdc, bounds.left, bounds.top, bounds.right, bounds.bottom, radius, radius);
    _ = c.SelectObject(hdc, old_pen);
    _ = c.SelectObject(hdc, old_brush);
    _ = c.DeleteObject(pen);
    _ = c.DeleteObject(brush);
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
    try std.testing.expect(applySettingsClick(100, 658));
    try std.testing.expect(settings_state.beta);
}
