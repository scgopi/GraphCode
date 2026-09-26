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
    const text = value orelse return false;
    if (std.mem.eql(u8, text, "0")) return false;
    if (std.mem.eql(u8, text, "1")) return true;
    return error.InvalidTerminalVtFlag;
}

pub fn startupEnabled(allocator: std.mem.Allocator) !bool {
    const value = std.process.getEnvVarOwned(allocator, environment_name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return false,
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
        c.ghostty_terminal_vt_write(self.terminal, bytes.ptr, bytes.len);
        try self.refresh();
        if (self.response_delivery_failed) return error.ResponseDeliveryFailed;
        if (self.response_overflow) return error.ResponseOverflow;
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

test "VT flag is explicit and default off" {
    try std.testing.expect(!try parseFlag(null));
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
