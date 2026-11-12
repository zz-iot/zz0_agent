const std = @import("std");
const core = @import("root.zig");
const X = core.xrce;
const B = core.backend;
const S = core.udp.ClientSessions;
const support = @import("test_support.zig");
const t = std.testing;
const second = std.time.ns_per_s;
const peer: std.Io.net.IpAddress = .{ .ip4 = .loopback(23100) };

const Factory = struct {
    owners: [8]?B.Client = @splat(null),
    backends: [8]support.Fake = @splat(.{}),
    close_calls: usize = 0,
    fail: ?usize = null,
    fn open(ctx: *anyopaque, _: [4]u8, _: u8) !*B.Client {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        for (&self.owners, 0..) |*slot, i| if (slot.* == null) {
            self.backends[i] = .{};
            slot.* = try B.Client.init(support.catalog, self.backends[i].backend());
            return &slot.*.?;
        };
        return error.OutOfMemory;
    }
    fn close(ctx: *anyopaque, owner: *B.Client) !void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.close_calls += 1;
        for (&self.owners, 0..) |*slot, i| if (slot.* != null and &slot.*.? == owner) {
            if (self.fail == i) return error.CleanupFailed;
            try owner.clear();
            slot.* = null;
            return;
        };
        return error.UnknownOwner;
    }
    fn factory(self: *@This()) B.ClientFactory {
        return .{ .context = self, .open = open, .close = close };
    }
};
fn login(s: *S, key: u8, port: u16, sid: u8) !void {
    var req: [64]u8 = undefined;
    var out: [64]u8 = undefined;
    const n = try (X.CreateClient{ .client_key = .{ 1, 2, 3, key }, .session_id = sid }).encodeMessage(&req);
    _ = try s.handleDatagram(.{ .ip4 = .loopback(port) }, req[0..n], &out);
}
fn write(s: *S, output: []u8) !usize {
    var request: [128]u8 = undefined;
    const n = try (X.WriteData{ .session_id = 0x81, .sequence_nr = 1, .request_id = .{ 0, 1 }, .object_id = support.writer, .serialized_data = &.{ 1, 2, 3, 4 } }).encodeMessage(&request);
    return s.handleDatagram(peer, request[0..n], output);
}
test "expiry deadline frees capacity and same-key login starts a fresh graph" {
    var f: Factory = .{};
    var s: S = .{ .backend_factory = f.factory(), .idle_timeout = .fromSeconds(10) };
    defer s.close() catch @panic("cleanup");
    for (0..8) |i| try login(&s, @intCast(i), @intCast(23100 + i), 0x81);
    try support.populate(s.clients[0].?.agent.backend_client.?);
    try t.expectError(error.ClientCapacityExceeded, login(&s, 9, 23200, 0x81));
    s.maintain(9 * second);
    try login(&s, 1, 23101, 0x81); // Preserve this client while all others expire.
    s.maintain(10 * second - 1);
    try t.expectEqual(@as(usize, 0), f.close_calls);
    s.maintain(10 * second);
    try t.expect(s.clients[0] == null);
    try t.expect(s.clients[1] != null);
    try t.expectEqual(@as(usize, 7), f.close_calls);
    try login(&s, 0, 23100, 0x81);
    try t.expectEqual(@as(usize, 0), s.clients[0].?.agent.backend_client.?.count());
    try login(&s, 9, 23200, 0x81);
}
test "valid negative status refreshes activity but malformed traffic and short output do not" {
    var f: Factory = .{};
    var s: S = .{ .backend_factory = f.factory(), .idle_timeout = .fromSeconds(10) };
    defer s.close() catch @panic("cleanup");
    try login(&s, 1, 23100, 0x81);
    var out: [64]u8 = undefined;
    s.maintain(5 * second);
    const n = try write(&s, &out);
    try t.expectEqual(X.StatusValue.err_unknown_reference, (try X.decodeStatusMessage(out[0..n])).result.status);
    try t.expectEqual(@as(i96, 5 * second), s.clients[0].?.last_activity);
    s.maintain(9 * second);
    try t.expectError(error.BufferTooSmall, write(&s, out[0..0]));
    try t.expectError(error.ShortMessage, s.handleDatagram(peer, "bad", &out));
    const unsupported = [_]u8{ 0x81, 1, 0, 0, 0x0a, 1, 0, 0 }; // Unsupported ACKNACK
    try t.expectError(error.NoSupportedSubmessage, s.handleDatagram(peer, &unsupported, &out));
    var malformed = [_]u8{ 0x81, 1, 0, 0, 7, 1, 0, 0 }; // WRITE_DATA without request/object IDs
    try t.expectError(error.ShortSubmessage, s.handleDatagram(peer, &malformed, &out));
    var multiple: [128]u8 = undefined;
    const len = try (X.WriteData{ .session_id = 0x81, .sequence_nr = 2, .request_id = .{ 0, 2 }, .object_id = support.writer, .serialized_data = &.{ 1, 2, 3, 4 } }).encodeMessage(&multiple);
    @memcpy(multiple[len..][0..4], unsupported[4..8]);
    try t.expectError(error.UnsupportedMultipleSubmessages, s.handleDatagram(peer, multiple[0 .. len + 4], &out));
    var registration: [64]u8 = undefined;
    const registered = try (X.CreateClient{ .client_key = .{ 1, 2, 3, 1 }, .session_id = 0x82 }).encodeMessage(&registration);
    try t.expectError(error.BufferTooSmall, s.handleDatagram(peer, registration[0..registered], out[0..0]));
    try t.expectEqual(@as(u8, 0x81), s.clients[0].?.session_id);
    try t.expectEqual(@as(i96, 5 * second), s.clients[0].?.last_activity);
    s.maintain(15 * second);
    try t.expect(s.clients[0] == null);
}
test "failed expiry retains ownership, spaces retries and does not block other expirations" {
    const previous = t.log_level;
    t.log_level = .err;
    defer t.log_level = previous;
    var f: Factory = .{};
    var s: S = .{ .backend_factory = f.factory(), .idle_timeout = .fromSeconds(10) };
    defer s.close() catch @panic("cleanup");
    try login(&s, 1, 23100, 0x81);
    try login(&s, 2, 23101, 0x81);
    try support.populate(s.clients[0].?.agent.backend_client.?);
    f.fail = 0;
    s.maintain(10 * second);
    try t.expect(s.clients[0].?.closing);
    try t.expect(s.clients[1] == null);
    try t.expectEqual(@as(usize, 4), s.clients[0].?.agent.backend_client.?.count());
    try t.expectEqual(@as(i96, 11 * second), s.nextMaintenance().?);
    try t.expectEqual(@as(usize, 2), f.close_calls);
    try t.expectError(error.ClientCleanupRequired, login(&s, 1, 23100, 0x81));
    try t.expectError(error.ClientCleanupRequired, login(&s, 1, 23100, 0x82));
    var out: [64]u8 = undefined;
    try t.expectError(error.ClientCleanupRequired, write(&s, &out));
    s.maintain(11 * second - 1);
    try t.expectEqual(@as(usize, 2), f.close_calls);
    s.maintain(11 * second);
    try t.expectEqual(@as(usize, 3), f.close_calls);
    f.fail = null;
    s.maintain(12 * second);
    try t.expect(s.clients[0] == null);
    try login(&s, 1, 23100, 0x81);
    try t.expectEqual(@as(usize, 0), s.clients[0].?.agent.backend_client.?.count());
}
test "RESET refreshes activity and rebinding preserves graph until expiry" {
    var f: Factory = .{};
    var s: S = .{ .backend_factory = f.factory(), .idle_timeout = .fromSeconds(10) };
    defer s.close() catch @panic("cleanup");
    try login(&s, 1, 23100, 0x81);
    const owner = s.clients[0].?.agent.backend_client.?;
    try support.populate(owner);
    s.maintain(5 * second);
    try login(&s, 1, 23101, 0x81);
    try t.expectEqual(owner, s.clients[0].?.agent.backend_client.?);
    try t.expectEqual(@as(usize, 4), owner.count());
    s.maintain(9 * second);
    var req: [64]u8 = undefined;
    var out: [64]u8 = undefined;
    const n = try (X.Reset{ .session_id = 0x81, .sequence_nr = 5 }).encodeMessage(&req);
    try t.expectEqual(@as(usize, 0), try s.handleDatagram(.{ .ip4 = .loopback(23101) }, req[0..n], &out));
    try t.expectEqual(@as(i96, 9 * second), s.clients[0].?.last_activity);
    try t.expectEqual(@as(usize, 0), owner.count());
    s.maintain(19 * second);
    try t.expect(s.clients[0] == null);
}
test "reusable sessions disable expiry by default and fixture slots can expire" {
    var s: S = .{};
    try login(&s, 1, 23100, 0x81);
    s.maintain(1000 * second);
    try t.expect(s.clients[0] != null);
    try t.expect(s.nextMaintenance() == null);
    s.idle_timeout = .fromSeconds(10);
    s.maintain(1000 * second);
    try t.expect(s.clients[0] == null);
}
