const std = @import("std");

pub const c = @cImport({
    @cDefine("GHOSTTY_STATIC", "1");
    @cInclude("ghostty/vt.h");
});

pub const environment_name = "GRAPHCODE_EXPERIMENTAL_TERMINAL_VT";
pub const response_capacity = 64 * 1024;
pub const Error = error{
    OutOfMemory,
    InvalidValue,
    OutOfSpace,
    NoValue,
    UnexpectedResult,
    InvalidSize,
    InvalidSnapshot,
    RenderStateUnreliable,
    ResizeFailed,
    ResponseOverflow,
    ResponseDeliveryFailed,
};

pub fn parseFlag(value: ?[]const u8) error{InvalidTerminalVtFlag}!bool {
    const text = value orelse return true;
    if (std.mem.eql(u8, text, "0")) return false;
    if (std.mem.eql(u8, text, "1")) return true;
    return error.InvalidTerminalVtFlag;
}

pub fn startupEnabled(allocator: std.mem.Allocator) !bool {
    const value = std.process.getEnvVarOwned(allocator, environment_name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return true,
        else => return err,
    };
    defer allocator.free(value);
    return parseFlag(value) catch |err| {
        std.debug.print("{s} must be absent, 0, or 1: {s}\n", .{ environment_name, @errorName(err) });
        return err;
    };
}

fn check(result: c.GhosttyResult) Error!void {
    return switch (result) {
        c.GHOSTTY_SUCCESS => {},
        c.GHOSTTY_OUT_OF_MEMORY => error.OutOfMemory,
        c.GHOSTTY_INVALID_VALUE => error.InvalidValue,
        c.GHOSTTY_OUT_OF_SPACE => error.OutOfSpace,
        c.GHOSTTY_NO_VALUE => error.NoValue,
        else => error.UnexpectedResult,
    };
}

pub const Cell = struct {
    raw: c.GhosttyCell,
    codepoints: []const u32,
    style: c.GhosttyStyle,
    wide: c.GhosttyCellWide,
    content: c.GhosttyCellContentTag,
    semantic: c.GhosttyCellSemanticContent,
    hyperlink: bool,
    protected: bool,
    foreground: ?c.GhosttyColorRgb,
    background: ?c.GhosttyColorRgb,
};

pub const Row = struct {
    raw: c.GhosttyRow,
    wrap: bool,
    continuation: bool,
};

pub const Cursor = struct {
    visible: bool,
    blinking: bool,
    password: bool,
    style: c.GhosttyRenderStateCursorVisualStyle,
    in_viewport: bool,
    x: u16 = 0,
    y: u16 = 0,
    wide_tail: bool = false,
    pending_wrap: bool,
};

/// A cell position in screen coordinates: row 0 is the oldest scrollback row, so a point keeps
/// naming the same text while output scrolls the viewport.
pub const ScreenPoint = struct {
    x: u16,
    y: u32,

    pub fn eql(self: ScreenPoint, other: ScreenPoint) bool {
        return self.x == other.x and self.y == other.y;
    }

    pub fn before(self: ScreenPoint, other: ScreenPoint) bool {
        return self.y < other.y or (self.y == other.y and self.x < other.x);
    }
};

pub const GridCell = struct {
    /// The cell's first scalar; zero for a blank cell.
    codepoint: u32,
    wide: c.GhosttyCellWide,
    /// The row soft-wraps into the next one.
    wraps: bool,
    /// The row continues a soft-wrapped row above it.
    continuation: bool,
};

pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    columns: u16,
    rows: u16,
    cells: []Cell,
    row_data: []Row,
    colors: c.GhosttyRenderStateColors,
    cursor: Cursor,
    active_screen: c.GhosttyTerminalScreen,
    scrollbar: c.GhosttyTerminalScrollbar,
    title: []const u8,
    pwd: []const u8,
    text: []const u8,
    utf16: []const u16,
    // One offset per grid position plus an end-of-row offset. Wide tails
    // share their leading cell's offset; spacers do not invent text.
    offsets: []usize,
    caret: ?usize,

    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

// The host accepts only one scalar and two colors per cell. Keeping this
// projection separate prevents an unsupported cell from corrupting VT state.
pub const HostCell = extern struct {
    pub const foreground_set: u32 = 1 << 0;
    pub const background_set: u32 = 1 << 1;

    codepoint: u32,
    fg: u32,
    bg: u32,
    flags: u32,
};

pub fn project(snapshot: *const Snapshot, output: []HostCell) error{ UnsupportedHostCell, InvalidGrid }!void {
    if (output.len != snapshot.cells.len) return error.InvalidGrid;
    for (snapshot.cells) |cell| {
        const s = cell.style;
        if (cell.wide != c.GHOSTTY_CELL_WIDE_NARROW or cell.codepoints.len > 1 or
            s.bold or s.italic or s.faint or s.blink or s.strikethrough or s.overline or
            s.underline != 0 or s.underline_color.tag != c.GHOSTTY_STYLE_COLOR_NONE)
            return error.UnsupportedHostCell;
        if (cell.codepoints.len == 1) {
            const cp = cell.codepoints[0];
            if (cp < 0x20 or (cp >= 0x7f and cp <= 0x9f) or
                cp > 0x10ffff or (cp >= 0xd800 and cp <= 0xdfff))
                return error.UnsupportedHostCell;
        }
    }
    for (snapshot.cells, output) |cell, *out| {
        var fg = cell.foreground orelse snapshot.colors.foreground;
        var bg = cell.background orelse snapshot.colors.background;
        if (cell.style.inverse) std.mem.swap(c.GhosttyColorRgb, &fg, &bg);
        if (cell.style.invisible) fg = bg;
        out.* = .{
            .codepoint = if (cell.codepoints.len == 0) ' ' else cell.codepoints[0],
            .fg = rgb(fg),
            .bg = rgb(bg),
            .flags = HostCell.foreground_set | HostCell.background_set,
        };
    }
}

fn rgb(color: c.GhosttyColorRgb) u32 {
    return (@as(u32, color.r) << 16) | (@as(u32, color.g) << 8) | color.b;
}

pub const max_mouse_sequence_bytes = 32;

pub const MouseAction = enum { press, release, motion };
pub const MouseButton = enum { none, left, middle, right, wheel_up, wheel_down };

/// One pointer event in surface pixels. `any_button_pressed` says whether a button is down
/// (motion with no button reports differently from a drag).
pub const MouseEvent = struct {
    action: MouseAction,
    button: MouseButton = .none,
    shift: bool = false,
    ctrl: bool = false,
    x: i32,
    y: i32,
    any_button_pressed: bool = false,
};

