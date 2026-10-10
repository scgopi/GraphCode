const std = @import("std");
const TerminalVt = @import("TerminalVt.zig");

pub const Point = TerminalVt.ScreenPoint;
pub const Screen = TerminalVt.c.GhosttyTerminalScreen;

/// An inclusive span of screen points in reading order.
pub const Range = struct {
    start: Point,
    end: Point,

    pub fn between(a: Point, b: Point) Range {
        return if (b.before(a)) .{ .start = b, .end = a } else .{ .start = a, .end = b };
    }

    pub fn merge(a: Range, b: Range) Range {
        return .{
            .start = if (b.start.before(a.start)) b.start else a.start,
            .end = if (a.end.before(b.end)) b.end else a.end,
        };
    }

    pub fn contains(self: Range, x: u16, y: u32) bool {
        const point = Point{ .x = x, .y = y };
        return !point.before(self.start) and !self.end.before(point);
    }

    pub fn eql(self: Range, other: Range) bool {
        return self.start.eql(other.start) and self.end.eql(other.end);
    }
};

pub const Mode = enum { cell, word, line };

pub const Press = struct {
    /// The provider's count: 1 for a press, 2 for the press Windows reports as a double click.
    click_count: u32,
    shift: bool,
    now_ms: u64,
    double_click_ms: u64,
};

/// Characters that end a word, as in Ghostty's default `selection-word-chars`.
const word_boundaries = " \t'\"`|:;,()[]{}<>$";

pub fn isBoundary(codepoint: u32) bool {
    if (codepoint == 0 or codepoint == 0x2502) return true;
    return codepoint < 0x80 and std.mem.indexOfScalar(u8, word_boundaries, @intCast(codepoint)) != null;
}

/// A mouse selection over the terminal's screen coordinates. The shell owns the text, so the
/// selection is tracked here and read back through the VT, not through the provider.
pub const State = struct {
    range: ?Range = null,
    pressed: bool = false,
    mode: Mode = .cell,
    anchor: Point = .{ .x = 0, .y = 0 },
    // The word or line under the press, kept whole while a word/line drag extends from it.
    anchor_unit: Range = .{ .start = .{ .x = 0, .y = 0 }, .end = .{ .x = 0, .y = 0 } },
    // Which screen (primary or alternate) the range belongs to.
    screen: Screen = 0,
    last_click_ms: u64 = 0,
    last_click_point: Point = .{ .x = 0, .y = 0 },
    last_click_count: u32 = 0,

    pub fn hasSelection(self: *const State) bool {
        return self.range != null;
    }

    /// Drops the selection and any drag in progress. True when something was visible.
    pub fn clear(self: *State) bool {
        const had = self.range != null;
        self.range = null;
        self.pressed = false;
        return had;
    }

    /// Drops the selection when the terminal now shows another screen. True when it did.
    pub fn followScreen(self: *State, screen: Screen) bool {
        if (self.range != null and self.screen != screen) return self.clear();
        return false;
    }

    fn clickCount(self: *State, point: Point, input: Press) u32 {
        var count: u32 = if (input.click_count >= 2) 2 else 1;
        if (count == 1 and self.last_click_count == 2 and
            input.now_ms -% self.last_click_ms <= input.double_click_ms and
            self.last_click_point.eql(point)) count = 3;
        self.last_click_ms = input.now_ms;
        self.last_click_point = point;
        self.last_click_count = count;
        return count;
    }

    /// A left-button press at `raw`. True when the visible selection changed.
    pub fn press(self: *State, grid: anytype, screen: Screen, raw: Point, input: Press) bool {
        const point = grid.normalize(raw);
        const count = self.clickCount(point, input);
        const previous = self.range;
        self.pressed = true;
        self.screen = screen;
        if (input.shift and count == 1 and previous != null) {
            const current = previous.?;
            // Extend whichever end the click is nearest to; the far end stays put.
            const near_start = distance(point, current.start) <= distance(point, current.end);
            self.anchor = if (near_start) current.end else current.start;
            self.mode = .cell;
            self.range = Range.between(self.anchor, point);
        } else {
            self.anchor = point;
            self.mode = switch (count) {
                1 => .cell,
                2 => .word,
                else => .line,
            };
            switch (self.mode) {
                .cell => self.range = null,
                .word => {
                    self.anchor_unit = grid.wordAt(point);
                    self.range = self.anchor_unit;
                },
                .line => {
                    self.anchor_unit = grid.lineAt(point);
                    self.range = self.anchor_unit;
                },
            }
        }
        return !sameRange(previous, self.range);
    }

    /// The pointer moved with the button held. True when the visible selection changed.
    pub fn drag(self: *State, grid: anytype, raw: Point) bool {
        if (!self.pressed) return false;
        const point = grid.normalize(raw);
        const previous = self.range;
        switch (self.mode) {
            // A press that has not left its cell selects nothing, so a click only clears.
            .cell => {
                if (self.range != null or !point.eql(self.anchor)) self.range = Range.between(self.anchor, point);
            },
            .word => self.range = Range.merge(self.anchor_unit, grid.wordAt(point)),
            .line => self.range = Range.merge(self.anchor_unit, grid.lineAt(point)),
        }
        return !sameRange(previous, self.range);
    }

    pub fn release(self: *State) void {
        self.pressed = false;
    }
};

