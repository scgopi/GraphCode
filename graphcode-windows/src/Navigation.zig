const std = @import("std");

pub const Identity = struct {
    project_path: []const u8,
    node_id: []const u8,

    pub fn eql(a: Identity, b: Identity) bool {
        return std.mem.eql(u8, a.project_path, b.project_path) and
            std.mem.eql(u8, a.node_id, b.node_id);
    }
};

pub const Item = struct {
    identity: Identity,
    title: []const u8,
    attention: bool = false,
};

pub const Search = struct {
    pub fn matches(item: Item, query: []const u8) bool {
        const needle = std.mem.trim(u8, query, " \t\r\n");
        return needle.len == 0 or containsIgnoreCase(item.title, needle) or
            containsIgnoreCase(item.identity.node_id, needle) or
            containsIgnoreCase(item.identity.project_path, needle);
    }

    pub fn collect(items: []const Item, query: []const u8, output: []Item) usize {
        var count: usize = 0;
        for (items) |item| {
            if (count == output.len) break;
            if (matches(item, query)) {
                output[count] = item;
                count += 1;
            }
        }
        return count;
    }
};

pub const Cursor = struct {
    current: ?Identity = null,

    pub fn next(self: *Cursor, items: []const Item) ?Item {
        return self.step(items, 1, false);
    }

    pub fn previous(self: *Cursor, items: []const Item) ?Item {
        return self.step(items, -1, false);
    }

    pub fn nextAttention(self: *Cursor, items: []const Item) ?Item {
        return self.step(items, 1, true);
    }

    fn step(self: *Cursor, items: []const Item, offset: isize, attention_only: bool) ?Item {
        if (items.len == 0) return null;
        var start: usize = if (self.current) |current| blk: {
            for (items, 0..) |item, index| if (item.identity.eql(current)) break :blk index;
            break :blk if (offset < 0) items.len else 0;
        } else if (offset < 0) items.len else 0;
        var checked: usize = 0;
        while (checked < items.len) : (checked += 1) {
            if (offset > 0) start = (start + 1) % items.len else start = (start + items.len - 1) % items.len;
            if (attention_only and !items[start].attention) continue;
            self.current = items[start].identity;
            return items[start];
        }
        return null;
    }
};

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var equal = true;
        for (needle, 0..) |byte, index| {
            if (std.ascii.toLower(haystack[start + index]) != std.ascii.toLower(byte)) {
                equal = false;
                break;
            }
        }
        if (equal) return true;
    }
    return false;
}

test "palette searches title id and project across stable identities" {
    const items = [_]Item{
        .{ .identity = .{ .project_path = "C:\\one", .node_id = "a" }, .title = "Build", },
        .{ .identity = .{ .project_path = "C:\\two", .node_id = "b" }, .title = "Review", },
    };
    var result: [2]Item = undefined;
    try std.testing.expectEqual(@as(usize, 1), Search.collect(&items, "TWO", &result));
    try std.testing.expect(Identity.eql(result[0].identity, items[1].identity));
    try std.testing.expectEqual(@as(usize, 1), Search.collect(&items, "BUILD", &result));
}

test "navigation wraps and follows stable identity after reorder" {
    const first = Item{ .identity = .{ .project_path = "p", .node_id = "a" }, .title = "A" };
    const second = Item{ .identity = .{ .project_path = "p", .node_id = "b" }, .title = "B" };
    const third = Item{ .identity = .{ .project_path = "p", .node_id = "c" }, .title = "C", .attention = true };
    var cursor = Cursor{ .current = first.identity };
    const reordered = [_]Item{ third, first, second };
    try std.testing.expectEqualStrings("B", cursor.next(&reordered).?.title);
    try std.testing.expectEqualStrings("C", cursor.nextAttention(&reordered).?.title);
    try std.testing.expectEqualStrings("A", cursor.previous(&reordered).?.title);
}