pub const MouseGeometry = struct {
    columns: u16,
    rows: u16,
    cell_width: u32,
    cell_height: u32,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    bridge: c.GhosttyAllocator,
    terminal: c.GhosttyTerminal = null,
    render: c.GhosttyRenderState = null,
    row_iterator: c.GhosttyRenderStateRowIterator = null,
    row_cells: c.GhosttyRenderStateRowCells = null,
    allocation_failed: bool = false,
    failure: ?Error = null,
    snapshot: ?Snapshot = null,
    snapshot_current: bool = false,
    response_buffer: [response_capacity]u8 = undefined,
    response_length: usize = 0,
    response_overflow: bool = false,
    response_delivery_failed: bool = false,
    mouse_encoder: c.GhosttyMouseEncoder = null,
    mouse_last_cell: ?[2]u32 = null,
    /// How many times the program has switched mouse tracking from on to off (counting a
    /// reset that is switched back on within the same buffer); see `feed`.
    mouse_tracking_resets: u32 = 0,
    mode_scan: enum { ground, escape, csi, private } = .ground,

    pub fn create(allocator: std.mem.Allocator, columns: usize, rows: usize) Error!*State {
        const size = try dimensions(columns, rows);
        const self = try allocator.create(State);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .bridge = .{ .ctx = self, .vtable = &allocator_vtable } };
        try check(c.ghostty_terminal_new(&self.bridge, &self.terminal, .{
            .cols = size[0],
            .rows = size[1],
            .max_scrollback = 10_000,
        }));
        errdefer c.ghostty_terminal_free(self.terminal);
        try check(c.ghostty_render_state_new(&self.bridge, &self.render));
        errdefer c.ghostty_render_state_free(self.render);
        try check(c.ghostty_render_state_row_iterator_new(&self.bridge, &self.row_iterator));
        errdefer c.ghostty_render_state_row_iterator_free(self.row_iterator);
        try check(c.ghostty_render_state_row_cells_new(&self.bridge, &self.row_cells));
        errdefer c.ghostty_render_state_row_cells_free(self.row_cells);
        try check(c.ghostty_terminal_set(self.terminal, c.GHOSTTY_TERMINAL_OPT_USERDATA, self));
        try check(c.ghostty_terminal_set(self.terminal, c.GHOSTTY_TERMINAL_OPT_WRITE_PTY, @ptrCast(&writePty)));
        try self.refresh();
        return self;
    }

    pub fn destroy(self: *State) void {
        if (self.snapshot) |*snapshot| snapshot.deinit();
        if (self.mouse_encoder != null) c.ghostty_mouse_encoder_free(self.mouse_encoder);
        c.ghostty_render_state_row_cells_free(self.row_cells);
        c.ghostty_render_state_row_iterator_free(self.row_iterator);
        c.ghostty_render_state_free(self.render);
        c.ghostty_terminal_free(self.terminal);
        self.allocator.destroy(self);
    }

    pub fn feed(self: *State, bytes: []const u8) Error!void {
        if (self.failure) |err| return err;
        self.snapshot_current = false;
        // vt_write returns void. A completed call is not a parse-success result.
        // The mouse-tracking state is looked at after every sequence that can switch it off, not
        // only at the end, so a program that switches it off and on again within one buffer (or
        // one sequence split across two) is still seen to have done so.
        var was_tracking = self.mouseTrackingEnabled();
        var start: usize = 0;
        for (bytes, 0..) |byte, index| {
            if (!self.endsMouseModeSequence(byte)) continue;
            c.ghostty_terminal_vt_write(self.terminal, bytes[start..].ptr, index + 1 - start);
            start = index + 1;
            was_tracking = self.noteMouseTracking(was_tracking);
        }
        if (start < bytes.len or bytes.len == 0) {
            c.ghostty_terminal_vt_write(self.terminal, bytes[start..].ptr, bytes.len - start);
            _ = self.noteMouseTracking(was_tracking);
        }
        try self.refresh();
        if (self.response_delivery_failed) return error.ResponseDeliveryFailed;
        if (self.response_overflow) return error.ResponseOverflow;
    }

    fn noteMouseTracking(self: *State, was_tracking: bool) bool {
        const tracking = self.mouseTrackingEnabled();
        if (was_tracking and !tracking) self.mouse_tracking_resets +%= 1;
        return tracking;
    }

    /// Follows just enough of the escape sequences in the stream to tell where one that can
    /// switch mouse tracking off ends: a private-mode reset (CSI ? ... l) or a full
    /// terminal reset (ESC c). Other bytes only move it along; a wrong guess
    /// (a sequence inside a string) costs a split of the buffer and nothing else.
    fn endsMouseModeSequence(self: *State, byte: u8) bool {
        const next: @TypeOf(self.mode_scan) = switch (self.mode_scan) {
            .ground => if (byte == 0x1b) .escape else .ground,
            .escape => switch (byte) {
                '[' => .csi,
                0x1b => .escape,
                'c' => return self.endSequence(),
                else => .ground,
            },
            .csi => switch (byte) {
                '?' => .private,
                0x1b => .escape,
                else => .ground,
            },
            .private => switch (byte) {
                '0'...'9', ';', ':' => .private,
                'l' => return self.endSequence(),
                0x1b => .escape,
                else => .ground,
            },
        };
        self.mode_scan = next;
        return false;
    }

    fn endSequence(self: *State) bool {
        self.mode_scan = .ground;
        return true;
    }

    pub fn resize(self: *State, columns: usize, rows: usize) Error!void {
        const size = try dimensions(columns, rows);
        if (self.failure) |err| return err;
        self.snapshot_current = false;
        check(c.ghostty_terminal_resize(self.terminal, size[0], size[1], 0, 0)) catch {
            self.failure = if (self.allocation_failed) error.RenderStateUnreliable else error.ResizeFailed;
            return self.failure.?;
        };
        try self.refresh();
        if (self.response_delivery_failed) return error.ResponseDeliveryFailed;
        if (self.response_overflow) return error.ResponseOverflow;
    }

    pub fn scrollViewport(self: *State, delta: isize) Error!void {
        if (self.failure) |err| return err;
        self.snapshot_current = false;
        c.ghostty_terminal_scroll_viewport(self.terminal, .{
            .tag = c.GHOSTTY_SCROLL_VIEWPORT_DELTA,
            .value = .{ .delta = delta },
        });
        try self.refresh();
        if (self.response_delivery_failed) return error.ResponseDeliveryFailed;
        if (self.response_overflow) return error.ResponseOverflow;
    }

    pub fn responses(self: *const State) []const u8 {
        return self.response_buffer[0..self.response_length];
    }

    pub fn consumeResponses(self: *State) void {
        self.response_length = 0;
    }

    /// Whether the running program asked for bracketed paste (DECSET 2004).
    pub fn bracketedPasteEnabled(self: *const State) bool {
        var enabled = false;
        if (c.ghostty_terminal_mode_get(self.terminal, c.ghostty_mode_new(2004, false), &enabled) != c.GHOSTTY_SUCCESS)
            return false;
        return enabled;
    }

    /// Whether the running program asked for mouse reports (DECSET 9, 1000, 1002 or 1003).
    pub fn mouseTrackingEnabled(self: *const State) bool {
        var enabled = false;
        if (c.ghostty_terminal_get(self.terminal, c.GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &enabled) != c.GHOSTTY_SUCCESS)
            return false;
        return enabled;
    }

    /// Encodes one mouse event the way the program asked to receive it (tracking mode from
    /// DECSET 9/1000/1002/1003, format from 1005/1006/1015/1016). The result is empty when the
    /// program's mode does not report this event, for example motion under normal tracking.
    /// Motion that stays in the cell of the last report is dropped here (except in SGR-pixels
    /// format, where it is meaningful): the encoder's own cell tracking resets whenever its
    /// options are refreshed from the terminal, which this does on every call.
    pub fn encodeMouse(
        self: *State,
        buffer: *[max_mouse_sequence_bytes]u8,
        event: MouseEvent,
        geometry: MouseGeometry,
    ) Error![]const u8 {
        if (geometry.cell_width == 0 or geometry.cell_height == 0 or geometry.columns == 0 or geometry.rows == 0)
            return error.InvalidSize;
        if (!self.mouseTrackingEnabled()) {
            self.mouse_last_cell = null;
            return buffer[0..0];
        }
        if (self.mouse_encoder == null) try check(c.ghostty_mouse_encoder_new(&self.bridge, &self.mouse_encoder));
        const encoder = self.mouse_encoder;
        c.ghostty_mouse_encoder_setopt_from_terminal(encoder, self.terminal);
        var size = std.mem.zeroes(c.GhosttyMouseEncoderSize);
        size.size = @sizeOf(c.GhosttyMouseEncoderSize);
        size.screen_width = @as(u32, geometry.columns) * geometry.cell_width;
        size.screen_height = @as(u32, geometry.rows) * geometry.cell_height;
        size.cell_width = geometry.cell_width;
        size.cell_height = geometry.cell_height;
        c.ghostty_mouse_encoder_setopt(encoder, c.GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size);
        c.ghostty_mouse_encoder_setopt(encoder, c.GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &event.any_button_pressed);

        var native: c.GhosttyMouseEvent = null;
        try check(c.ghostty_mouse_event_new(&self.bridge, &native));
        defer c.ghostty_mouse_event_free(native);
        c.ghostty_mouse_event_set_action(native, switch (event.action) {
            .press => c.GHOSTTY_MOUSE_ACTION_PRESS,
            .release => c.GHOSTTY_MOUSE_ACTION_RELEASE,
            .motion => c.GHOSTTY_MOUSE_ACTION_MOTION,
        });
        switch (event.button) {
            .none => c.ghostty_mouse_event_clear_button(native),
            .left => c.ghostty_mouse_event_set_button(native, c.GHOSTTY_MOUSE_BUTTON_LEFT),
            .middle => c.ghostty_mouse_event_set_button(native, c.GHOSTTY_MOUSE_BUTTON_MIDDLE),
            .right => c.ghostty_mouse_event_set_button(native, c.GHOSTTY_MOUSE_BUTTON_RIGHT),
            .wheel_up => c.ghostty_mouse_event_set_button(native, c.GHOSTTY_MOUSE_BUTTON_FOUR),
            .wheel_down => c.ghostty_mouse_event_set_button(native, c.GHOSTTY_MOUSE_BUTTON_FIVE),
        }
        var mods: c.GhosttyMods = 0;
        if (event.shift) mods |= c.GHOSTTY_MODS_SHIFT;
        if (event.ctrl) mods |= c.GHOSTTY_MODS_CTRL;
        c.ghostty_mouse_event_set_mods(native, mods);
        const max_x: i32 = @intCast(size.screen_width - 1);
        const max_y: i32 = @intCast(size.screen_height - 1);
        const x = std.math.clamp(event.x, 0, max_x);
        const y = std.math.clamp(event.y, 0, max_y);
        c.ghostty_mouse_event_set_position(native, .{ .x = @floatFromInt(x), .y = @floatFromInt(y) });
        const cell = [2]u32{
            @intCast(@divTrunc(x, @as(i32, @intCast(geometry.cell_width)))),
            @intCast(@divTrunc(y, @as(i32, @intCast(geometry.cell_height)))),
        };
        if (event.action == .motion and !self.modeEnabled(1016)) {
            if (self.mouse_last_cell) |last| {
                if (last[0] == cell[0] and last[1] == cell[1]) return buffer[0..0];
            }
        }

        var written: usize = 0;
        try check(c.ghostty_mouse_encoder_encode(encoder, native, buffer, buffer.len, &written));
        if (written != 0) self.mouse_last_cell = cell;
        return buffer[0..written];
    }

    fn modeEnabled(self: *const State, mode: u16) bool {
        var enabled = false;
        if (c.ghostty_terminal_mode_get(self.terminal, c.ghostty_mode_new(mode, false), &enabled) != c.GHOSTTY_SUCCESS)
            return false;
        return enabled;
    }

    /// Forgets the last reported cell, so the next motion is reported even if it is in the same
    /// cell. Call when the pointer leaves the terminal.
    pub fn resetMouse(self: *State) void {
        self.mouse_last_cell = null;
    }

    /// First screen row (scrollback included) shown at the top of the viewport.
    pub fn viewportTop(self: *const State) u32 {
        const snapshot = self.snapshot orelse return 0;
        return std.math.cast(u32, snapshot.scrollbar.offset) orelse std.math.maxInt(u32);
    }

    fn gridRef(self: *State, point: ScreenPoint) ?c.GhosttyGridRef {
        var ref = std.mem.zeroes(c.GhosttyGridRef);
        ref.size = @sizeOf(c.GhosttyGridRef);
        const status = c.ghostty_terminal_grid_ref(self.terminal, .{
            .tag = c.GHOSTTY_POINT_TAG_SCREEN,
            .value = .{ .coordinate = .{ .x = point.x, .y = point.y } },
        }, &ref);
        return if (status == c.GHOSTTY_SUCCESS) ref else null;
    }

    /// What the grid holds at `point` (screen coordinates, scrollback included), read straight
    /// from the terminal rather than the viewport snapshot. Null when the point is off the grid.
    pub fn cellAt(self: *State, point: ScreenPoint) ?GridCell {
        const ref = self.gridRef(point) orelse return null;
        var cell: c.GhosttyCell = undefined;
        var row: c.GhosttyRow = undefined;
        if (c.ghostty_grid_ref_cell(&ref, &cell) != c.GHOSTTY_SUCCESS) return null;
        if (c.ghostty_grid_ref_row(&ref, &row) != c.GHOSTTY_SUCCESS) return null;
        var result = GridCell{ .codepoint = 0, .wide = c.GHOSTTY_CELL_WIDE_NARROW, .wraps = false, .continuation = false };
        if (c.ghostty_cell_get(cell, c.GHOSTTY_CELL_DATA_WIDE, &result.wide) != c.GHOSTTY_SUCCESS) return null;
        var codepoints: [1]u32 = undefined;
        var length: usize = 0;
        const text = c.ghostty_grid_ref_graphemes(&ref, &codepoints, codepoints.len, &length);
        if (text == c.GHOSTTY_SUCCESS or text == c.GHOSTTY_OUT_OF_SPACE) {
            if (length != 0) result.codepoint = codepoints[0];
        } else return null;
        if (c.ghostty_row_get(row, c.GHOSTTY_ROW_DATA_WRAP, &result.wraps) != c.GHOSTTY_SUCCESS) return null;
        if (c.ghostty_row_get(row, c.GHOSTTY_ROW_DATA_WRAP_CONTINUATION, &result.continuation) != c.GHOSTTY_SUCCESS) return null;
        return result;
    }

    /// The text between two screen points, inclusive and in reading order, exactly as Ghostty
    /// copies it: soft-wrapped rows join into one line, hard line breaks stay, and blank cells
    /// after the last character of a line are dropped.
    pub fn selectionText(self: *State, allocator: std.mem.Allocator, start: ScreenPoint, end: ScreenPoint) Error![]u8 {
        if (self.failure) |err| return err;
        var selection = std.mem.zeroes(c.GhosttySelection);
        selection.size = @sizeOf(c.GhosttySelection);
        selection.start = self.gridRef(start) orelse return error.InvalidValue;
        selection.end = self.gridRef(end) orelse return error.InvalidValue;
        var options = std.mem.zeroes(c.GhosttyFormatterTerminalOptions);
        options.size = @sizeOf(c.GhosttyFormatterTerminalOptions);
        options.emit = c.GHOSTTY_FORMATTER_FORMAT_PLAIN;
        options.unwrap = true;
        options.trim = true;
        options.extra.size = @sizeOf(c.GhosttyFormatterTerminalExtra);
        options.extra.screen.size = @sizeOf(c.GhosttyFormatterScreenExtra);
        options.selection = &selection;
        var formatter: c.GhosttyFormatter = null;
        try check(c.ghostty_formatter_terminal_new(&self.bridge, &formatter, self.terminal, options));
        defer c.ghostty_formatter_free(formatter);
        var required: usize = 0;
        const probe = c.ghostty_formatter_format_buf(formatter, null, 0, &required);
        if (probe != c.GHOSTTY_OUT_OF_SPACE and probe != c.GHOSTTY_SUCCESS) try check(probe);
        const text = try allocator.alloc(u8, required);
        errdefer allocator.free(text);
        var written: usize = 0;
        try check(c.ghostty_formatter_format_buf(formatter, text.ptr, text.len, &written));
        if (written > text.len) return error.UnexpectedResult;
        return allocator.realloc(text, written) catch text[0..written];
    }

    fn refresh(self: *State) Error!void {
        if (self.allocation_failed) {
            self.failure = error.RenderStateUnreliable;
            return error.RenderStateUnreliable;
        }
        check(c.ghostty_render_state_update(self.render, self.terminal)) catch |err| {
            self.failure = if (self.allocation_failed) error.RenderStateUnreliable else err;
            return self.failure.?;
        };
        if (self.allocation_failed) {
            self.failure = error.RenderStateUnreliable;
            return error.RenderStateUnreliable;
        }
        const next = try self.capture();
        if (self.snapshot) |*old| old.deinit();
        self.snapshot = next;
        self.snapshot_current = true;
    }

    fn renderGet(self: *State, comptime T: type, key: c.GhosttyRenderStateData) Error!T {
        var result: T = undefined;
        try check(c.ghostty_render_state_get(self.render, key, &result));
        return result;
    }

    fn terminalGet(self: *State, comptime T: type, key: c.GhosttyTerminalData) Error!T {
        var result: T = undefined;
        try check(c.ghostty_terminal_get(self.terminal, key, &result));
        return result;
    }

    fn cellGet(self: *State, comptime T: type, key: c.GhosttyRenderStateRowCellsData) Error!T {
        var result: T = undefined;
        try check(c.ghostty_render_state_row_cells_get(self.row_cells, key, &result));
        return result;
    }

    fn cellColor(self: *State, key: c.GhosttyRenderStateRowCellsData) Error!?c.GhosttyColorRgb {
        var result: c.GhosttyColorRgb = undefined;
        const status = c.ghostty_render_state_row_cells_get(self.row_cells, key, &result);
        // Only invoked after next() and a successful RAW read selected a valid cell.
        if (status == c.GHOSTTY_INVALID_VALUE) return null;
        try check(status);
        return result;
    }

    fn capture(self: *State) Error!Snapshot {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const allocator = arena.allocator();
        const columns = try self.renderGet(u16, c.GHOSTTY_RENDER_STATE_DATA_COLS);
        const rows = try self.renderGet(u16, c.GHOSTTY_RENDER_STATE_DATA_ROWS);
        _ = try dimensions(columns, rows);
        const cells = try allocator.alloc(Cell, @as(usize, columns) * rows);
        const row_data = try allocator.alloc(Row, rows);
        var colors = std.mem.zeroes(c.GhosttyRenderStateColors);
        colors.size = @sizeOf(c.GhosttyRenderStateColors);
        try check(c.ghostty_render_state_colors_get(self.render, &colors));
        var cursor = Cursor{
            .visible = try self.renderGet(bool, c.GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE),
            .blinking = try self.renderGet(bool, c.GHOSTTY_RENDER_STATE_DATA_CURSOR_BLINKING),
            .password = try self.renderGet(bool, c.GHOSTTY_RENDER_STATE_DATA_CURSOR_PASSWORD_INPUT),
            .style = try self.renderGet(c.GhosttyRenderStateCursorVisualStyle, c.GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE),
            .in_viewport = try self.renderGet(bool, c.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE),
            .pending_wrap = try self.terminalGet(bool, c.GHOSTTY_TERMINAL_DATA_CURSOR_PENDING_WRAP),
        };
        if (cursor.in_viewport) {
            cursor.x = try self.renderGet(u16, c.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X);
            cursor.y = try self.renderGet(u16, c.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y);
            cursor.wide_tail = try self.renderGet(bool, c.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_WIDE_TAIL);
            if (cursor.x >= columns or cursor.y >= rows) return error.InvalidSnapshot;
        }
        try check(c.ghostty_render_state_get(self.render, c.GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, @ptrCast(&self.row_iterator)));
        for (row_data, 0..) |*row, y| {
            if (!c.ghostty_render_state_row_iterator_next(self.row_iterator)) return error.InvalidSnapshot;
            try check(c.ghostty_render_state_row_get(self.row_iterator, c.GHOSTTY_RENDER_STATE_ROW_DATA_RAW, &row.raw));
            try check(c.ghostty_row_get(row.raw, c.GHOSTTY_ROW_DATA_WRAP, &row.wrap));
            try check(c.ghostty_row_get(row.raw, c.GHOSTTY_ROW_DATA_WRAP_CONTINUATION, &row.continuation));
            try check(c.ghostty_render_state_row_get(self.row_iterator, c.GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, @ptrCast(&self.row_cells)));
            for (cells[y * columns ..][0..columns]) |*cell| {
                if (!c.ghostty_render_state_row_cells_next(self.row_cells)) return error.InvalidSnapshot;
                cell.raw = try self.cellGet(c.GhosttyCell, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW);
                const length = try self.cellGet(u32, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN);
                const codepoints = try allocator.alloc(u32, length);
                if (length != 0) try check(c.ghostty_render_state_row_cells_get(self.row_cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, codepoints.ptr));
                cell.codepoints = codepoints;
                cell.style = std.mem.zeroes(c.GhosttyStyle);
                cell.style.size = @sizeOf(c.GhosttyStyle);
                try check(c.ghostty_render_state_row_cells_get(self.row_cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &cell.style));
                try check(c.ghostty_cell_get(cell.raw, c.GHOSTTY_CELL_DATA_WIDE, &cell.wide));
                try check(c.ghostty_cell_get(cell.raw, c.GHOSTTY_CELL_DATA_CONTENT_TAG, &cell.content));
                try check(c.ghostty_cell_get(cell.raw, c.GHOSTTY_CELL_DATA_SEMANTIC_CONTENT, &cell.semantic));
                try check(c.ghostty_cell_get(cell.raw, c.GHOSTTY_CELL_DATA_HAS_HYPERLINK, &cell.hyperlink));
                try check(c.ghostty_cell_get(cell.raw, c.GHOSTTY_CELL_DATA_PROTECTED, &cell.protected));
                cell.foreground = try self.cellColor(c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR);
                cell.background = try self.cellColor(c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR);
            }
            if (c.ghostty_render_state_row_cells_next(self.row_cells)) return error.InvalidSnapshot;
        }
        if (c.ghostty_render_state_row_iterator_next(self.row_iterator)) return error.InvalidSnapshot;
        var text: std.ArrayList(u8) = .empty;
        const offsets = try allocator.alloc(usize, (@as(usize, columns) + 1) * rows);
        var utf16_length: usize = 0;
        for (0..rows) |y| {
            if (y != 0) {
                try text.append(allocator, '\n');
                utf16_length += 1;
            }
            const row_offsets = offsets[y * (@as(usize, columns) + 1) ..][0 .. @as(usize, columns) + 1];
            for (cells[y * columns ..][0..columns], 0..) |cell, x| {
                row_offsets[x] = utf16_length;
                if (cell.wide == c.GHOSTTY_CELL_WIDE_SPACER_TAIL) {
                    if (x == 0) return error.InvalidSnapshot;
                    row_offsets[x] = row_offsets[x - 1];
                    continue;
                }
                if (cell.wide == c.GHOSTTY_CELL_WIDE_SPACER_HEAD) continue;
                if (cell.codepoints.len == 0) {
                    try text.append(allocator, ' ');
                    utf16_length += 1;
                } else for (cell.codepoints) |cp| {
                    if (cp > 0x10ffff or (cp >= 0xd800 and cp <= 0xdfff)) return error.InvalidSnapshot;
                    var encoded: [4]u8 = undefined;
                    const length = std.unicode.utf8Encode(@intCast(cp), &encoded) catch return error.InvalidSnapshot;
                    try text.appendSlice(allocator, encoded[0..length]);
                    utf16_length += if (cp > 0xffff) @as(usize, 2) else 1;
                }
            }
            row_offsets[columns] = utf16_length;
        }
        const utf16 = std.unicode.utf8ToUtf16LeAlloc(allocator, text.items) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidUtf8 => error.InvalidSnapshot,
        };
        if (utf16.len != utf16_length) return error.InvalidSnapshot;
        const title = try self.terminalGet(c.GhosttyString, c.GHOSTTY_TERMINAL_DATA_TITLE);
        const pwd = try self.terminalGet(c.GhosttyString, c.GHOSTTY_TERMINAL_DATA_PWD);
        const owned_title = try allocator.dupe(u8, title.ptr[0..title.len]);
        const owned_pwd = try allocator.dupe(u8, pwd.ptr[0..pwd.len]);
        return .{
            .arena = arena,
            .columns = columns,
            .rows = rows,
            .cells = cells,
            .row_data = row_data,
            .colors = colors,
            .cursor = cursor,
            .active_screen = try self.terminalGet(c.GhosttyTerminalScreen, c.GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN),
            .scrollbar = try self.terminalGet(c.GhosttyTerminalScrollbar, c.GHOSTTY_TERMINAL_DATA_SCROLLBAR),
            .title = owned_title,
            .pwd = owned_pwd,
            .text = text.items,
            .utf16 = utf16,
            .offsets = offsets,
            .caret = if (cursor.in_viewport)
                offsets[@as(usize, cursor.y) * (@as(usize, columns) + 1) + if (cursor.pending_wrap) @as(usize, columns) else cursor.x]
            else
                null,
        };
    }

    fn writePty(_: c.GhosttyTerminal, context: ?*anyopaque, bytes: [*c]const u8, length: usize) callconv(.c) void {
        const self: *State = @ptrCast(@alignCast(context.?));
        if (self.response_overflow or self.response_delivery_failed) return;
        if (length > self.response_buffer.len - self.response_length) {
            self.response_overflow = true;
            return;
        }
        @memcpy(self.response_buffer[self.response_length..][0..length], bytes[0..length]);
        self.response_length += length;
    }

    const allocator_vtable: c.GhosttyAllocatorVtable = .{
        .alloc = alloc,
        .resize = resizeAllocation,
        .remap = remap,
        .free = free,
    };

    // f5abc059 src/lib/allocator.zig passes log2(alignment), matching
    // std.mem.Alignment, despite allocator.h describing a byte alignment.
    fn alloc(context: ?*anyopaque, length: usize, alignment: u8, ra: usize) callconv(.c) ?*anyopaque {
        const self: *State = @ptrCast(@alignCast(context.?));
        const memory = self.allocator.rawAlloc(length, @enumFromInt(alignment), ra) orelse {
            self.allocation_failed = true;
            return null;
        };
        return memory;
    }

    fn resizeAllocation(context: ?*anyopaque, memory: ?*anyopaque, length: usize, alignment: u8, new_length: usize, ra: usize) callconv(.c) bool {
        const self: *State = @ptrCast(@alignCast(context.?));
        const ptr: [*]u8 = @ptrCast(memory.?);
        return self.allocator.rawResize(ptr[0..length], @enumFromInt(alignment), new_length, ra);
    }

    fn remap(context: ?*anyopaque, memory: ?*anyopaque, length: usize, alignment: u8, new_length: usize, ra: usize) callconv(.c) ?*anyopaque {
        const self: *State = @ptrCast(@alignCast(context.?));
        const ptr: [*]u8 = @ptrCast(memory.?);
        return self.allocator.rawRemap(ptr[0..length], @enumFromInt(alignment), new_length, ra);
    }

    fn free(context: ?*anyopaque, memory: ?*anyopaque, length: usize, alignment: u8, ra: usize) callconv(.c) void {
        const self: *State = @ptrCast(@alignCast(context.?));
        const ptr: [*]u8 = @ptrCast(memory.?);
        self.allocator.rawFree(ptr[0..length], @enumFromInt(alignment), ra);
    }
};

