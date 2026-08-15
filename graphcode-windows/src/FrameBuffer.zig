const std = @import("std");
const Wire = @import("Wire.zig");

pub const FrameBuffer = struct {
    mode: Wire.ProtocolMode = .v2,
    bytes: [Wire.legacy_max_payload + 4]u8 = undefined,
    length: usize = 0,
    expected_length: ?usize = null,

    pub fn init(mode: Wire.ProtocolMode) FrameBuffer {
        return .{ .mode = mode };
    }

    pub fn setMode(self: *FrameBuffer, mode: Wire.ProtocolMode) void {
        self.mode = mode;
        self.reset();
    }

    pub fn reset(self: *FrameBuffer) void {
        self.length = 0;
        self.expected_length = null;
    }

    pub fn append(self: *FrameBuffer, chunk: []const u8) !void {
        if (chunk.len > self.bytes.len - self.length) return error.BufferOverflow;
        @memcpy(self.bytes[self.length..][0..chunk.len], chunk);
        self.length += chunk.len;
    }

    pub fn next(self: *FrameBuffer, allocator: std.mem.Allocator) !?[]u8 {
        if (self.expected_length == null) {
            if (self.length < 4) return null;
            var header: [4]u8 = undefined;
            @memcpy(&header, self.bytes[0..4]);
            self.remove(4);
            self.expected_length = try Wire.decodedLength(header, self.mode);
        }
        const frame_length = self.expected_length.?;
        if (self.length < frame_length) return null;
        const frame = try allocator.alloc(u8, frame_length);
        errdefer allocator.free(frame);
        @memcpy(frame, self.bytes[0..frame_length]);
        self.remove(frame_length);
        self.expected_length = null;
        return frame;
    }

    fn remove(self: *FrameBuffer, count: usize) void {
        const remaining = self.length - count;
        if (remaining != 0) {
            std.mem.copyForwards(u8, self.bytes[0..remaining], self.bytes[count..self.length]);
        }
        self.length = remaining;
    }
};

test "incremental frame buffering never requires a complete read" {
    const allocator = std.testing.allocator;
    const payload = "split frame";
    const header = try Wire.frameLength(payload, .v2);
    var buffer = FrameBuffer.init(.v2);
    try buffer.append(header[0..2]);
    try std.testing.expect((try buffer.next(allocator)) == null);
    try buffer.append(header[2..]);
    try buffer.append(payload[0..5]);
    try std.testing.expect((try buffer.next(allocator)) == null);
    try buffer.append(payload[5..]);
    const frame = (try buffer.next(allocator)).?;
    defer allocator.free(frame);
    try std.testing.expectEqualStrings(payload, frame);
}

test "incremental frame buffering drains coalesced frames" {
    const allocator = std.testing.allocator;
    const first = "one";
    const second = "two";
    const first_header = try Wire.frameLength(first, .v2);
    const second_header = try Wire.frameLength(second, .v2);
    var buffer = FrameBuffer.init(.v2);
    try buffer.append(&first_header);
    try buffer.append(first);
    try buffer.append(&second_header);
    try buffer.append(second);
    const first_frame = (try buffer.next(allocator)).?;
    defer allocator.free(first_frame);
    const second_frame = (try buffer.next(allocator)).?;
    defer allocator.free(second_frame);
    try std.testing.expectEqualStrings(first, first_frame);
    try std.testing.expectEqualStrings(second, second_frame);
    try std.testing.expect((try buffer.next(allocator)) == null);
}