fn sameRange(a: ?Range, b: ?Range) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.eql(b.?);
}

fn distance(a: Point, b: Point) u64 {
    const left = @as(u64, a.y) * 65536 + a.x;
    const right = @as(u64, b.y) * 65536 + b.x;
    return if (left > right) left - right else right - left;
}

/// Word and line geometry over the VT's grid, the way Ghostty selects them: a word is a run
/// of the same kind of character (word versus boundary), a line is a whole soft-wrapped line
/// without its trailing blanks, and both cross soft wraps.
pub const VtGrid = struct {
    state: *TerminalVt.State,
    columns: u16,
    rows: u32,

    pub fn init(state: *TerminalVt.State) VtGrid {
        const snapshot = state.snapshot orelse return .{ .state = state, .columns = 1, .rows = 1 };
        return .{
            .state = state,
            .columns = @max(snapshot.columns, 1),
            .rows = std.math.cast(u32, snapshot.scrollbar.total) orelse std.math.maxInt(u32),
        };
    }

    pub fn clamp(self: VtGrid, point: Point) Point {
        return .{
            .x = @min(point.x, self.columns - 1),
            .y = @min(point.y, self.rows -| 1),
        };
    }

    /// The point itself, or the lead cell when it lands on the tail of a wide character.
    pub fn normalize(self: VtGrid, raw: Point) Point {
        const point = self.clamp(raw);
        const cell = self.state.cellAt(point) orelse return point;
        if (cell.wide == TerminalVt.c.GHOSTTY_CELL_WIDE_SPACER_TAIL and point.x > 0)
            return .{ .x = point.x - 1, .y = point.y };
        return point;
    }

    /// Whether the cell holds a boundary character; null for cells that are only the
    /// continuation of a wide character and so take their neighbour's side.
    fn boundaryAt(self: VtGrid, point: Point) ?bool {
        const cell = self.state.cellAt(point) orelse return null;
        if (cell.wide == TerminalVt.c.GHOSTTY_CELL_WIDE_SPACER_TAIL or
            cell.wide == TerminalVt.c.GHOSTTY_CELL_WIDE_SPACER_HEAD) return null;
        return isBoundary(cell.codepoint);
    }

    fn previous(self: VtGrid, point: Point) ?Point {
        if (point.x > 0) return .{ .x = point.x - 1, .y = point.y };
        if (point.y == 0) return null;
        const above = Point{ .x = self.columns - 1, .y = point.y - 1 };
        const cell = self.state.cellAt(above) orelse return null;
        return if (cell.wraps) above else null;
    }

    fn next(self: VtGrid, point: Point) ?Point {
        if (point.x + 1 < self.columns) return .{ .x = point.x + 1, .y = point.y };
        if (point.y + 1 >= self.rows) return null;
        const cell = self.state.cellAt(point) orelse return null;
        return if (cell.wraps) .{ .x = 0, .y = point.y + 1 } else null;
    }

    pub fn wordAt(self: VtGrid, raw: Point) Range {
        const point = self.normalize(raw);
        const boundary = self.boundaryAt(point) orelse return .{ .start = point, .end = point };
        var start = point;
        while (self.previous(start)) |candidate| {
            if (self.boundaryAt(candidate)) |side| if (side != boundary) break;
            start = candidate;
        }
        var end = point;
        while (self.next(end)) |candidate| {
            if (self.boundaryAt(candidate)) |side| if (side != boundary) break;
            end = candidate;
        }
        return .{ .start = self.normalize(start), .end = self.normalize(end) };
    }

    pub fn lineAt(self: VtGrid, raw: Point) Range {
        const point = self.clamp(raw);
        var first = point.y;
        while (first > 0) {
            const cell = self.state.cellAt(.{ .x = 0, .y = first }) orelse break;
            if (!cell.continuation) break;
            first -= 1;
        }
        var last = point.y;
        while (last + 1 < self.rows) {
            const cell = self.state.cellAt(.{ .x = 0, .y = last }) orelse break;
            if (!cell.wraps) break;
            last += 1;
        }
        var end_x: u16 = self.columns - 1;
        while (end_x > 0) : (end_x -= 1) {
            const cell = self.state.cellAt(.{ .x = end_x, .y = last }) orelse break;
            if (cell.codepoint != 0 and cell.codepoint != ' ') break;
        }
        return .{ .start = .{ .x = 0, .y = first }, .end = self.normalize(.{ .x = end_x, .y = last }) };
    }
};