fn dimensions(columns: usize, rows: usize) Error![2]u16 {
    if (columns == 0 or rows == 0 or columns > std.math.maxInt(u16) or rows > std.math.maxInt(u16))
        return error.InvalidSize;
    return .{ @intCast(columns), @intCast(rows) };
}

pub const PasteError = error{ OutOfMemory, TerminalPasteRequiresConfirmation, TerminalPasteFailed, TerminalPasteTooLarge };

/// The most clipboard text one paste carries, in UTF-8 bytes. It is a decimal million, a little
/// under the shell's 1 MiB terminal input queue, so a pasted payload with its bracketed-paste
/// markers still fits; larger text is refused before anything is allocated for it.
pub const max_paste_bytes: usize = 1_000_000;

/// Prepares clipboard text for the pty the way Ghostty does for a paste: line endings
/// are normalised, the control bytes xterm blanks (NUL, BS, ENQ, EOT, ESC, DEL and the tty's
/// interrupt, quit, kill, suspend, start, stop, word-erase, literal-next, reprint and discard
/// characters, so pasted text cannot close the bracket itself) become spaces, and the text is
/// wrapped in bracketed-paste markers only when the running program enabled them. Other
/// control bytes, such as BEL, pass through. Multi-line text for a program that did not enable
/// them would run each line as typed, so it needs `allow_unbracketed_multiline`. Text over
/// `max_paste_bytes` is refused before it is copied.
pub fn encodePaste(
    allocator: std.mem.Allocator,
    text: []const u8,
    bracketed: bool,
    allow_unbracketed_multiline: bool,
) PasteError![]u8 {
    if (text.len > max_paste_bytes) return error.TerminalPasteTooLarge;
    var normalized = try allocator.alloc(u8, text.len);
    defer allocator.free(normalized);
    var length: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const byte = text[index];
        if (byte == '\r') {
            index += if (index + 1 < text.len and text[index + 1] == '\n') 2 else 1;
            normalized[length] = '\n';
            length += 1;
            continue;
        }
        if (byte < 0x80) {
            normalized[length] = byte;
            length += 1;
            index += 1;
            continue;
        }
        // C1 controls (U+0080 to U+009F) include the 8-bit CSI, OSC and DCS introducers that some
        // terminals honour even in UTF-8, so a pasted one is blanked, as a lone byte in that range
        // is. Other multi-byte characters are copied whole.
        const sequence = std.unicode.utf8ByteSequenceLength(byte) catch 1;
        const whole = sequence > 1 and index + sequence <= text.len;
        const codepoint: ?u21 = if (whole) std.unicode.utf8Decode(text[index .. index + sequence]) catch null else null;
        if (codepoint) |value| {
            if (value >= 0x80 and value <= 0x9f) {
                normalized[length] = ' ';
                length += 1;
            } else {
                @memcpy(normalized[length .. length + sequence], text[index .. index + sequence]);
                length += sequence;
            }
            index += sequence;
        } else {
            normalized[length] = if (byte >= 0x80 and byte <= 0x9f) ' ' else byte;
            length += 1;
            index += 1;
        }
    }
    const data = normalized[0..length];
    if (!bracketed and !allow_unbracketed_multiline and !c.ghostty_paste_is_safe(data.ptr, data.len))
        return error.TerminalPasteRequiresConfirmation;

    var required: usize = 0;
    const probe = c.ghostty_paste_encode(data.ptr, data.len, bracketed, null, 0, &required);
    if (probe != c.GHOSTTY_OUT_OF_SPACE and probe != c.GHOSTTY_SUCCESS) return error.TerminalPasteFailed;
    const output = try allocator.alloc(u8, required);
    errdefer allocator.free(output);
    var written: usize = 0;
    if (c.ghostty_paste_encode(data.ptr, data.len, bracketed, output.ptr, output.len, &written) != c.GHOSTTY_SUCCESS)
        return error.TerminalPasteFailed;
    return allocator.realloc(output, written) catch output[0..written];
}

