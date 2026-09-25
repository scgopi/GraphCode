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

const CacheEntry = struct { size: i32, bold: bool, font: c.HFONT };

// Small fixed cache: the app only ever requests a handful of distinct
// (size, bold) pairs across all surfaces, so a linear scan over a short
// array is simpler and cheaper than a hash map, and every font lives for
// the process lifetime exactly like the other cached GDI fonts/brushes
// already in this codebase (e.g. NativeForms.zig's `cachedTileFont`).
var cache: [32]CacheEntry = undefined;
var cache_len: usize = 0;

fn getScaled(scaled_size: i32, bold: bool) c.HFONT {
    for (cache[0..cache_len]) |entry| {
        if (entry.size == scaled_size and entry.bold == bold) return entry.font;
    }
    const font = c.CreateFontW(
        -scaled_size,
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
        std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI").ptr,
    );
    if (font != null and cache_len < cache.len) {
        cache[cache_len] = .{ .size = scaled_size, .bold = bold, .font = font };
        cache_len += 1;
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
    return getScaled(Dpi.scale(size, dpi), bold);
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
