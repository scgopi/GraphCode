// The app's single standard UI typeface: Segoe UI requested at
// CLEARTYPE_QUALITY, matching the font already used by GraphCanvas.zig's
// `drawTextRect`, WindowsOnboarding.zig, WindowsProductSettings.zig, and
// NativeForms.zig's teaching tiles. Several remaining surfaces (Sidebar's
// owner-drawn rows, WindowsRepositoryDialogs.zig's EDIT/STATIC/BUTTON
// controls) never requested a font at all and so inherited whatever GDI
// stock font was selected into the DC (or `GetStockObject(DEFAULT_GUI_FONT)`
// for created controls) -- both paths accept whatever text-rendering
// quality Windows defaults to rather than explicitly requesting ClearType,
// which is a likely contributor to Windows text looking comparatively
// "crappier"/more aliased than macOS's default AA text rendering. This
// module centralizes font creation so every remaining surface can request
// the exact same ClearType Segoe UI font instead of duplicating the
// creation call or falling back to a stock font.
const std = @import("std");
const Win32 = @import("Win32.zig");
const c = Win32.c;
const Dpi = @import("Dpi.zig");

pub const Style = enum { regular, semibold, card_title, card_mono, card_state };
const Face = enum { segoe, consolas };
const CacheEntry = struct { size: i32, face: Face, weight: i32, font: c.HFONT };

// Rounded card zoom/DPI sizes share this cache with native controls. Handles
// remain process-owned, including while a control has one selected.
var cache: [512]CacheEntry = undefined;
var cache_len: usize = 0;

fn getScaled(scaled_size: i32, face: Face, weight: i32) c.HFONT {
    for (cache[0..cache_len]) |entry| {
        if (entry.size == scaled_size and entry.face == face and entry.weight == weight) return entry.font;
    }
    // Controls borrow these handles for their lifetime; never evict a cached font.
    if (cache_len == cache.len) {
        std.log.warn("UI font cache exhausted (size={d}, face={s}, weight={d})", .{ scaled_size, @tagName(face), weight });
        return null;
    }
    const font = c.CreateFontW(
        -scaled_size,
        0,
        0,
        0,
        weight,
        0,
        0,
        0,
        c.DEFAULT_CHARSET,
        c.OUT_DEFAULT_PRECIS,
        c.CLIP_DEFAULT_PRECIS,
        c.CLEARTYPE_QUALITY,
        c.DEFAULT_PITCH | c.FF_DONTCARE,
        if (face == .consolas) std.unicode.utf8ToUtf16LeStringLiteral("Consolas").ptr else std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI").ptr,
    );
    if (font != null) {
        cache[cache_len] = .{ .size = scaled_size, .face = face, .weight = weight, .font = font };
        cache_len += 1;
    } else {
        std.log.warn("UI font creation failed (size={d}, face={s}, weight={d})", .{ scaled_size, @tagName(face), weight });
    }
    return font;
}

/// Returns the app's standard ClearType-quality Segoe UI font at a logical
/// 96-DPI size. Use `apply` or `select` for live controls and paint DCs so the
/// logical size is scaled to the monitor automatically.
pub fn get(size: i32, bold: bool) c.HFONT {
    return getForDpi(size, bold, Dpi.base_dpi);
}

pub fn getForDpi(size: i32, bold: bool, dpi: u32) c.HFONT {
    return getScaled(Dpi.scale(size, dpi), .segoe, if (bold) c.FW_SEMIBOLD else c.FW_NORMAL);
}

pub fn styleHeight(size: f32, dpi: u32) i32 {
    return @max(1, @as(i32, @intFromFloat(@round(size * @as(f32, @floatFromInt(dpi)) / 96.0))));
}

pub fn getStyle(size: f32, style: Style) c.HFONT {
    return getStyleForDpi(size, style, Dpi.base_dpi);
}

pub fn getStyleForDpi(size: f32, style: Style, dpi: u32) c.HFONT {
    return getScaled(styleHeight(size, dpi), if (style == .card_mono) .consolas else .segoe, switch (style) {
        .regular, .card_mono => c.FW_NORMAL,
        .semibold, .card_title => c.FW_SEMIBOLD,
        .card_state => c.FW_BOLD,
    });
}

/// The standard body-text size used for plain dialog controls (EDIT,
/// STATIC labels, BUTTON captions) that previously fell back to the Win32
/// stock `DEFAULT_GUI_FONT` instead of requesting any font at all.
pub const control_size: i32 = 14;