test "paste encoding follows the program's bracketed-paste mode" {
    const allocator = std.testing.allocator;
    const single = try encodePaste(allocator, "echo hi", false, false);
    defer allocator.free(single);
    try std.testing.expectEqualStrings("echo hi", single);

    const bracketed = try encodePaste(allocator, "echo hi", true, false);
    defer allocator.free(bracketed);
    try std.testing.expectEqualStrings("\x1b[200~echo hi\x1b[201~", bracketed);

    const multiline = try encodePaste(allocator, "one\r\ntwo\rthree\nfour", true, false);
    defer allocator.free(multiline);
    try std.testing.expectEqualStrings("\x1b[200~one\ntwo\nthree\nfour\x1b[201~", multiline);
}

test "multi-line paste to a program without bracketed paste needs confirmation and then sends carriage returns" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.TerminalPasteRequiresConfirmation, encodePaste(allocator, "a\r\nb", false, false));
    const confirmed = try encodePaste(allocator, "a\r\nb\r\n", false, true);
    defer allocator.free(confirmed);
    try std.testing.expectEqualStrings("a\rb\r", confirmed);
}

test "paste encoding keeps Unicode and blanks escapes that could close the bracket" {
    const allocator = std.testing.allocator;
    const unicode = try encodePaste(allocator, "paste-é-漢字-😀", false, false);
    defer allocator.free(unicode);
    try std.testing.expectEqualStrings("paste-é-漢字-😀", unicode);

    const hostile = try encodePaste(allocator, "x\x1b[201~rm -rf /\n", true, false);
    defer allocator.free(hostile);
    try std.testing.expect(std.mem.startsWith(u8, hostile, "\x1b[200~"));
    try std.testing.expect(std.mem.endsWith(u8, hostile, "\x1b[201~"));
    const inner = hostile["\x1b[200~".len .. hostile.len - "\x1b[201~".len];
    try std.testing.expect(std.mem.indexOfScalar(u8, inner, 0x1b) == null);
}

