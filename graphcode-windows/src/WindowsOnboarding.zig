const std = @import("std");
const CanvasInput = @import("CanvasInput.zig");
const c = @import("Win32.zig").c;

pub const page_count: u8 = 4;

pub const Backend = enum {
    claudeCode,
    copilotCLI,
    codex,

    pub fn parse(raw: []const u8) Backend {
        if (std.mem.eql(u8, raw, "copilotCLI")) return .copilotCLI;
        if (std.mem.eql(u8, raw, "codex")) return .codex;
        return .claudeCode;
    }

    pub fn value(self: Backend) []const u8 {
        return switch (self) {
            .claudeCode => "claudeCode",
            .copilotCLI => "copilotCLI",
            .codex => "codex",
        };
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    marker: []u8,

    pub fn init(allocator: std.mem.Allocator) !Store {
        const base = std.process.getEnvVarOwned(allocator, "LOCALAPPDATA") catch
            try std.process.getEnvVarOwned(allocator, "USERPROFILE");
        defer allocator.free(base);
        const dir = try std.fs.path.join(allocator, &.{ base, "GraphCode" });
        errdefer allocator.free(dir);
        try std.fs.cwd().makePath(dir);
        const marker = try std.fs.path.join(allocator, &.{ dir, "onboarding-seen" });
        allocator.free(dir);
        return .{ .allocator = allocator, .marker = marker };
    }

    pub fn deinit(self: *Store) void {
        self.allocator.free(self.marker);
        self.* = undefined;
    }

    pub fn shouldShow(self: Store) bool {
        std.fs.cwd().access(self.marker, .{}) catch return true;
        return false;
    }

    pub fn markSeen(self: Store) !void {
        var file = try std.fs.cwd().createFile(self.marker, .{ .truncate = true });
        file.close();
    }
};

const State = struct {
    allocator: std.mem.Allocator,
    page: u8 = 0,
    backend: Backend,
    closed: bool = false,
};

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GraphCodeWindowsOnboarding");
const title = std.unicode.utf8ToUtf16LeStringLiteral("Welcome to GraphCode");
const client_width: i32 = 560;
const client_height: i32 = 620;
var active = false;
var active_state: State = undefined;

pub fn showFirstRun(
    parent: c.HWND,
    allocator: std.mem.Allocator,
    store: Store,
    initial_backend: []const u8,
) !?Backend {
    if (!store.shouldShow()) return null;
    const backend = try show(parent, allocator, initial_backend);
    try store.markSeen();
    return backend;
}

pub fn show(parent: c.HWND, allocator: std.mem.Allocator, initial_backend: []const u8) !Backend {
    if (active) return error.OnboardingAlreadyOpen;
    try registerClass();

    var frame = c.RECT{ .left = 0, .top = 0, .right = client_width, .bottom = client_height };
    const style = c.WS_POPUP;
    const ex_style = c.WS_EX_DLGMODALFRAME;
    _ = c.AdjustWindowRectEx(&frame, style, 0, ex_style);
    const width = frame.right - frame.left;
    const height = frame.bottom - frame.top;
    var owner: c.RECT = undefined;
    _ = c.GetWindowRect(parent, &owner);
    const x = owner.left + @divTrunc((owner.right - owner.left) - width, 2);
    const y = owner.top + @divTrunc((owner.bottom - owner.top) - height, 2);

    active_state = .{
        .allocator = allocator,
        .backend = Backend.parse(initial_backend),
    };
    active = true;
    const hwnd = c.CreateWindowExW(
        ex_style,
        class_name.ptr,
        title.ptr,
        style,
        x,
        y,
        width,
        height,
        parent,
        null,
        c.GetModuleHandleW(null),
        null,
    ) orelse {
        active = false;
        return error.OnboardingCreationFailed;
    };
    const region = c.CreateRoundRectRgn(0, 0, width, height, 18, 18);
    if (region != null and c.SetWindowRgn(hwnd, region, 1) == 0) {
        _ = c.DeleteObject(region);
    }
    _ = c.EnableWindow(parent, 0);
    _ = c.ShowWindow(hwnd, c.SW_SHOW);
    _ = c.SetForegroundWindow(hwnd);
    _ = c.SetFocus(hwnd);

    var message: c.MSG = undefined;
    while (!active_state.closed) {
        const code = c.GetMessageW(&message, null, 0, 0);
        if (code <= 0) {
            active_state.closed = true;
            break;
        }
        _ = c.TranslateMessage(&message);
        _ = c.DispatchMessageW(&message);
    }
    const backend = active_state.backend;
    _ = c.DestroyWindow(hwnd);
    _ = c.EnableWindow(parent, 1);
    _ = c.SetActiveWindow(parent);
    active = false;
    return backend;
}

fn registerClass() !void {
    var klass: c.WNDCLASSW = std.mem.zeroes(c.WNDCLASSW);
    klass.lpfnWndProc = @ptrCast(&windowProc);
    klass.hInstance = c.GetModuleHandleW(null);
    klass.lpszClassName = class_name.ptr;
    klass.hCursor = c.LoadCursorW(null, @ptrFromInt(32512));
    klass.hbrBackground = null;
    if (c.RegisterClassW(&klass) == 0 and c.GetLastError() != c.ERROR_CLASS_ALREADY_EXISTS)
        return error.OnboardingClassRegistrationFailed;
}

fn windowProc(hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    if (!active) return c.DefWindowProcW(hwnd, message, wparam, lparam);
    switch (message) {
        c.WM_ERASEBKGND => return 1,
        c.WM_PAINT => {
            var paint_state: c.PAINTSTRUCT = undefined;
            const hdc = c.BeginPaint(hwnd, &paint_state);
            paint(hdc, active_state.allocator, active_state.page, active_state.backend);
            _ = c.EndPaint(hwnd, &paint_state);
            return 0;
        },
        c.WM_LBUTTONUP => {
            const point = CanvasInput.decodeMouseMessage(lparam);
            handleClick(hwnd, point.x, point.y);
            return 0;
        },
        c.WM_KEYDOWN => {
            switch (wparam) {
                c.VK_ESCAPE => active_state.closed = true,
                c.VK_LEFT => {
                    if (active_state.page > 0) active_state.page -= 1;
                },
                c.VK_RIGHT, c.VK_RETURN => {
                    if (active_state.page + 1 < page_count)
                        active_state.page += 1
                    else
                        active_state.closed = true;
                },
                else => return c.DefWindowProcW(hwnd, message, wparam, lparam),
            }
            _ = c.InvalidateRect(hwnd, null, 0);
            return 0;
        },
        c.WM_CLOSE => {
            active_state.closed = true;
            return 0;
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, message, wparam, lparam);
}

fn handleClick(hwnd: c.HWND, x: i32, y: i32) void {
    if (applyClick(&active_state, x, y)) {
        _ = c.InvalidateRect(hwnd, null, 0);
    }
}

fn applyClick(state: *State, x: i32, y: i32) bool {
    if (inside(x, y, rect(474, 12, 540, 42))) {
        state.closed = true;
        return false;
    }
    if (state.page > 0 and inside(x, y, rect(20, 564, 102, 604))) {
        state.page -= 1;
        return true;
    }
    if (inside(x, y, rect(418, 564, 540, 604))) {
        if (state.page + 1 < page_count)
            state.page += 1
        else
            state.closed = true;
        return true;
    }
    if (state.page == 3) {
        if (inside(x, y, rect(58, 182, 502, 248))) state.backend = .claudeCode;
        if (inside(x, y, rect(58, 258, 502, 324))) state.backend = .copilotCLI;
        if (inside(x, y, rect(58, 334, 502, 400))) state.backend = .codex;
        return true;
    }
    return false;
}

fn paint(hdc: c.HDC, allocator: std.mem.Allocator, page: u8, backend: Backend) void {
    fill(hdc, rect(0, 0, client_width, client_height), rgb(35, 35, 38));
    text(hdc, allocator, "Skip", rect(474, 16, 540, 40), 13, rgb(160, 160, 166), c.DT_CENTER | c.DT_SINGLELINE, false);
    switch (page) {
        0 => paintWelcome(hdc, allocator),
        1 => paintReading(hdc, allocator),
        2 => paintTypes(hdc, allocator),
        else => paintBackends(hdc, allocator, backend),
    }
    paintFooter(hdc, allocator, page);
}

fn paintWelcome(hdc: c.HDC, allocator: std.mem.Allocator) void {
    line(hdc, 160, 112, 342, 174, rgb(112, 112, 118), 2);
    line(hdc, 342, 174, 178, 250, rgb(112, 112, 118), 2);
    card(hdc, allocator, rect(48, 72, 244, 132), rgb(90, 174, 255), "Watch crash reports", "RUNNING", "/loop 1h - last run 14:02", false);
    card(hdc, allocator, rect(276, 144, 472, 204), rgb(123, 210, 130), "Fix the top crash", "RUNNING", "pass 3 - 1.42 -> 1.10", false);
    card(hdc, allocator, rect(78, 220, 274, 280), rgb(179, 138, 255), "Review the fix", "NEEDS YOU", "\"Ship this, or split it in two?\"", true);
    text(hdc, allocator, "Agents you can watch", rect(32, 330, 528, 370), 25, rgb(245, 245, 247), c.DT_CENTER | c.DT_SINGLELINE, true);
    text(hdc, allocator,
        "Every card is a real terminal session you can open and steer. They hand work to each other along the edges - and tell you when they need you.",
        rect(48, 382, 512, 456), 14, rgb(168, 168, 174), c.DT_CENTER | c.DT_WORDBREAK, false);
}

fn paintReading(hdc: c.HDC, allocator: std.mem.Allocator) void {
    card(hdc, allocator, rect(130, 70, 430, 162), rgb(123, 210, 130), "Fix the top crash", "RUNNING", "pass 3 - 1.42 -> 1.10", false);
    text(hdc, allocator, "How to read a loop", rect(32, 194, 528, 232), 25, rgb(245, 245, 247), c.DT_CENTER | c.DT_SINGLELINE, true);
    lesson(hdc, allocator, 260, "The pill", "What it's doing right now - running, done, blocked, or needs you");
    lesson(hdc, allocator, 304, "The line under it", "Where it's got to, in its own words");
    lesson(hdc, allocator, 348, "The bar", "Progress toward whatever you told it to aim for");
    lesson(hdc, allocator, 392, "The stripe", "Which kind of loop it is - next slide");
    rounded(hdc, rect(127, 458, 433, 490), rgb(61, 49, 31), rgb(61, 49, 31), 12);
    text(hdc, allocator, "Amber always means one thing: it's waiting on you.", rect(136, 465, 424, 486), 12, rgb(255, 205, 122), c.DT_CENTER | c.DT_SINGLELINE, true);
}

fn lesson(hdc: c.HDC, allocator: std.mem.Allocator, y: i32, label: []const u8, description: []const u8) void {
    text(hdc, allocator, label, rect(58, y, 188, y + 38), 13, rgb(230, 230, 234), c.DT_RIGHT | c.DT_WORDBREAK, true);
    text(hdc, allocator, description, rect(208, y, 506, y + 40), 13, rgb(158, 158, 165), c.DT_LEFT | c.DT_WORDBREAK, false);
}

fn paintTypes(hdc: c.HDC, allocator: std.mem.Allocator) void {
    text(hdc, allocator, "Four kinds of loop", rect(32, 68, 528, 106), 25, rgb(245, 245, 247), c.DT_CENTER | c.DT_SINGLELINE, true);
    text(hdc, allocator, "They differ in what makes them stop.", rect(32, 108, 528, 134), 14, rgb(168, 168, 174), c.DT_CENTER | c.DT_SINGLELINE, false);
    typeTile(hdc, allocator, rect(58, 158, 270, 226), rgb(123, 210, 130), "Goal", "Stops when the goal is met");
    typeTile(hdc, allocator, rect(290, 158, 502, 226), rgb(179, 138, 255), "Turn", "Stops after a fixed number of turns");
    typeTile(hdc, allocator, rect(58, 240, 270, 308), rgb(90, 174, 255), "Time", "Stops when its time budget expires");
    typeTile(hdc, allocator, rect(290, 240, 502, 308), rgb(255, 166, 82), "Composite", "Stops when its child work is done");
    line(hdc, 58, 342, 502, 342, rgb(63, 63, 68), 1);
    card(hdc, allocator, rect(76, 370, 244, 424), rgb(90, 174, 255), "Find bugs", "RUNNING", "/loop 1h", false);
    line(hdc, 250, 397, 306, 397, rgb(112, 112, 118), 2);
    card(hdc, allocator, rect(314, 370, 482, 424), rgb(123, 210, 130), "Fix them", "IDLE", "waiting on the hand-off", false);
    text(hdc, allocator,
        "Wire them together by dragging from a card's + handle. Click + without dragging to grow a new loop already connected to it.",
        rect(58, 446, 502, 512), 13, rgb(158, 158, 165), c.DT_CENTER | c.DT_WORDBREAK, false);
}

fn paintBackends(hdc: c.HDC, allocator: std.mem.Allocator, selected: Backend) void {
    text(hdc, allocator, "Which agent runs them", rect(32, 64, 528, 102), 25, rgb(245, 245, 247), c.DT_CENTER | c.DT_SINGLELINE, true);
    text(hdc, allocator, "The default for new loops. Change it any time in Settings, or per loop.", rect(52, 108, 508, 150), 14, rgb(168, 168, 174), c.DT_CENTER | c.DT_WORDBREAK, false);
    backendRow(hdc, allocator, rect(58, 182, 502, 248), .claudeCode, selected, "Claude Code", "Anthropic's agent - the reference backend, fully wired.", true);
    backendRow(hdc, allocator, rect(58, 258, 502, 324), .copilotCLI, selected, "Copilot CLI", "GitHub's agent CLI.", false);
    backendRow(hdc, allocator, rect(58, 334, 502, 400), .codex, selected, "Codex", "OpenAI's agent CLI.", false);
    text(hdc, allocator, "The CLI must be installed and on your PATH - GraphCode launches it, it doesn't bundle it.", rect(72, 434, 488, 480), 12, rgb(126, 126, 133), c.DT_CENTER | c.DT_WORDBREAK, false);
}

fn backendRow(
    hdc: c.HDC,
    allocator: std.mem.Allocator,
    bounds: c.RECT,
    backend: Backend,
    selected: Backend,
    name: []const u8,
    blurb: []const u8,
    hosts_all: bool,
) void {
    const is_selected = backend == selected;
    rounded(hdc, bounds, if (is_selected) rgb(29, 51, 73) else rgb(43, 43, 47), if (is_selected) rgb(10, 132, 255) else rgb(64, 64, 69), 12);
    rounded(hdc, rect(bounds.left + 14, bounds.top + 17, bounds.left + 48, bounds.top + 51), rgb(54, 54, 59), rgb(54, 54, 59), 8);
    text(hdc, allocator, ">_", rect(bounds.left + 18, bounds.top + 25, bounds.left + 45, bounds.top + 46), 13, rgb(170, 170, 177), c.DT_CENTER | c.DT_SINGLELINE, true);
    text(hdc, allocator, name, rect(bounds.left + 62, bounds.top + 11, bounds.left + 205, bounds.top + 32), 13, rgb(240, 240, 243), c.DT_LEFT | c.DT_SINGLELINE, true);
    const badge = if (hosts_all) "HOSTS EVERY LOOP KIND" else "LIMITED LOOP TYPES";
    rounded(hdc, rect(bounds.left + 208, bounds.top + 10, bounds.left + 348, bounds.top + 29), if (hosts_all) rgb(38, 66, 46) else rgb(70, 57, 36), if (hosts_all) rgb(38, 66, 46) else rgb(70, 57, 36), 5);
    text(hdc, allocator, badge, rect(bounds.left + 212, bounds.top + 13, bounds.left + 344, bounds.top + 27), 9, if (hosts_all) rgb(126, 228, 155) else rgb(255, 205, 122), c.DT_CENTER | c.DT_SINGLELINE, true);
    text(hdc, allocator, blurb, rect(bounds.left + 62, bounds.top + 36, bounds.right - 44, bounds.top + 56), 12, rgb(154, 154, 161), c.DT_LEFT | c.DT_SINGLELINE, false);
    text(hdc, allocator, if (is_selected) "●" else "○", rect(bounds.right - 38, bounds.top + 21, bounds.right - 12, bounds.top + 47), 18, if (is_selected) rgb(10, 132, 255) else rgb(110, 110, 116), c.DT_CENTER | c.DT_SINGLELINE, false);
}

fn paintFooter(hdc: c.HDC, allocator: std.mem.Allocator, page: u8) void {
    if (page > 0) {
        rounded(hdc, rect(20, 564, 102, 604), rgb(48, 48, 52), rgb(78, 78, 84), 9);
        text(hdc, allocator, "Back", rect(20, 576, 102, 598), 13, rgb(230, 230, 234), c.DT_CENTER | c.DT_SINGLELINE, false);
    }
    const primary = page + 1 == page_count;
    rounded(hdc, rect(418, 564, 540, 604), if (primary) rgb(10, 132, 255) else rgb(48, 48, 52), if (primary) rgb(10, 132, 255) else rgb(78, 78, 84), 9);
    text(hdc, allocator, if (primary) "Get Started" else "Continue", rect(418, 576, 540, 598), 13, rgb(245, 245, 247), c.DT_CENTER | c.DT_SINGLELINE, true);
    var x: i32 = 254;
    for (0..page_count) |index| {
        const color = if (index == page) rgb(10, 132, 255) else rgb(92, 92, 98);
        const brush = c.CreateSolidBrush(color);
        if (brush != null) {
            const old = c.SelectObject(hdc, brush);
            _ = c.Ellipse(hdc, x, 580, x + 7, 587);
            _ = c.SelectObject(hdc, old);
            _ = c.DeleteObject(brush);
        }
        x += 16;
    }
}

fn typeTile(hdc: c.HDC, allocator: std.mem.Allocator, bounds: c.RECT, accent: u32, name: []const u8, detail: []const u8) void {
    rounded(hdc, bounds, rgb(43, 43, 47), rgb(64, 64, 69), 10);
    fill(hdc, rect(bounds.left, bounds.top, bounds.left + 4, bounds.bottom), accent);
    text(hdc, allocator, name, rect(bounds.left + 16, bounds.top + 12, bounds.right - 10, bounds.top + 34), 14, rgb(240, 240, 243), c.DT_LEFT | c.DT_SINGLELINE, true);
    text(hdc, allocator, detail, rect(bounds.left + 16, bounds.top + 38, bounds.right - 10, bounds.bottom - 6), 11, rgb(154, 154, 161), c.DT_LEFT | c.DT_WORDBREAK, false);
}

fn card(hdc: c.HDC, allocator: std.mem.Allocator, bounds: c.RECT, accent: u32, heading: []const u8, state: []const u8, subline: []const u8, attention: bool) void {
    rounded(hdc, bounds, if (attention) rgb(55, 43, 31) else rgb(39, 39, 44), if (attention) rgb(143, 96, 41) else rgb(61, 61, 67), 10);
    fill(hdc, rect(bounds.left, bounds.top, bounds.left + 4, bounds.bottom), accent);
    text(hdc, allocator, heading, rect(bounds.left + 12, bounds.top + 9, bounds.right - 68, bounds.top + 29), 12, rgb(242, 242, 245), c.DT_LEFT | c.DT_SINGLELINE | c.DT_END_ELLIPSIS, true);
    text(hdc, allocator, state, rect(bounds.right - 70, bounds.top + 10, bounds.right - 8, bounds.top + 28), 9, if (attention) rgb(255, 205, 122) else rgb(164, 222, 174), c.DT_RIGHT | c.DT_SINGLELINE, true);
    text(hdc, allocator, subline, rect(bounds.left + 12, bounds.top + 35, bounds.right - 8, bounds.bottom - 6), 10, rgb(145, 145, 153), c.DT_LEFT | c.DT_SINGLELINE | c.DT_END_ELLIPSIS, false);
}

fn text(
    hdc: c.HDC,
    allocator: std.mem.Allocator,
    value: []const u8,
    bounds_value: c.RECT,
    size: i32,
    color: u32,
    format: c.UINT,
    bold: bool,
) void {
    const wide = std.unicode.utf8ToUtf16LeAlloc(allocator, value) catch return;
    defer allocator.free(wide);
    const face = std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI");
    const font = c.CreateFontW(
        -size,
        0,
        0,
        0,
        if (bold) c.FW_SEMIBOLD else c.FW_NORMAL,
        0,
        0,
        0,
        c.DEFAULT_CHARSET,
        c.OUT_DEFAULT_PRECIS,
        c.CLIP_DEFAULT_PRECIS,
        c.CLEARTYPE_QUALITY,
        c.DEFAULT_PITCH | c.FF_DONTCARE,
        face.ptr,
    );
    const old_font = if (font != null) c.SelectObject(hdc, font) else null;
    _ = c.SetTextColor(hdc, color);
    _ = c.SetBkMode(hdc, c.TRANSPARENT);
    var bounds = bounds_value;
    _ = c.DrawTextW(hdc, wide.ptr, @intCast(wide.len), &bounds, format);
    if (font != null) {
        _ = c.SelectObject(hdc, old_font);
        _ = c.DeleteObject(font);
    }
}

fn rounded(hdc: c.HDC, bounds: c.RECT, fill_color: u32, border_color: u32, radius: i32) void {
    const brush = c.CreateSolidBrush(fill_color);
    const pen = c.CreatePen(c.PS_SOLID, 1, border_color);
    if (brush == null or pen == null) {
        if (brush != null) _ = c.DeleteObject(brush);
        if (pen != null) _ = c.DeleteObject(pen);
        return;
    }
    const old_brush = c.SelectObject(hdc, brush);
    const old_pen = c.SelectObject(hdc, pen);
    _ = c.RoundRect(hdc, bounds.left, bounds.top, bounds.right, bounds.bottom, radius, radius);
    _ = c.SelectObject(hdc, old_pen);
    _ = c.SelectObject(hdc, old_brush);
    _ = c.DeleteObject(pen);
    _ = c.DeleteObject(brush);
}

fn fill(hdc: c.HDC, bounds: c.RECT, color: u32) void {
    const brush = c.CreateSolidBrush(color);
    if (brush == null) return;
    _ = c.FillRect(hdc, &bounds, brush);
    _ = c.DeleteObject(brush);
}

fn line(hdc: c.HDC, x1: i32, y1: i32, x2: i32, y2: i32, color: u32, width: i32) void {
    const pen = c.CreatePen(c.PS_SOLID, width, color);
    if (pen == null) return;
    const old = c.SelectObject(hdc, pen);
    _ = c.MoveToEx(hdc, x1, y1, null);
    _ = c.LineTo(hdc, x2, y2);
    _ = c.SelectObject(hdc, old);
    _ = c.DeleteObject(pen);
}

fn rect(left: i32, top: i32, right: i32, bottom: i32) c.RECT {
    return .{ .left = left, .top = top, .right = right, .bottom = bottom };
}

fn inside(x: i32, y: i32, bounds: c.RECT) bool {
    return x >= bounds.left and x < bounds.right and y >= bounds.top and y < bounds.bottom;
}

fn rgb(red: u8, green: u8, blue: u8) u32 {
    return @as(u32, red) | (@as(u32, green) << 8) | (@as(u32, blue) << 16);
}

test "Windows onboarding matches the four-page macOS contract" {
    try std.testing.expectEqual(@as(u8, 4), page_count);
}

test "onboarding click flow navigates every page and selects a backend" {
    var state = State{ .allocator = std.testing.allocator, .backend = .claudeCode };
    try std.testing.expect(applyClick(&state, 500, 580));
    try std.testing.expectEqual(@as(u8, 1), state.page);
    try std.testing.expect(applyClick(&state, 500, 580));
    try std.testing.expect(applyClick(&state, 500, 580));
    try std.testing.expectEqual(@as(u8, 3), state.page);
    try std.testing.expect(applyClick(&state, 200, 280));
    try std.testing.expectEqual(Backend.copilotCLI, state.backend);
    try std.testing.expect(applyClick(&state, 50, 580));
    try std.testing.expectEqual(@as(u8, 2), state.page);
    try std.testing.expect(applyClick(&state, 500, 580));
    try std.testing.expect(applyClick(&state, 500, 580));
    try std.testing.expect(state.closed);
}

test "onboarding skip closes immediately" {
    var state = State{ .allocator = std.testing.allocator, .backend = .claudeCode };
    try std.testing.expect(!applyClick(&state, 500, 20));
    try std.testing.expect(state.closed);
}

test "onboarding marker persists first-run completion" {
    const marker = "graphcode-onboarding-marker-test";
    std.fs.cwd().deleteFile(marker) catch {};
    defer std.fs.cwd().deleteFile(marker) catch {};
    const store = Store{ .allocator = std.testing.allocator, .marker = @constCast(marker) };
    try std.testing.expect(store.shouldShow());
    try store.markSeen();
    try std.testing.expect(!store.shouldShow());
}

test "onboarding backend values match product settings" {
    try std.testing.expectEqual(Backend.copilotCLI, Backend.parse("copilotCLI"));
    try std.testing.expectEqualStrings("codex", Backend.codex.value());
    try std.testing.expectEqual(Backend.claudeCode, Backend.parse("unknown"));
}

test "first-run marker defaults to showing when absent" {
    const store = Store{ .allocator = std.testing.allocator, .marker = @constCast("definitely-not-present") };
    try std.testing.expect(store.shouldShow());
}
