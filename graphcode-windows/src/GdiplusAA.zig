// Minimal GDI+ "flat" C-API bindings used solely to anti-alias the graph
// canvas's line/curve/rounded-rect drawing. Classic GDI pens created via
// CreatePen are never anti-aliased, which is a primary cause of edges,
// connectors, and selection rings looking visibly "jaggier" on Windows
// than the same shapes rendered by macOS's Core Graphics (which
// anti-aliases by default). GDI+ is a standard, always-present Windows
// component (gdiplus.dll) that supports SmoothingMode::AntiAlias without
// requiring a larger Direct2D migration.
//
// This module is intentionally small and defensive: every draw call
// gracefully no-ops (returning false) if GDI+ failed to initialize or if
// any GDI+ call fails, so every call site retains its original plain-GDI
// fallback path and this cannot regress or destabilize existing rendering.
const std = @import("std");
const c = @import("Win32.zig").c;

const GpStatus = c_int;
const Ok: GpStatus = 0;

const GpGraphics = opaque {};
const GpPen = opaque {};
const GpPath = opaque {};
const GpBrush = opaque {};

const SmoothingModeAntiAlias: c_int = 4;
const UnitPixel: c_int = 2;
const FillModeAlternate: c_int = 0;

const GdiplusStartupInput = extern struct {
    GdiplusVersion: u32 = 1,
    DebugEventCallback: ?*anyopaque = null,
    SuppressBackgroundThread: c.BOOL = 0,
    SuppressExternalCodecs: c.BOOL = 0,
};

extern "gdiplus" fn GdiplusStartup(
    token: *usize,
    input: *const GdiplusStartupInput,
    output: ?*anyopaque,
) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdiplusShutdown(token: usize) callconv(.winapi) void;
extern "gdiplus" fn GdipCreateFromHDC(hdc: c.HDC, graphics: **GpGraphics) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipDeleteGraphics(graphics: *GpGraphics) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipSetSmoothingMode(graphics: *GpGraphics, mode: c_int) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipCreatePen1(color: u32, width: f32, unit: c_int, pen: **GpPen) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipDeletePen(pen: *GpPen) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipDrawLineI(graphics: *GpGraphics, pen: *GpPen, x1: c_int, y1: c_int, x2: c_int, y2: c_int) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipDrawBezierI(
    graphics: *GpGraphics,
    pen: *GpPen,
    x1: c_int,
    y1: c_int,
    x2: c_int,
    y2: c_int,
    x3: c_int,
    y3: c_int,
    x4: c_int,
    y4: c_int,
) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipCreatePath(brush_mode: c_int, path: **GpPath) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipDeletePath(path: *GpPath) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipAddPathArcI(path: *GpPath, x: c_int, y: c_int, width: c_int, height: c_int, start_angle: f32, sweep_angle: f32) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipClosePathFigure(path: *GpPath) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipDrawPath(graphics: *GpGraphics, pen: *GpPen, path: *GpPath) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipFillPath(graphics: *GpGraphics, brush: *GpBrush, path: *GpPath) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipCreateSolidFill(color: u32, brush: **GpBrush) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipDeleteBrush(brush: *GpBrush) callconv(.winapi) GpStatus;

var startup_mutex: std.Thread.Mutex = .{};
var startup_token: usize = 0;
var available: bool = false;
var start_attempted: bool = false;
var shutdown_requested: bool = false;

const SystemStartup = struct {
    pub fn run() ?usize {
        var token: usize = 0;
        var input = GdiplusStartupInput{};
        if (GdiplusStartup(&token, &input, null) != Ok) return null;
        return token;
    }
};

/// Starts optional GDI+ initialization away from the UI thread. Until the
/// worker succeeds, every draw call returns false and the caller uses plain GDI.
pub fn init() void {
    initWith(SystemStartup);
}

pub fn initWith(comptime Startup: type) void {
    startup_mutex.lock();
    if (start_attempted or shutdown_requested) {
        startup_mutex.unlock();
        return;
    }
    start_attempted = true;
    startup_mutex.unlock();

    const Worker = struct {
        fn run() void {
            const token = Startup.run() orelse return;
            startup_mutex.lock();
            if (shutdown_requested) {
                startup_mutex.unlock();
                GdiplusShutdown(token);
                return;
            }
            startup_token = token;
            available = true;
            startup_mutex.unlock();
        }
    };
    var worker = std.Thread.spawn(.{}, Worker.run, .{}) catch return;
    worker.detach();
}

/// Prevents new GDI+ sessions and releases a completed process-global startup.
/// A worker still blocked inside Windows remains detached and cannot delay exit.
pub fn deinit() void {
    startup_mutex.lock();
    shutdown_requested = true;
    if (!available) {
        startup_mutex.unlock();
        return;
    }
    available = false;
    const token = startup_token;
    startup_token = 0;
    startup_mutex.unlock();
    GdiplusShutdown(token);
}

fn colorrefToArgb(colorref: u32) u32 {
    const r = colorref & 0xFF;
    const g = (colorref >> 8) & 0xFF;
    const b = (colorref >> 16) & 0xFF;
    return 0xFF000000 | (r << 16) | (g << 8) | b;
}

const Session = struct {
    graphics: *GpGraphics,
    pen: *GpPen,
};