const testing = std.testing;

fn at(x: u16, y: u32) Point {
    return .{ .x = x, .y = y };
}

fn click(state: *State, grid: VtGrid, point: Point, count: u32, now: u64) bool {
    return state.press(grid, 0, point, .{ .click_count = count, .shift = false, .now_ms = now, .double_click_ms = 500 });
}

fn expectText(vt: *TerminalVt.State, range: ?Range, expected: []const u8) !void {
    const selection = range orelse return error.TestExpectedSelection;
    const value = try vt.selectionText(testing.allocator, selection.start, selection.end);
    defer testing.allocator.free(value);
    try testing.expectEqualStrings(expected, value);
}

test "selection text copies a span without padding or a trailing newline" {
    const vt = try TerminalVt.State.create(testing.allocator, 20, 4);
    defer vt.destroy();
    try vt.feed("GC-COPY-1\r\nGC-COPY-2\r\n\r\nlast");
    try expectText(vt, Range.between(at(0, 1), at(8, 1)), "GC-COPY-2");
    // Blank cells after the text, up to the end of the row, are dropped.
    try expectText(vt, Range.between(at(0, 1), at(19, 1)), "GC-COPY-2");
    try expectText(vt, Range.between(at(3, 0), at(5, 1)), "COPY-1\nGC-COP");
    try expectText(vt, Range.between(at(0, 0), at(3, 3)), "GC-COPY-1\nGC-COPY-2\n\nlast");
    // Either end may come first.
    try expectText(vt, Range.between(at(5, 1), at(3, 0)), "COPY-1\nGC-COP");
}

test "selection text joins soft-wrapped rows and keeps hard breaks" {
    const vt = try TerminalVt.State.create(testing.allocator, 10, 5);
    defer vt.destroy();
    try vt.feed("0123456789ABCDE\r\nnext");
    try expectText(vt, Range.between(at(8, 0), at(2, 1)), "89ABC");
    try expectText(vt, Range.between(at(0, 0), at(3, 2)), "0123456789ABCDE\nnext");
}

test "selection text covers scrollback and survives output that scrolls it" {
    const vt = try TerminalVt.State.create(testing.allocator, 12, 3);
    defer vt.destroy();
    try vt.feed("first\r\nsecond\r\nthird\r\nfourth\r\nfifth");
    try testing.expect(vt.viewportTop() > 0);
    const first = Range.between(at(0, 0), at(4, 0));
    try expectText(vt, first, "first");
    try vt.feed("\r\nsixth");
    try expectText(vt, first, "first");
    try expectText(vt, Range.between(at(0, 1), at(5, 2)), "second\nthird");
}