test "paste encoding blanks C1 control characters, which some terminals read as escape introducers" {
    const allocator = std.testing.allocator;
    // U+009B is the 8-bit CSI: "\xc2\x9b" as UTF-8, or a lone 0x9b byte. It is blanked with the
    // rest of the C1 range (0x80 to 0x9f) whether or not the program asked for brackets.
    const cases = [_]struct { text: []const u8, bracketed: bool, expected: []const u8 }{
        .{ .text = "x\xc2\x9b201~y", .bracketed = false, .expected = "x 201~y" },
        .{ .text = "x\xc2\x9b201~y", .bracketed = true, .expected = "\x1b[200~x 201~y\x1b[201~" },
        .{ .text = "x\x9b201~y", .bracketed = false, .expected = "x 201~y" },
        .{ .text = "x\x9b201~y", .bracketed = true, .expected = "\x1b[200~x 201~y\x1b[201~" },
        .{ .text = "a\xc2\x90b\xc2\x9dc\xc2\x9fd", .bracketed = false, .expected = "a b c d" },
        // Characters whose UTF-8 bytes merely contain bytes in that range are untouched.
        .{ .text = "\xe2\x82\xac\xc3\xa9\xf0\x9f\x98\x80", .bracketed = false, .expected = "\xe2\x82\xac\xc3\xa9\xf0\x9f\x98\x80" },
        .{ .text = "\xc2\xa0\xc2\x80", .bracketed = false, .expected = "\xc2\xa0 " },
    };
    for (cases) |case| {
        const encoded = try encodePaste(allocator, case.text, case.bracketed, true);
        defer allocator.free(encoded);
        if (!std.mem.eql(u8, case.expected, encoded)) std.debug.print("C1 case {any}: got {any}\n", .{ case.text, encoded });
        try std.testing.expectEqualSlices(u8, case.expected, encoded);
    }
}

test "VT reports the program's bracketed-paste request" {
    const state = try State.create(std.testing.allocator, 20, 3);
    defer state.destroy();
    try std.testing.expect(!state.bracketedPasteEnabled());
    try state.feed("\x1b[?2004h");
    try std.testing.expect(state.bracketedPasteEnabled());
    try state.feed("\x1b[?2004l");
    try std.testing.expect(!state.bracketedPasteEnabled());
}

const test_mouse_geometry = MouseGeometry{ .columns = 200, .rows = 24, .cell_width = 8, .cell_height = 16 };

fn expectMouse(state: *State, event: MouseEvent, expected: []const u8) !void {
    var buffer: [max_mouse_sequence_bytes]u8 = undefined;
    const bytes = try state.encodeMouse(&buffer, event, test_mouse_geometry);
    try std.testing.expectEqualSlices(u8, expected, bytes);
}

/// The pixel at the middle of a cell.
fn cellCenter(column: i32, row: i32) [2]i32 {
    return .{ column * 8 + 4, row * 16 + 8 };
}

test "VT reports whether the program asked for mouse tracking" {
    const state = try State.create(std.testing.allocator, 20, 3);
    defer state.destroy();
    try std.testing.expect(!state.mouseTrackingEnabled());
    for ([_][]const u8{ "9", "1000", "1002", "1003" }) |mode| {
        var on: [16]u8 = undefined;
        var off: [16]u8 = undefined;
        try state.feed(try std.fmt.bufPrint(&on, "\x1b[?{s}h", .{mode}));
        try std.testing.expect(state.mouseTrackingEnabled());
        try state.feed(try std.fmt.bufPrint(&off, "\x1b[?{s}l", .{mode}));
        try std.testing.expect(!state.mouseTrackingEnabled());
    }
    // An encoding request alone is not tracking.
    try state.feed("\x1b[?1006h");
    try std.testing.expect(!state.mouseTrackingEnabled());
}

