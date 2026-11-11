const std = @import("std");
const B = @import("zz0_agent_core").backend;
const xrce = @import("zz0_client").xrce;
const testing = std.testing;
const support = @import("zz0_agent_core").test_support;
const definitions = support.definitions;
const catalog = support.catalog;
const participant = support.participant;
const topic = support.topic;
const publisher = support.publisher;
const writer = support.writer;
const Fake = support.Fake;
const expect = support.expect;
const populate = support.populate;
test "packet backend write acceptance survives optional telemetry failure and bounds reply space" {
    const Agent = @import("fixture_root.zig").Agent;
    var fake: Fake = .{};
    var client = try B.Client.init(catalog, fake.backend());
    defer client.clear() catch @panic("cleanup");
    try populate(&client);
    var agent: Agent = .{ .backend_client = &client, .policy = .{ .writer_definition = "writer" } };
    var request: [64]u8 = undefined;
    var response: [64]u8 = undefined;
    const n = try (xrce.WriteData{ .session_id = 0x81, .sequence_nr = 3, .request_id = .{ 0xaa, 5 }, .object_id = writer, .serialized_data = &.{ 1, 2, 3, 4 } }).encodeMessage(&request);
    try testing.expectError(error.BufferTooSmall, agent.handleDatagram(request[0..n], response[0..1]));
    try testing.expectEqual(@as(usize, 0), fake.write_calls);
    const m = try agent.handleDatagram(request[0..n], &response);
    const status = try xrce.decodeStatusMessage(response[0..m]);
    try expect(.ok, status.result);
    try testing.expectEqual(@as(u64, 1), client.stats.accepted);
    try testing.expectEqual(@as(u64, 1), agent.write_stats.total_writes);
    try testing.expectEqual(@as(u64, 1), agent.policy.counter_status_stats.invalid);
    try testing.expectEqualSlices(u8, &.{ 0xaa, 5 }, &status.related_request.request_id);
    try testing.expectEqualSlices(u8, &writer, &status.related_request.object_id);
}
test "generated appendable nested and mutable fixtures use XTypes 1.3 headers" {
    const rt = @import("zidl_rt");
    const F = @import("encoding_fixture");
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(testing.allocator);
    var w = rt.CdrWriter(.xcdr2).init(&bytes, testing.allocator);
    try w.writeEncapHeaderDelimited();
    try F.DelimitedProbe.serialize(&w, .{ .value = 42 });
    try testing.expectEqualSlices(u8, &.{ 0, 9, 0, 0, 4, 0, 0, 0, 42, 0, 0, 0 }, bytes.items);
    bytes.clearRetainingCapacity();
    w = rt.CdrWriter(.xcdr2).init(&bytes, testing.allocator);
    try w.writeEncapHeader();
    try F.NestedProbe.serialize(&w, .{ .tag = 1, .nested = .{ .value = 42 }, .serial = 0x0102030405060708 });
    try testing.expectEqualSlices(u8, &.{ 0, 7, 0, 0, 1, 0, 0, 0, 4, 0, 0, 0, 42, 0, 0, 0, 8, 7, 6, 5, 4, 3, 2, 1 }, bytes.items);
    bytes.clearRetainingCapacity();
    w = rt.CdrWriter(.xcdr2).init(&bytes, testing.allocator);
    try w.writeEncapHeaderMutable();
    try F.MutableProbe.serialize(&w, .{ .value = 42 });
    try testing.expectEqualSlices(u8, &.{ 0, 11, 0, 0, 8, 0, 0, 0, 0, 0, 0, 32, 42, 0, 0, 0 }, bytes.items);
}

test "appendable wire sample reaches generated decoder through the packet adapter" {
    const Agent = @import("fixture_root.zig").Agent;
    const Decode = struct {
        fn write(ctx: *anyopaque, handle: B.Handle, bytes: []const u8) !void {
            const self: *Fake = @ptrCast(@alignCast(ctx));
            try testing.expect(self.live[handle.slot]);
            var reader = try @import("zidl_rt").CdrReader.init(bytes);
            var sample: @import("encoding_fixture").DelimitedProbe = undefined;
            try @import("encoding_fixture").DelimitedProbe.deserializeInto(&sample, &reader, testing.allocator);
            try testing.expectEqual(@as(u32, 42), sample.value);
            try testing.expectEqual(bytes.len, reader.pos);
            try testing.expectEqualSlices(u8, &.{ 0, 9, 0, 0, 4, 0, 0, 0, 42, 0, 0, 0 }, bytes);
            self.write_calls += 1;
        }
    };
    var fake: Fake = .{};
    var vtable = Fake.vtable;
    vtable.write = Decode.write;
    var defs = definitions;
    defs[3].encoding = .delimited_cdr2_le;
    var client = try B.Client.init(.{ .definitions = &defs }, .{ .context = &fake, .vtable = &vtable });
    defer client.clear() catch @panic("cleanup");
    try populate(&client);
    var agent: Agent = .{ .backend_client = &client };
    var request: [128]u8 = undefined;
    var response: [64]u8 = undefined;
    const n = try (xrce.WriteData{ .session_id = 0x81, .sequence_nr = 0, .request_id = .{ 0, 1 }, .object_id = writer, .serialized_data = &.{ 4, 0, 0, 0, 42, 0, 0, 0 } }).encodeMessage(&request);
    const m = try agent.handleDatagram(request[0..n], &response);
    try expect(.ok, (try xrce.decodeStatusMessage(response[0..m])).result);
    try testing.expectEqual(@as(usize, 1), fake.write_calls);
}