test "wide characters stay whole and their tail selects with them" {
    const vt = try TerminalVt.State.create(testing.allocator, 10, 2);
    defer vt.destroy();
    try vt.feed("a\xe7\x95\x8cb");
    const grid = VtGrid.init(vt);
    try testing.expect(grid.normalize(at(2, 0)).eql(at(1, 0)));
    try expectText(vt, Range.between(at(1, 0), at(1, 0)), "\xe7\x95\x8c");
    try expectText(vt, Range.between(at(0, 0), at(3, 0)), "a\xe7\x95\x8cb");
    try testing.expect(grid.wordAt(at(2, 0)).eql(.{ .start = at(0, 0), .end = at(3, 0) }));
}

test "points off the grid are rejected rather than clamped silently" {
    const vt = try TerminalVt.State.create(testing.allocator, 10, 2);
    defer vt.destroy();
    try testing.expectError(error.InvalidValue, vt.selectionText(testing.allocator, at(0, 0), at(0, 400)));
}

test "word selection follows boundary characters and crosses soft wraps" {
    const vt = try TerminalVt.State.create(testing.allocator, 10, 5);
    defer vt.destroy();
    try vt.feed("alpha beta-gamma (delta)\r\nx");
    const grid = VtGrid.init(vt);
    try expectText(vt, grid.wordAt(at(2, 0)), "alpha");
    // Hyphens are word characters; spaces and brackets are boundaries.
    try expectText(vt, grid.wordAt(at(7, 0)), "beta-gamma");
    try testing.expect(grid.wordAt(at(5, 0)).eql(.{ .start = at(5, 0), .end = at(5, 0) }));
    try expectText(vt, grid.wordAt(at(8, 1)), "delta");
    try expectText(vt, grid.wordAt(at(0, 3)), "x");
}

test "line selection takes the whole soft-wrapped line without trailing blanks" {
    const vt = try TerminalVt.State.create(testing.allocator, 10, 5);
    defer vt.destroy();
    try vt.feed("0123456789ABCDE\r\nshort\r\n\r\nend");
    const grid = VtGrid.init(vt);
    for ([_]u32{ 0, 1 }) |row| {
        const line = grid.lineAt(at(3, row));
        try testing.expect(line.start.eql(at(0, 0)) and line.end.eql(at(4, 1)));
        try expectText(vt, line, "0123456789ABCDE");
    }
    try expectText(vt, grid.lineAt(at(9, 2)), "short");
    try expectText(vt, grid.lineAt(at(0, 4)), "end");
}

test "press and drag select cells; a click selects nothing and clears" {
    const vt = try TerminalVt.State.create(testing.allocator, 20, 3);
    defer vt.destroy();
    try vt.feed("alpha beta\r\ngamma");
    const grid = VtGrid.init(vt);
    var state = State{};

    try testing.expect(!click(&state, grid, at(1, 0), 1, 0));
    try testing.expect(!state.hasSelection());
    try testing.expect(!state.drag(grid, at(1, 0)));
    try testing.expect(state.drag(grid, at(3, 0)));
    try testing.expect(state.range.?.eql(Range.between(at(1, 0), at(3, 0))));
    try testing.expect(!state.drag(grid, at(3, 0)));
    state.release();
    try testing.expect(!state.drag(grid, at(8, 0)));
    try testing.expect(state.range.?.eql(Range.between(at(1, 0), at(3, 0))));

    // A click clears the previous selection.
    try testing.expect(click(&state, grid, at(7, 0), 1, 1000));
    try testing.expect(!state.hasSelection());
    state.release();

    // Dragging backwards and across rows works the same.
    _ = click(&state, grid, at(3, 1), 1, 5000);
    try testing.expect(state.drag(grid, at(2, 0)));
    try expectText(vt, state.range, "pha beta\ngamm");
}