test "VT counts every time the program switched mouse tracking off, even when it is switched back on at once" {
    const state = try State.create(std.testing.allocator, 20, 3);
    defer state.destroy();
    try state.feed("\x1b[?1002h\x1b[?1006h");
    // Plain text, other private modes and turning modes on or off beside tracking change nothing.
    try state.feed("hello l h \x1b[?25l\x1b[?25h\x1b[?1006l\x1b[?1002h");
    try std.testing.expectEqual(@as(u32, 0), state.mouse_tracking_resets);

    // Off and on within one buffer: the state afterwards is the same, the count is not.
    try state.feed("\x1b[?1002l\x1b[?1002h");
    try std.testing.expect(state.mouseTrackingEnabled());
    try std.testing.expectEqual(@as(u32, 1), state.mouse_tracking_resets);

    // The sequence split across two buffers, with the second also turning it back on.
    try state.feed("text\x1b[?10");
    try state.feed("02l\x1b[?1002h");
    try std.testing.expectEqual(@as(u32, 2), state.mouse_tracking_resets);

    // Switching to another tracking mode passes through off, as does a full reset.
    try state.feed("\x1b[?1002l\x1b[?1000h");
    try std.testing.expectEqual(@as(u32, 3), state.mouse_tracking_resets);
    try state.feed("\x1bc\x1b[?1000h");
    try std.testing.expectEqual(@as(u32, 4), state.mouse_tracking_resets);

    // Off while already off is not a transition.
    try state.feed("\x1b[?1000l");
    try std.testing.expectEqual(@as(u32, 5), state.mouse_tracking_resets);
    try state.feed("\x1b[?1000l");
    try std.testing.expectEqual(@as(u32, 5), state.mouse_tracking_resets);
}

test "mouse events are encoded in the tracking mode and format the program chose" {
    const state = try State.create(std.testing.allocator, 200, 24);
    defer state.destroy();
    const at = cellCenter(3, 2);
    const press = MouseEvent{ .action = .press, .button = .left, .x = at[0], .y = at[1], .any_button_pressed = true };
    const release = MouseEvent{ .action = .release, .button = .left, .x = at[0], .y = at[1] };

    // No tracking: nothing to report.
    try expectMouse(state, press, "");

    // Normal tracking, X10 format: ESC [ M, button + 32, column + 33, row + 33 (one-based).
    try state.feed("\x1b[?1000h");
    try expectMouse(state, press, "\x1b[M $#");
    try expectMouse(state, release, "\x1b[M#$#");
    // SGR format.
    try state.feed("\x1b[?1006h");
    try expectMouse(state, press, "\x1b[<0;4;3M");
    try expectMouse(state, release, "\x1b[<0;4;3m");
    try expectMouse(state, .{ .action = .press, .button = .right, .x = at[0], .y = at[1], .any_button_pressed = true }, "\x1b[<2;4;3M");
    try expectMouse(state, .{ .action = .press, .button = .middle, .x = at[0], .y = at[1], .any_button_pressed = true }, "\x1b[<1;4;3M");
    try expectMouse(state, .{ .action = .press, .button = .left, .ctrl = true, .x = at[0], .y = at[1], .any_button_pressed = true }, "\x1b[<16;4;3M");
    try expectMouse(state, .{ .action = .press, .button = .wheel_up, .x = at[0], .y = at[1] }, "\x1b[<64;4;3M");
    try expectMouse(state, .{ .action = .press, .button = .wheel_down, .x = at[0], .y = at[1] }, "\x1b[<65;4;3M");
    // Normal tracking has no motion.
    const next = cellCenter(4, 2);
    try expectMouse(state, .{ .action = .motion, .button = .left, .x = next[0], .y = next[1], .any_button_pressed = true }, "");

    // Button tracking reports a drag once per cell; any-event tracking also reports a hover.
    try state.feed("\x1b[?1002h");
    try expectMouse(state, .{ .action = .motion, .button = .left, .x = next[0], .y = next[1], .any_button_pressed = true }, "\x1b[<32;5;3M");
    try expectMouse(state, .{ .action = .motion, .button = .left, .x = next[0] + 1, .y = next[1], .any_button_pressed = true }, "");
    try expectMouse(state, .{ .action = .motion, .x = next[0], .y = next[1] + 16 }, "");
    try state.feed("\x1b[?1003h");
    try expectMouse(state, .{ .action = .motion, .x = next[0], .y = next[1] + 32 }, "\x1b[<35;5;5M");
    state.resetMouse();
    try expectMouse(state, .{ .action = .motion, .x = next[0], .y = next[1] + 32 }, "\x1b[<35;5;5M");
    // Disabling a mode turns tracking off whatever was enabled before, so the program asks again.
    try state.feed("\x1b[?1003l\x1b[?1002l\x1b[?1000h");

    // URXVT, SGR-pixels, and UTF-8 formats; the legacy X10 mode (9) reports presses only.
    try state.feed("\x1b[?1006l\x1b[?1015h");
    try expectMouse(state, press, "\x1b[32;4;3M");
    try state.feed("\x1b[?1015l\x1b[?1016h");
    try expectMouse(state, press, "\x1b[<0;28;40M");
    try state.feed("\x1b[?1016l\x1b[?1005h");
    const far = cellCenter(100, 2);
    try expectMouse(state, .{ .action = .press, .button = .left, .x = far[0], .y = far[1], .any_button_pressed = true }, "\x1b[M \xc2\x85#");
    try state.feed("\x1b[?1005l\x1b[?1000l\x1b[?9h");
    try expectMouse(state, press, "\x1b[M $#");
    try expectMouse(state, release, "");
}

test "mouse positions outside the surface clamp to its edge cells and an empty geometry is refused" {
    const state = try State.create(std.testing.allocator, 200, 24);
    defer state.destroy();
    try state.feed("\x1b[?1002h\x1b[?1006h");
    try expectMouse(state, .{ .action = .press, .button = .left, .x = -50, .y = -50, .any_button_pressed = true }, "\x1b[<0;1;1M");
    try expectMouse(state, .{ .action = .release, .button = .left, .x = 99999, .y = 99999 }, "\x1b[<0;200;24m");
    var buffer: [max_mouse_sequence_bytes]u8 = undefined;
    try std.testing.expectError(error.InvalidSize, state.encodeMouse(&buffer, .{ .action = .press, .x = 0, .y = 0 }, .{
        .columns = 0,
        .rows = 24,
        .cell_width = 8,
        .cell_height = 16,
    }));
}

test "VT parser is production default with an explicit legacy opt-out" {
    try std.testing.expect(try parseFlag(null));
    try std.testing.expect(!try parseFlag("0"));
    try std.testing.expect(try parseFlag("1"));
    for ([_][]const u8{ "", "true", "false", " 1", "2" }) |value|
        try std.testing.expectError(error.InvalidTerminalVtFlag, parseFlag(value));
}

test "VT real parser consumes split UTF8 and multiparameter CSI SGR" {
    const state = try State.create(std.testing.allocator, 12, 3);
    defer state.destroy();
    try state.feed("\xc3");
    try state.feed("\xa9\x1b[2;3H\x1b[38;2;12;34;56mZ");
    const snapshot = &state.snapshot.?;
    try std.testing.expectEqualSlices(u32, &.{0xe9}, snapshot.cells[0].codepoints);
    try std.testing.expectEqualSlices(u32, &.{'Z'}, snapshot.cells[14].codepoints);
    try std.testing.expectEqual(@as(u32, 0x0c2238), rgb(snapshot.cells[14].foreground.?));
    try std.testing.expectEqual(@as(u16, 3), snapshot.cursor.x);
    try std.testing.expectEqual(@as(u16, 1), snapshot.cursor.y);
    var projected: [36]HostCell = undefined;
    try project(snapshot, &projected);
    try std.testing.expectEqual(@as(u32, 'Z'), projected[14].codepoint);
}

fn expectSameSnapshot(expected: *const Snapshot, actual: *const Snapshot) !void {
    try std.testing.expectEqualStrings(expected.text, actual.text);
    try std.testing.expectEqualSlices(u16, expected.utf16, actual.utf16);
    try std.testing.expectEqualSlices(usize, expected.offsets, actual.offsets);
    try std.testing.expectEqualDeep(expected.cursor, actual.cursor);
    try std.testing.expectEqual(expected.caret, actual.caret);
    try std.testing.expectEqual(expected.active_screen, actual.active_screen);
    for (expected.cells, actual.cells) |a, b| {
        try std.testing.expectEqualSlices(u32, a.codepoints, b.codepoints);
        try std.testing.expectEqual(a.wide, b.wide);
        try std.testing.expectEqualDeep(a.foreground, b.foreground);
        try std.testing.expectEqualDeep(a.background, b.background);
        try std.testing.expectEqual(a.style.bold, b.style.bold);
        try std.testing.expectEqual(a.style.underline, b.style.underline);
    }
}