/// Applies the standard ClearType font to a Win32 control via WM_SETFONT,
/// for controls created with CreateWindowW that would otherwise default
/// to whatever stock font the control class picks (typically the bitmap
/// -hinted `DEFAULT_GUI_FONT`).
pub fn apply(control: c.HWND, size: i32, bold: bool) void {
    if (control == null) return;
    _ = c.SendMessageW(control, c.WM_SETFONT, @intFromPtr(getForDpi(size, bold, Win32.dpiForWindow(control))), 1);
}

/// Selects the standard ClearType font into `hdc` for direct GDI text
/// painting (owner-draw rows, custom WM_PAINT text) and returns the
/// previously-selected font so the caller can restore it afterwards.
pub fn select(hdc: c.HDC, size: i32, bold: bool) c.HGDIOBJ {
    const font = get(size, bold);
    return c.SelectObject(hdc, font);
}

/// Selects a logical-size font scaled for the target DC. Use this only when
/// the caller also scales its text rectangles and surrounding geometry.
pub fn selectForDpi(hdc: c.HDC, size: i32, bold: bool) c.HGDIOBJ {
    const dpi: u32 = @intCast(c.GetDeviceCaps(hdc, c.LOGPIXELSY));
    return c.SelectObject(hdc, getForDpi(size, bold, dpi));
}

test "logical font sizes scale with monitor DPI" {
    try std.testing.expectEqual(@as(i32, 14), Dpi.scale(14, 96));
    try std.testing.expectEqual(@as(i32, 21), Dpi.scale(14, 144));
    try std.testing.expectEqual(@as(i32, 28), Dpi.scale(14, 192));
}

test "get caches distinct fonts per (size, bold) and reuses the same handle" {
    const regular_14 = get(14, false);
    const bold_14 = get(14, true);
    const regular_10 = get(10, false);
    try std.testing.expect(regular_14 != null);
    try std.testing.expect(bold_14 != null);
    try std.testing.expect(regular_10 != null);
    try std.testing.expect(regular_14 != bold_14);
    try std.testing.expect(regular_14 != regular_10);
    // Repeated calls with the same (size, bold) must return the cached
    // handle rather than creating a new GDI font object each time.
    try std.testing.expectEqual(regular_14, get(14, false));
    try std.testing.expectEqual(bold_14, get(14, true));
}

test "loop card parity font faces weights and cache growth" {
    _ = get(14, false);
    _ = get(14, true);
    try std.testing.expectEqual(get(15, true), getStyle(14.5, .card_title));
    const starting_count = cache_len;
    const styles = [_]Style{ .card_title, .card_mono, .card_state };
    const sizes = [_]f32{ 14.5, 10.5, 10 };
    var handles: [3 * 26 * 4]c.HFONT = undefined;
    var key_count: usize = 0;
    for (0..2) |sweep| {
        var index: usize = 0;
        for (0..26) |step| {
            const zoom = 0.55 + @as(f32, @floatFromInt(step)) * 0.05;
            for ([_]u32{ 96, 120, 144, 192 }) |dpi| {
                for (styles, sizes) |style, size| {
                    const font = getStyleForDpi(size * zoom, style, dpi);
                    try std.testing.expect(font != null);
                    var info = std.mem.zeroes(c.LOGFONTW);
                    try std.testing.expect(c.GetObjectW(font, @sizeOf(c.LOGFONTW), &info) != 0);
                    try std.testing.expectEqual(-styleHeight(size * zoom, dpi), info.lfHeight);
                    try std.testing.expectEqual(@as(i32, if (style == .card_title) c.FW_SEMIBOLD else if (style == .card_state) c.FW_BOLD else c.FW_NORMAL), info.lfWeight);
                    const family = if (style == .card_mono) std.unicode.utf8ToUtf16LeStringLiteral("Consolas") else std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI");
                    try std.testing.expectEqualSlices(u16, family, std.mem.sliceTo(&info.lfFaceName, 0));
                    if (sweep == 0) handles[index] = font else try std.testing.expectEqual(handles[index], font);
                    index += 1;
                }
            }
        }
        if (sweep == 0) {
            try std.testing.expect(cache_len > starting_count);
            try std.testing.expect(cache_len - starting_count <= handles.len);
            key_count = cache_len;
        } else try std.testing.expectEqual(key_count, cache_len);
    }
    try std.testing.expectEqual(@as(i32, 15), styleHeight(14.5, 96));
    try std.testing.expectEqual(@as(i32, 11), styleHeight(10.5, 96));
}

test "loop card parity full cache refuses without creating uncached handles" {
    const font = get(14, false);
    const saved_len = cache_len;
    defer cache_len = saved_len;
    while (cache_len < cache.len) : (cache_len += 1) cache[cache_len] = cache[0];
    try std.testing.expectEqual(font, get(14, false));
    try std.testing.expect(getStyle(123, .card_mono) == null);
}