fn beginSession(hdc: c.HDC, colorref: u32, width: f32) ?Session {
    startup_mutex.lock();
    if (!available) {
        startup_mutex.unlock();
        return null;
    }
    var graphics: *GpGraphics = undefined;
    if (GdipCreateFromHDC(hdc, &graphics) != Ok) {
        startup_mutex.unlock();
        return null;
    }
    if (GdipSetSmoothingMode(graphics, SmoothingModeAntiAlias) != Ok) {
        _ = GdipDeleteGraphics(graphics);
        startup_mutex.unlock();
        return null;
    }
    var pen: *GpPen = undefined;
    if (GdipCreatePen1(colorrefToArgb(colorref), width, UnitPixel, &pen) != Ok) {
        _ = GdipDeleteGraphics(graphics);
        startup_mutex.unlock();
        return null;
    }
    return .{ .graphics = graphics, .pen = pen };
}

fn endSession(session: Session) void {
    _ = GdipDeletePen(session.pen);
    _ = GdipDeleteGraphics(session.graphics);
    startup_mutex.unlock();
}

/// Draws an anti-aliased straight line. Returns false (drawing nothing)
/// if GDI+ is unavailable so the caller can fall back to CreatePen/LineTo.
pub fn drawLine(hdc: c.HDC, x1: i32, y1: i32, x2: i32, y2: i32, colorref: u32, width: f32) bool {
    const session = beginSession(hdc, colorref, width) orelse return false;
    defer endSession(session);
    return GdipDrawLineI(session.graphics, session.pen, x1, y1, x2, y2) == Ok;
}

/// Draws an anti-aliased cubic Bezier curve (the same 4-point control
/// convention as Win32's PolyBezier for a single segment).
pub fn drawBezier(
    hdc: c.HDC,
    x1: i32,
    y1: i32,
    x2: i32,
    y2: i32,
    x3: i32,
    y3: i32,
    x4: i32,
    y4: i32,
    colorref: u32,
    width: f32,
) bool {
    const session = beginSession(hdc, colorref, width) orelse return false;
    defer endSession(session);
    return GdipDrawBezierI(session.graphics, session.pen, x1, y1, x2, y2, x3, y3, x4, y4) == Ok;
}

fn buildRoundedRectPath(x: i32, y: i32, width: i32, height: i32, radius: i32) ?*GpPath {
    var path: *GpPath = undefined;
    if (GdipCreatePath(FillModeAlternate, &path) != Ok) return null;
    const d = radius * 2;
    const right = x + width;
    const bottom = y + height;
    var ok = true;
    ok = ok and GdipAddPathArcI(path, x, y, d, d, 180, 90) == Ok;
    ok = ok and GdipAddPathArcI(path, right - d, y, d, d, 270, 90) == Ok;
    ok = ok and GdipAddPathArcI(path, right - d, bottom - d, d, d, 0, 90) == Ok;
    ok = ok and GdipAddPathArcI(path, x, bottom - d, d, d, 90, 90) == Ok;
    ok = ok and GdipClosePathFigure(path) == Ok;
    if (!ok) {
        _ = GdipDeletePath(path);
        return null;
    }
    return path;
}

/// Draws an anti-aliased filled-and-stroked rounded rectangle, replacing
/// GDI's `RoundRect` (whose curved corners are never anti-aliased) for the
/// graph canvas's node cards and selection rings. Returns false if GDI+
/// drawing failed at any step, in which case the caller should fall back
/// to the original `CreateSolidBrush` + `CreatePen` + `RoundRect` path.
pub fn drawRoundedRect(
    hdc: c.HDC,
    bounds: c.RECT,
    radius: i32,
    fill_colorref: u32,
    border_colorref: u32,
    border_width: f32,
) bool {
    startup_mutex.lock();
    defer startup_mutex.unlock();
    if (!available) return false;
    var graphics: *GpGraphics = undefined;
    if (GdipCreateFromHDC(hdc, &graphics) != Ok) return false;
    defer _ = GdipDeleteGraphics(graphics);
    if (GdipSetSmoothingMode(graphics, SmoothingModeAntiAlias) != Ok) return false;

    const width = bounds.right - bounds.left;
    const height = bounds.bottom - bounds.top;
    const clamped_radius = @min(radius, @divTrunc(@min(width, height), 2));
    const path = buildRoundedRectPath(bounds.left, bounds.top, width, height, clamped_radius) orelse return false;
    defer _ = GdipDeletePath(path);

    var brush: *GpBrush = undefined;
    if (GdipCreateSolidFill(colorrefToArgb(fill_colorref), &brush) != Ok) return false;
    defer _ = GdipDeleteBrush(brush);
    if (GdipFillPath(graphics, brush, path) != Ok) return false;

    var pen: *GpPen = undefined;
    if (GdipCreatePen1(colorrefToArgb(border_colorref), border_width, UnitPixel, &pen) != Ok) return false;
    defer _ = GdipDeletePen(pen);
    return GdipDrawPath(graphics, pen, path) == Ok;
}

test "colorrefToArgb preserves channel order" {
    // COLORREF 0x00BBGGRR -> ARGB 0xAARRGGBB with full alpha.
    // 0x007AB8FF is B=0x7A, G=0xB8, R=0xFF, so ARGB is 0xFF (alpha) FF (R) B8 (G) 7A (B).
    try std.testing.expectEqual(@as(u32, 0xFFFFB87A), colorrefToArgb(0x007AB8FF));
}