test "VT all chunk boundaries and bytewise stream retain identical state" {
    const input = "A\xc3\xa9\xe7\x95\x8ce\xcc\x81\xf0\x9f\x98\x80\xcc\x81" ++
        "\x1b[2;3H\x1b[38;2;12;34;56mZ\x1b[48;5;21m \x1b[0m" ++
        "\x1b]2;owned-title\x1b\\\x1b[?25l\x1b[5 q\x1b[6n";
    const whole = try State.create(std.testing.allocator, 16, 3);
    defer whole.destroy();
    try whole.feed(input);
    for (0..input.len + 1) |boundary| {
        const split = try State.create(std.testing.allocator, 16, 3);
        defer split.destroy();
        try split.feed(input[0..boundary]);
        try split.feed(input[boundary..]);
        try expectSameSnapshot(&whole.snapshot.?, &split.snapshot.?);
        try std.testing.expectEqualStrings(whole.responses(), split.responses());
        try std.testing.expectEqualStrings("owned-title", split.snapshot.?.title);
    }
    const bytewise = try State.create(std.testing.allocator, 16, 3);
    defer bytewise.destroy();
    for (input) |byte| try bytewise.feed(&.{byte});
    try expectSameSnapshot(&whole.snapshot.?, &bytewise.snapshot.?);
    try std.testing.expectEqualStrings(whole.responses(), bytewise.responses());
}

test "VT preserves complete clusters wide occupancy and exact UTF16 caret" {
    const state = try State.create(std.testing.allocator, 8, 2);
    defer state.destroy();
    try state.feed("A\xe7\x95\x8ce\xcc\x81\xf0\x9f\x98\x80\xcc\x81");
    const s = &state.snapshot.?;
    try std.testing.expectEqualSlices(u32, &.{0x754c}, s.cells[1].codepoints);
    try std.testing.expectEqual(c.GHOSTTY_CELL_WIDE_WIDE, s.cells[1].wide);
    try std.testing.expectEqual(c.GHOSTTY_CELL_WIDE_SPACER_TAIL, s.cells[2].wide);
    try std.testing.expectEqualSlices(u32, &.{ 'e', 0x301 }, s.cells[3].codepoints);
    try std.testing.expectEqualSlices(u32, &.{ 0x1f600, 0x301 }, s.cells[4].codepoints);
    try std.testing.expectEqualStrings("A\xe7\x95\x8ce\xcc\x81\xf0\x9f\x98\x80\xcc\x81  \n        ", s.text);
    try std.testing.expectEqualSlices(u16, &.{ 'A', 0x754c, 'e', 0x301, 0xd83d, 0xde00, 0x301, ' ', ' ', '\n', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ' }, s.utf16);
    try std.testing.expectEqual(@as(?usize, 7), s.caret);
    try std.testing.expectEqual(s.offsets[1], s.offsets[2]);
    try std.testing.expectEqual(s.offsets[4], s.offsets[5]);
    var host: [16]HostCell = @splat(.{ .codepoint = 'X', .fg = 1, .bg = 2, .flags = 3 });
    try std.testing.expectError(error.UnsupportedHostCell, project(s, &host));
    for (host) |cell| try std.testing.expectEqual(@as(u32, 'X'), cell.codepoint);
    try std.testing.expect(state.snapshot_current);
}

test "VT colors flatten inverse invisible but reject decorations without changing projection" {
    const state = try State.create(std.testing.allocator, 8, 2);
    defer state.destroy();
    try state.feed("\x1b[38;2;0;0;0;48;2;11;22;33mA\x1b[7mB\x1b[27;8mC\x1b[0mD");
    var host: [16]HostCell = undefined;
    try project(&state.snapshot.?, &host);
    try std.testing.expectEqual(@as(u32, 0), host[0].fg);
    try std.testing.expectEqual(@as(u32, 0x0b1621), host[0].bg);
    try std.testing.expectEqual(@as(u32, 3), host[0].flags);
    try std.testing.expectEqual(host[0].bg, host[1].fg);
    try std.testing.expectEqual(host[0].fg, host[1].bg);
    try std.testing.expectEqual(host[2].fg, host[2].bg);
    try std.testing.expect(state.snapshot.?.cells[3].foreground == null);
    try std.testing.expectEqual(rgb(state.snapshot.?.colors.foreground), host[3].fg);
    for ([_][]const u8{ "\x1b[1m", "\x1b[2m", "\x1b[3m", "\x1b[4m", "\x1b[5m", "\x1b[9m", "\x1b[53m" }) |sgr| {
        try state.feed("\x1b[0m\x1b[2J\x1b[H");
        try state.feed(sgr);
        try state.feed("X");
        try std.testing.expectError(error.UnsupportedHostCell, project(&state.snapshot.?, &host));
    }
    try state.feed("\x1b[0m\x1b[2J\x1b[H");
    try project(&state.snapshot.?, &host);
}

test "VT cursor pending wrap row wrap alternate restore viewport and memory resize" {
    const state = try State.create(std.testing.allocator, 4, 2);
    defer state.destroy();
    try state.feed("abcd");
    try std.testing.expect(state.snapshot.?.cursor.pending_wrap);
    try std.testing.expectEqual(@as(?usize, 4), state.snapshot.?.caret);
    try state.feed("ef");
    try std.testing.expect(state.snapshot.?.row_data[0].wrap);
    try state.resize(8, 2);
    try std.testing.expect(std.mem.startsWith(u8, state.snapshot.?.text, "abcdef"));
    try state.feed("\x1b[?1049hALT\x1b[?25l\x1b[5 q");
    try std.testing.expectEqual(c.GHOSTTY_TERMINAL_SCREEN_ALTERNATE, state.snapshot.?.active_screen);
    try std.testing.expect(!state.snapshot.?.cursor.visible);
    try std.testing.expect(state.snapshot.?.cursor.blinking);
    try std.testing.expectEqual(c.GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR, state.snapshot.?.cursor.style);
    try state.feed("\x1b[?1049l");
    try std.testing.expectEqual(c.GHOSTTY_TERMINAL_SCREEN_PRIMARY, state.snapshot.?.active_screen);
    try std.testing.expect(std.mem.startsWith(u8, state.snapshot.?.text, "abcdef"));
    try state.feed("\r\none\r\ntwo\r\nthree");
    try std.testing.expect(state.snapshot.?.scrollbar.total > state.snapshot.?.rows);
    const bottom = state.snapshot.?.scrollbar.offset;
    try state.scrollViewport(-2);
    try std.testing.expect(state.snapshot.?.scrollbar.offset < bottom);
    try std.testing.expect(!state.snapshot.?.cursor.in_viewport);
    try std.testing.expectEqual(@as(?usize, null), state.snapshot.?.caret);
    try state.scrollViewport(100);
    try std.testing.expect(state.snapshot.?.cursor.in_viewport);
    try std.testing.expectError(error.InvalidSize, state.resize(0, 2));
    try std.testing.expectError(error.InvalidSize, state.resize(65536, 2));
    try std.testing.expect(state.snapshot_current);
}

test "VT owned snapshots survive updates and preserve semantic hyperlink protection title and PWD" {
    const state = try State.create(std.testing.allocator, 8, 2);
    defer state.destroy();
    const pwd = c.GhosttyString{ .ptr = "/owned", .len = 6 };
    try check(c.ghostty_terminal_set(state.terminal, c.GHOSTTY_TERMINAL_OPT_PWD, &pwd));
    try state.feed("\x1b]2;title\x07\x1b]133;A\x07\x1b]8;;https://example.invalid\x1b\\\x1b[1\"qA");
    var old = try state.capture();
    defer old.deinit();
    try std.testing.expectEqualStrings("title", old.title);
    try std.testing.expectEqualStrings("/owned", old.pwd);
    try std.testing.expect(old.cells[0].hyperlink);
    try std.testing.expect(old.cells[0].protected);
    try std.testing.expectEqual(c.GHOSTTY_CELL_SEMANTIC_PROMPT, old.cells[0].semantic);
    try state.feed("\x1b[2J\x1b[Hnew\x1b]2;changed\x07");
    try std.testing.expectEqualSlices(u32, &.{'A'}, old.cells[0].codepoints);
    try std.testing.expectEqualStrings("title", old.title);
}

test "VT responses are bounded whole messages and stable state follows pane swap" {
    var panes = [2]*State{
        try State.create(std.testing.allocator, 8, 2),
        try State.create(std.testing.allocator, 8, 2),
    };
    defer for (panes) |pane| pane.destroy();
    try panes[0].feed("A\x1b[6n");
    try panes[1].feed("BC\x1b[6n");
    const first = panes[0];
    std.mem.swap(*State, &panes[0], &panes[1]);
    try std.testing.expect(panes[1] == first);
    try std.testing.expectEqualStrings("\x1b[1;2R", panes[1].responses());
    try std.testing.expectEqualStrings("\x1b[1;3R", panes[0].responses());
    panes[1].consumeResponses();
    try panes[1].feed("\x1b[6n");
    try std.testing.expectEqualStrings("\x1b[1;2R", panes[1].responses());
    const queries = "\x1b[6n" ** 12000;
    try std.testing.expectError(error.ResponseOverflow, panes[1].feed(queries));
    try std.testing.expect(panes[1].response_length <= response_capacity);
    try std.testing.expectEqual(@as(usize, 0), panes[1].response_length % 6);
    const kept = panes[1].response_length;
    try std.testing.expectError(error.ResponseOverflow, panes[1].feed("\x1b[6n"));
    try std.testing.expectEqual(kept, panes[1].response_length);
    try std.testing.expect(panes[1].snapshot_current);
}

fn allocationScenario(allocator: std.mem.Allocator) !void {
    const state = State.create(allocator, 8, 2) catch |err| return if (err == error.RenderStateUnreliable) error.OutOfMemory else err;
    defer state.destroy();
    state.feed("A\xe7\x95\x8ce\xcc\x81\x1b[38;2;1;2;3mB") catch |err|
        return if (err == error.RenderStateUnreliable) error.OutOfMemory else err;
}

test "VT initialization and snapshots release every allocation on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationScenario, .{});
}

test "VT allocation loss is sticky but normal allocator resize refusal is not failure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const state = try State.create(failing.allocator(), 8, 2);
    defer state.destroy();
    // FailingAllocator's resize_fail_index refuses growth without a failed alloc.
    failing.resize_fail_index = failing.resize_index;
    for ([_]u8{ 0, 1, 3, 4, 6, 12 }) |alignment| {
        const memory = State.alloc(state, 64, alignment, @returnAddress()).?;
        defer State.free(state, memory, 64, alignment, @returnAddress());
        try std.testing.expectEqual(@as(usize, 0), @intFromPtr(memory) % (@as(usize, 1) << @intCast(alignment)));
        try std.testing.expect(!State.resizeAllocation(state, memory, 64, alignment, 128, @returnAddress()));
        try std.testing.expect(State.remap(state, memory, 64, alignment, 128, @returnAddress()) == null);
    }
    try std.testing.expect(!state.allocation_failed);
    failing.fail_index = failing.alloc_index;
    try std.testing.expect(State.alloc(state, 4096, 3, @returnAddress()) == null);
    try std.testing.expectError(error.RenderStateUnreliable, state.feed("not confirmed"));
    try std.testing.expect(!state.snapshot_current);
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expectError(error.RenderStateUnreliable, state.feed("no recovery"));
    try std.testing.expectError(error.RenderStateUnreliable, state.resize(10, 3));
}