test "double click selects a word and a word drag extends by whole words" {
    const vt = try TerminalVt.State.create(testing.allocator, 30, 2);
    defer vt.destroy();
    try vt.feed("alpha beta-gamma delta");
    const grid = VtGrid.init(vt);
    var state = State{};
    _ = click(&state, grid, at(1, 0), 1, 0);
    state.release();
    try testing.expect(click(&state, grid, at(1, 0), 2, 100));
    try expectText(vt, state.range, "alpha");
    try testing.expect(state.drag(grid, at(8, 0)));
    try expectText(vt, state.range, "alpha beta-gamma");
    state.release();
}

test "a third click within the double-click time selects the line, a slow or moved one does not" {
    const vt = try TerminalVt.State.create(testing.allocator, 30, 2);
    defer vt.destroy();
    try vt.feed("alpha beta-gamma delta");
    const grid = VtGrid.init(vt);
    var state = State{};
    _ = click(&state, grid, at(1, 0), 1, 0);
    _ = click(&state, grid, at(1, 0), 2, 100);
    state.release();
    try testing.expect(click(&state, grid, at(1, 0), 1, 200));
    try expectText(vt, state.range, "alpha beta-gamma delta");
    try testing.expectEqual(Mode.line, state.mode);
    state.release();

    // Too slow, or on another cell, it is a fresh single press.
    _ = click(&state, grid, at(1, 0), 2, 1000);
    _ = click(&state, grid, at(1, 0), 1, 1000 + 501);
    try testing.expectEqual(Mode.cell, state.mode);
    try testing.expect(!state.hasSelection());
    _ = click(&state, grid, at(1, 0), 2, 3000);
    _ = click(&state, grid, at(2, 0), 1, 3100);
    try testing.expectEqual(Mode.cell, state.mode);
}

test "shift-click extends from the far end and keeps extending on drag" {
    const vt = try TerminalVt.State.create(testing.allocator, 30, 2);
    defer vt.destroy();
    try vt.feed("alpha beta-gamma delta");
    const grid = VtGrid.init(vt);
    var state = State{};
    _ = click(&state, grid, at(0, 0), 1, 0);
    _ = state.drag(grid, at(4, 0));
    state.release();
    try expectText(vt, state.range, "alpha");

    const extend = Press{ .click_count = 1, .shift = true, .now_ms = 5000, .double_click_ms = 500 };
    try testing.expect(state.press(grid, 0, at(9, 0), extend));
    try expectText(vt, state.range, "alpha beta");
    try testing.expect(state.drag(grid, at(15, 0)));
    try expectText(vt, state.range, "alpha beta-gamma");
    state.release();

    // Left of the start, the end stays fixed instead.
    _ = click(&state, grid, at(10, 0), 1, 9000);
    _ = state.drag(grid, at(15, 0));
    state.release();
    try testing.expect(state.press(grid, 0, at(6, 0), .{ .click_count = 1, .shift = true, .now_ms = 20000, .double_click_ms = 500 }));
    try expectText(vt, state.range, "beta-gamma");
    state.release();

    // Without a selection a shift-click is an ordinary press.
    _ = state.clear();
    try testing.expect(!state.press(grid, 0, at(2, 0), .{ .click_count = 1, .shift = true, .now_ms = 40000, .double_click_ms = 500 }));
    try testing.expect(!state.hasSelection());
}

test "a selection follows the screen it was made on" {
    var state = State{};
    state.range = Range.between(at(0, 0), at(3, 0));
    state.screen = 0;
    try testing.expect(!state.followScreen(0));
    try testing.expect(state.hasSelection());
    try testing.expect(state.followScreen(1));
    try testing.expect(!state.hasSelection());
    try testing.expect(!state.followScreen(1));
}

test "range containment is inclusive and linear" {
    const range = Range.between(at(5, 1), at(2, 3));
    try testing.expect(!range.contains(4, 1));
    try testing.expect(range.contains(5, 1));
    try testing.expect(range.contains(0, 2));
    try testing.expect(range.contains(19, 2));
    try testing.expect(range.contains(2, 3));
    try testing.expect(!range.contains(3, 3));
    try testing.expect(!range.contains(0, 0));
}