test "VT OSC7 is not retained by the pinned stream API" {
    const state = try State.create(std.testing.allocator, 8, 2);
    defer state.destroy();
    try state.feed("\x1b]7;file:///owned\x07\x1b]2;OSC2 title\x07");
    try std.testing.expectEqualStrings("", state.snapshot.?.pwd);
    try std.testing.expectEqualStrings("OSC2 title", state.snapshot.?.title);
    const queried = try state.terminalGet(c.GhosttyString, c.GHOSTTY_TERMINAL_DATA_PWD);
    try std.testing.expectEqualStrings(queried.ptr[0..queried.len], state.snapshot.?.pwd);
}

test "VT wide head spacer and cursor tail retain occupancy without invented text" {
    const state = try State.create(std.testing.allocator, 4, 2);
    defer state.destroy();
    try state.feed("abc\xe7\x95\x8c");
    try std.testing.expectEqual(c.GHOSTTY_CELL_WIDE_SPACER_HEAD, state.snapshot.?.cells[3].wide);
    try std.testing.expectEqualStrings("abc\n\xe7\x95\x8c  ", state.snapshot.?.text);
    try state.feed("\x1b[2;2H");
    try std.testing.expect(state.snapshot.?.cursor.wide_tail);
    try std.testing.expectEqual(@as(?usize, 4), state.snapshot.?.caret);
}

test "VT projection validates scalar controls without partial mutation" {
    const state = try State.create(std.testing.allocator, 4, 2);
    defer state.destroy();
    try state.feed("A");
    var snapshot = try state.capture();
    defer snapshot.deinit();
    for ([_]u32{ 0, 0x1b, 0x7f, 0x80, 0x9f, 0xd800, 0x110000 }) |cp| {
        snapshot.cells[1].codepoints = &.{cp};
        var output: [8]HostCell = @splat(.{ .codepoint = 'X', .fg = 1, .bg = 2, .flags = 3 });
        try std.testing.expectError(error.UnsupportedHostCell, project(&snapshot, &output));
        for (output) |cell| try std.testing.expectEqual(@as(u32, 'X'), cell.codepoint);
    }
}

test "VT resize allocation failure preserves last owned snapshot but never reports recovery" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const state = try State.create(failing.allocator(), 8, 2);
    defer state.destroy();
    try state.feed("before");
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.RenderStateUnreliable, state.resize(512, 256));
    try std.testing.expect(!state.snapshot_current);
    try std.testing.expectEqual(@as(u16, 8), state.snapshot.?.columns);
    try std.testing.expect(std.mem.startsWith(u8, state.snapshot.?.text, "before"));
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expectError(error.RenderStateUnreliable, state.feed("after"));
}

test "VT ZWJ clustering follows mode 2027 and retains every scalar and surrogate pair" {
    const state = try State.create(std.testing.allocator, 4, 2);
    defer state.destroy();
    const cluster = "\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x92\xbb";
    for (cluster) |byte| try state.feed(&.{byte});
    try std.testing.expectEqualSlices(u32, &.{ 0x1f469, 0x200d }, state.snapshot.?.cells[0].codepoints);
    try std.testing.expectEqualSlices(u32, &.{0x1f4bb}, state.snapshot.?.cells[2].codepoints);
    try std.testing.expectEqualSlices(u16, &.{ 0xd83d, 0xdc69, 0x200d, 0xd83d, 0xdcbb }, state.snapshot.?.utf16[0..5]);
    try state.feed("\x1b[?2027h\x1b[2J\x1b[H");
    for (cluster) |byte| try state.feed(&.{byte});
    try std.testing.expectEqualSlices(u32, &.{ 0x1f469, 0x200d, 0x1f4bb }, state.snapshot.?.cells[0].codepoints);
    try std.testing.expectEqualSlices(u16, &.{ 0xd83d, 0xdc69, 0x200d, 0xd83d, 0xdcbb }, state.snapshot.?.utf16[0..5]);
    try std.testing.expectEqual(@as(?usize, 5), state.snapshot.?.caret);
}

test "VT provider allocation failure during feed is visible without successful recovery" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const state = try State.create(failing.allocator(), 8, 2);
    defer state.destroy();
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.RenderStateUnreliable, state.feed("\x1b]2;new title requiring allocation\x07"));
    try std.testing.expect(state.allocation_failed);
    try std.testing.expect(!state.snapshot_current);
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expectError(error.RenderStateUnreliable, state.feed("not replayed"));
}

test "VT allocator bridge shrinks and frees using the actual successful allocation length" {
    const state = try State.create(std.testing.allocator, 4, 2);
    defer state.destroy();
    var memory = State.alloc(state, 128, 4, @returnAddress()).?;
    var length: usize = 128;
    defer State.free(state, memory, length, 4, @returnAddress());
    if (State.resizeAllocation(state, memory, length, 4, 64, @returnAddress())) length = 64;
    if (State.remap(state, memory, length, 4, 32, @returnAddress())) |moved| {
        memory = moved;
        length = 32;
    }
    try std.testing.expect(!state.allocation_failed);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(memory) % 16);
}

test "VT copied metadata owns arena growth through the final snapshot allocation" {
    const state = try State.create(std.testing.allocator, 4, 2);
    defer state.destroy();
    const text = "metadata" ** 1024;
    const value = c.GhosttyString{ .ptr = text, .len = text.len };
    try check(c.ghostty_terminal_set(state.terminal, c.GHOSTTY_TERMINAL_OPT_TITLE, &value));
    try check(c.ghostty_terminal_set(state.terminal, c.GHOSTTY_TERMINAL_OPT_PWD, &value));
    try state.feed("");
    var snapshot = try state.capture();
    defer snapshot.deinit();
    try state.feed("\x1b]2;new title\x07");
    try std.testing.expectEqualStrings(text, snapshot.title);
    try std.testing.expectEqualStrings(text, snapshot.pwd);
}
