const std = @import("std");
const B = @import("backend.zig");
const xrce = @import("zz0_client").xrce;
const testing = std.testing;
const definitions = [_]B.Definition{
    .{ .name = "participant", .kind = .participant, .participant = "main", .resource = "main", .domain = 42 },
    .{ .name = "topic", .kind = .topic, .participant = "main", .resource = "reading", .parent = "participant", .topic_name = "Reading" },
    .{ .name = "publisher", .kind = .publisher, .participant = "main", .resource = "pub", .parent = "participant" },
    .{ .name = "writer", .kind = .datawriter, .participant = "main", .resource = "reading", .parent = "publisher", .topic = "topic", .telemetry = .counter_status },
};
const catalog: B.Catalog = .{ .definitions = &definitions };
const participant: xrce.ObjectId = .{ 0, 0x11 };
const topic: xrce.ObjectId = .{ 0, 0x12 };
const publisher: xrce.ObjectId = .{ 0, 0x13 };
const writer: xrce.ObjectId = .{ 0, 0x15 };
const Fake = struct {
    next: usize = 0,
    live: [64]bool = @splat(false),
    create_calls: usize = 0,
    write_calls: usize = 0,
    fail_create: bool = false,
    fail_delete: bool = false,
    fail_clear: bool = false,
    dirty: bool = false,
    sample: [516]u8 = undefined,
    sample_len: usize = 0,
    reentrant: ?*B.Client = null,
    fn cast(ctx: *anyopaque) *@This() {
        return @ptrCast(@alignCast(ctx));
    }
    fn create(ctx: *anyopaque, _: *const B.Definition, parent: ?B.Handle, topic_: ?B.Handle) !B.Handle {
        const self = cast(ctx);
        self.create_calls += 1;
        if (self.reentrant) |owner| try testing.expectError(error.OperationInProgress, owner.clear());
        if (self.fail_create) return error.OutOfMemory;
        if (parent) |p| try testing.expect(self.live[p.slot]);
        if (topic_) |t| try testing.expect(self.live[t.slot]);
        const slot = self.next;
        self.next += 1;
        self.live[slot] = true;
        return .{ .slot = slot, .generation = 1 };
    }
    fn write(ctx: *anyopaque, handle: B.Handle, data: []const u8) !void {
        const self = cast(ctx);
        try testing.expect(self.live[handle.slot]);
        self.write_calls += 1;
        if (data.len != 8) return error.InvalidSample;
        self.sample_len = data.len;
        @memcpy(self.sample[0..data.len], data);
    }
    fn delete(ctx: *anyopaque, handle: B.Handle) !void {
        const self = cast(ctx);
        if (self.fail_delete) return error.CleanupFailed;
        try testing.expect(self.live[handle.slot]);
        self.live[handle.slot] = false;
    }
    fn clear(ctx: *anyopaque) !void {
        const self = cast(ctx);
        // Simulate partial backend cleanup before failure.
        self.live[0] = false;
        if (self.fail_clear) return error.CleanupFailed;
        self.live = @splat(false);
        self.dirty = false;
    }
    fn dirtyState(ctx: *anyopaque) bool {
        return cast(ctx).dirty;
    }
    const vtable: B.Backend.Vtable = .{ .create = create, .write = write, .delete = delete, .clear = clear, .needs_cleanup = dirtyState };
    fn backend(self: *@This()) B.Backend {
        return .{ .context = self, .vtable = &vtable };
    }
};
fn expect(status: xrce.StatusValue, result: xrce.ResultStatus) !void {
    try testing.expectEqual(status, result.status);
}
fn populate(client: *B.Client) !void {
    try expect(.ok, client.create(.{ .object_id = participant, .definition = "participant", .domain = 42 }));
    try expect(.ok, client.create(.{ .object_id = topic, .definition = "topic", .parent = participant }));
    try expect(.ok, client.create(.{ .object_id = publisher, .definition = "publisher", .parent = participant }));
    try expect(.ok, client.create(.{ .object_id = writer, .definition = "writer", .parent = publisher, .topic = topic }));
}
test "backend catalog validates kind and parent definitions without fixed object IDs" {
    try catalog.validate();
    var bad = definitions;
    bad[3].parent = "topic";
    try testing.expectError(error.InvalidDefinition, (B.Catalog{ .definitions = &bad }).validate());
    bad = definitions;
    bad[1].name = "participant";
    try testing.expectError(error.DuplicateDefinition, (B.Catalog{ .definitions = &bad }).validate());
    bad = definitions;
    bad[0].domain = null;
    try testing.expectError(error.InvalidDefinition, (B.Catalog{ .definitions = &bad }).validate());
}
test "backend clients isolate overlapping IDs and gate telemetry on configured definitions" {
    var fa: Fake = .{};
    var fb: Fake = .{};
    var a = try B.Client.init(catalog, fa.backend());
    var b = try B.Client.init(catalog, fb.backend());
    defer a.clear() catch @panic("cleanup");
    defer b.clear() catch @panic("cleanup");
    try populate(&a);
    try expect(.err_unknown_reference, b.write(writer, &.{ 1, 2, 3, 4 }));
    try populate(&b);
    try expect(.ok, a.write(writer, &.{ 1, 2, 3, 4 }));
    try testing.expectEqualSlices(u8, &.{ 0, 7, 0, 0, 1, 2, 3, 4 }, fa.sample[0..fa.sample_len]);
    try testing.expectEqual(@as(usize, 0), fb.write_calls);
    try testing.expectEqual(B.Telemetry.counter_status, a.telemetry(writer).?);
    try a.clear();
    try testing.expectEqual(@as(usize, 0), a.count());
    try testing.expectEqual(@as(usize, 4), b.count());
    try expect(.ok, b.write(writer, &.{ 5, 6, 7, 8 }));
}
test "backend requests check dependencies domain and complete occupied-ID flag behavior" {
    var fake: Fake = .{};
    var client = try B.Client.init(catalog, fake.backend());
    defer client.clear() catch @panic("cleanup");
    try expect(.err_mismatch, client.create(.{ .object_id = participant, .definition = "participant", .domain = 7 }));
    try expect(.err_unknown_reference, client.create(.{ .object_id = topic, .definition = "topic", .parent = participant }));
    try testing.expectEqual(@as(usize, 0), fake.create_calls);
    try populate(&client);
    try expect(.err_denied, client.delete(topic));
    const reused: B.Create = .{ .object_id = writer, .definition = "writer", .parent = publisher, .topic = topic, .mode = .{ .reuse = true, .replace = false } };
    try expect(.ok_matched, client.create(reused));
    var request = reused;
    request.mode.replace = true;
    try expect(.ok_matched, client.create(request));
    request.mode.reuse = false;
    try expect(.err_denied, client.create(request));
    request.mode.replace = false;
    try expect(.err_already_exists, client.create(request));
    request.definition = "missing";
    try expect(.err_already_exists, client.create(request));
    try testing.expectEqual(@as(usize, 4), fake.create_calls); // No replacement/re-registration.
    try expect(.ok, client.delete(writer));
    try expect(.ok, client.delete(publisher));
    try expect(.ok, client.delete(topic));
    try expect(.ok, client.delete(participant));
}
test "backend failures never publish mappings and failed cleanup retains a blocked owner" {
    var fake: Fake = .{ .fail_create = true };
    var client = try B.Client.init(catalog, fake.backend());
    defer {
        fake.fail_clear = false;
        client.clear() catch @panic("cleanup");
    }
    try expect(.err_resources, client.create(.{ .object_id = participant, .definition = "participant", .domain = 42 }));
    try testing.expectEqual(@as(usize, 0), client.count());
    try testing.expectEqual(error.OutOfMemory, client.last_error.?);
    fake.fail_create = false;
    try populate(&client);
    try expect(.err_invalid_data, client.write(writer, &.{1}));
    try testing.expectEqual(@as(u64, 0), client.stats.accepted);
    try expect(.ok, client.write(writer, &.{ 1, 2, 3, 4 }));
    try testing.expectEqual(@as(u64, 1), client.stats.accepted);
    fake.fail_delete = true;
    try expect(.err_dds_error, client.delete(writer));
    try testing.expectEqual(@as(usize, 4), client.count());
    try expect(.err_dds_error, client.write(writer, &.{ 1, 2, 3, 4 }));
    try testing.expectEqual(error.CleanupFailed, client.cleanup_cause.?);
    fake.fail_clear = true;
    try testing.expectError(error.CleanupFailed, client.clear());
    try testing.expectEqual(@as(usize, 4), client.count());
    fake.fail_clear = false;
    try client.clear();
    try testing.expectEqual(@as(usize, 0), client.count());
    try testing.expectEqual(@as(u64, 3), client.stats.received);
    try testing.expectEqual(@as(u64, 2), client.stats.rejected);
}
test "backend capacity is checked before construction and XCDR2 framing follows the type" {
    var defs = definitions;
    defs[3].encoding = .delimited_cdr2_le;
    var fake: Fake = .{};
    var client = try B.Client.init(.{ .definitions = &defs }, fake.backend());
    defer client.clear() catch @panic("cleanup");
    try populate(&client);
    try expect(.ok, client.write(writer, &.{ 1, 2, 3, 4 }));
    try testing.expectEqual(@as(u8, 9), fake.sample[1]);
    const oversized: [513]u8 = @splat(0);
    try expect(.err_invalid_data, client.write(writer, &oversized));
    for (4..32) |i| try expect(.ok, client.create(.{ .object_id = .{ @intCast(i), 0x11 }, .definition = "participant", .domain = 42 }));
    try expect(.err_resources, client.create(.{ .object_id = .{ 33, 0x11 }, .definition = "participant", .domain = 42 }));
    try testing.expectEqual(@as(usize, 32), fake.create_calls);
}

test "backend parenting checks participant instances and reuse compares actual parents" {
    var fake: Fake = .{};
    var client = try B.Client.init(catalog, fake.backend());
    defer client.clear() catch @panic("cleanup");
    fake.reentrant = &client;
    try populate(&client);
    const dp2: xrce.ObjectId = .{ 0, 0x21 };
    const tp2: xrce.ObjectId = .{ 0, 0x22 };
    const pub2: xrce.ObjectId = .{ 0, 0x23 };
    try expect(.ok, client.create(.{ .object_id = dp2, .definition = "participant", .domain = 42 }));
    try expect(.ok, client.create(.{ .object_id = tp2, .definition = "topic", .parent = dp2 }));
    try expect(.ok, client.create(.{ .object_id = pub2, .definition = "publisher", .parent = dp2 }));
    try expect(.err_mismatch, client.create(.{ .object_id = .{ 0, 0x25 }, .definition = "writer", .parent = pub2, .topic = topic }));
    try expect(.err_mismatch, client.create(.{ .object_id = writer, .definition = "writer", .parent = pub2, .topic = tp2, .mode = .{ .reuse = true, .replace = false } }));
    try expect(.err_denied, client.create(.{ .object_id = writer, .definition = "writer", .parent = pub2, .topic = tp2, .mode = .{ .reuse = true, .replace = true } }));
    try testing.expectEqual(@as(usize, 7), fake.create_calls);
}
test "backend dirty creation blocks operations until explicit cleanup succeeds" {
    var fake: Fake = .{};
    var client = try B.Client.init(catalog, fake.backend());
    defer client.clear() catch @panic("cleanup");
    fake.fail_create = true;
    fake.dirty = true;
    try expect(.err_resources, client.create(.{ .object_id = participant, .definition = "participant", .domain = 42 }));
    try testing.expectEqual(@as(usize, 0), client.count());
    fake.fail_create = false;
    try expect(.err_dds_error, client.create(.{ .object_id = participant, .definition = "participant", .domain = 42 }));
    try testing.expectEqual(@as(usize, 1), fake.create_calls);
    try testing.expectEqual(error.OutOfMemory, client.cleanup_cause.?);
    try client.clear();
    try testing.expect(client.cleanup_cause == null);
    try expect(.ok, client.create(.{ .object_id = participant, .definition = "participant", .domain = 42 }));
}

test "packet backend CREATE reserves reply capacity and preserves request correlation" {
    const Agent = @import("root.zig").Agent;
    var fake: Fake = .{};
    var client = try B.Client.init(catalog, fake.backend());
    defer client.clear() catch @panic("cleanup");
    var agent: Agent = .{ .backend_client = &client };
    var request: [128]u8 = undefined;
    var response: [128]u8 = undefined;
    const n = try (xrce.CreateByReference{ .session_id = 0x81, .sequence_nr = 4, .request_id = .{ 0xaa, 9 }, .object_prefix = .{ 0, 0x10 }, .object_kind = .participant, .reference = "participant", .participant_domain_id = 42 }).encodeMessage(&request);
    request[11] &= 0xf0; // Prefix form in CREATE, original bytes in STATUS.
    try testing.expectError(error.BufferTooSmall, agent.handleDatagram(request[0..n], response[0..1]));
    try testing.expectEqual(@as(usize, 0), fake.create_calls);
    const m = try agent.handleDatagram(request[0..n], &response);
    const status = try xrce.decodeStatusMessage(response[0..m]);
    try expect(.ok, status.result);
    try testing.expectEqualSlices(u8, &.{ 0xaa, 9 }, &status.related_request.request_id);
    try testing.expectEqualSlices(u8, request[10..12], &status.related_request.object_id);
    const t = try (xrce.CreateByReference{ .session_id = 0x81, .sequence_nr = 5, .request_id = .{ 0xaa, 10 }, .object_prefix = .{ 0, 0x10 }, .object_kind = .topic, .reference = "topic", .related_object_id = participant }).encodeMessage(&request);
    const tm = try agent.handleDatagram(request[0..t], &response);
    try expect(.ok, (try xrce.decodeStatusMessage(response[0..tm])).result);
    const p = try (xrce.CreateByReference{ .session_id = 0x81, .sequence_nr = 6, .request_id = .{ 0xaa, 11 }, .object_prefix = .{ 0, 0x10 }, .object_kind = .publisher, .reference = "publisher", .related_object_id = participant }).encodeMessage(&request);
    const pm = try agent.handleDatagram(request[0..p], &response);
    try expect(.err_invalid_data, (try xrce.decodeStatusMessage(response[0..pm])).result);
    try testing.expectEqual(@as(usize, 2), fake.create_calls);
}
test "packet backend write acceptance survives optional telemetry failure and bounds reply space" {
    const Agent = @import("root.zig").Agent;
    var fake: Fake = .{};
    var client = try B.Client.init(catalog, fake.backend());
    defer client.clear() catch @panic("cleanup");
    try populate(&client);
    var agent: Agent = .{ .backend_client = &client };
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
    try testing.expectEqual(@as(u64, 1), agent.counter_status_stats.invalid);
    try testing.expectEqualSlices(u8, &.{ 0xaa, 5 }, &status.related_request.request_id);
    try testing.expectEqualSlices(u8, &writer, &status.related_request.object_id);
}
test "packet DELETE and RESET retain cleanup obligations and reject multiple operations" {
    const Agent = @import("root.zig").Agent;
    var fake: Fake = .{};
    var client = try B.Client.init(catalog, fake.backend());
    defer {
        fake.fail_clear = false;
        client.clear() catch @panic("cleanup");
    }
    try populate(&client);
    var agent: Agent = .{ .backend_client = &client };
    var request: [64]u8 = undefined;
    var response: [64]u8 = undefined;
    const n = try (xrce.DeleteRequest{ .session_id = 0x81, .sequence_nr = 4, .request_id = .{ 0xaa, 6 }, .object_id = writer }).encodeMessage(&request);
    try testing.expectError(error.BufferTooSmall, agent.handleDatagram(request[0..n], response[0..1]));
    try testing.expectEqual(@as(usize, 4), client.count());
    const m = try agent.handleDatagram(request[0..n], &response);
    try expect(.ok, (try xrce.decodeStatusMessage(response[0..m])).result);
    try testing.expectEqual(@as(usize, 3), client.count());
    const r = try (xrce.Reset{ .session_id = 0x81, .sequence_nr = 5 }).encodeMessage(&request);
    // Two RESET submessages must be rejected before either is performed.
    @memcpy(request[r..][0..4], request[4..8]);
    try testing.expectError(error.UnsupportedMultipleSubmessages, agent.handleDatagram(request[0 .. r + 4], &response));
    try testing.expectEqual(@as(usize, 3), client.count());
    fake.fail_clear = true;
    try testing.expectError(error.CleanupFailed, agent.handleDatagram(request[0..r], &response));
    try testing.expectEqual(@as(usize, 3), client.count());
    fake.fail_clear = false;
    try testing.expectEqual(@as(usize, 0), try agent.handleDatagram(request[0..r], &response));
    try testing.expectEqual(@as(usize, 0), client.count());
}
test "UDP templates reject a shared backend context until client allocation is integrated" {
    const root = @import("root.zig");
    var fake: Fake = .{};
    var client = try B.Client.init(catalog, fake.backend());
    defer client.clear() catch @panic("cleanup");
    const template: root.Agent = .{ .backend_client = &client };
    var sessions: root.udp.ClientSessions = .{ .template = template };
    var out: [64]u8 = undefined;
    const address = std.Io.net.IpAddress{ .ip4 = .loopback(0) };
    try testing.expectError(error.BackendRequiresClientFactory, sessions.handleDatagram(address, &.{}, &out));
    try testing.expectError(error.BackendRequiresClientFactory, root.udp.UdpServer.bind(std.testing.io, address, template));
}

test "packet binary CREATE resolves publisher and writer without legacy reference forms" {
    const Agent = @import("root.zig").Agent;
    var fake: Fake = .{};
    var client = try B.Client.init(catalog, fake.backend());
    defer client.clear() catch @panic("cleanup");
    var agent: Agent = .{ .backend_client = &client };
    // Root objects are already authorized/created; no publisher or writer yet.
    try expect(.ok, client.create(.{ .object_id = participant, .definition = "participant", .domain = 42 }));
    try expect(.ok, client.create(.{ .object_id = topic, .definition = "topic", .parent = participant }));
    var request: [256]u8 = undefined;
    var response: [64]u8 = undefined;
    const p = try (xrce.CreateBinary{ .session_id = 0x81, .sequence_nr = 1, .request_id = .{ 0xaa, 1 }, .object_prefix = .{ 0, 0x10 }, .parent = participant, .definition = .{ .publisher = "pub" } }).encodeMessage(&request);
    const pr = try agent.handleDatagram(request[0..p], &response);
    try expect(.ok, (try xrce.decodeStatusMessage(response[0..pr])).result);
    const w = try (xrce.CreateBinary{ .session_id = 0x81, .sequence_nr = 2, .request_id = .{ 0xaa, 2 }, .object_prefix = .{ 0, 0x10 }, .parent = publisher, .definition = .{ .datawriter = "Reading" } }).encodeMessage(&request);
    const wr = try agent.handleDatagram(request[0..w], &response);
    try expect(.ok, (try xrce.decodeStatusMessage(response[0..wr])).result);
    try testing.expectEqual(@as(usize, 4), client.count());
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
    const Agent = @import("root.zig").Agent;
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
    defs[3].telemetry = .none;
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

test "binary CREATE rejects ambiguous configured publishers and writers" {
    var defs: [6]B.Definition = undefined;
    @memcpy(defs[0..4], &definitions);
    defs[4] = .{ .name = "other-publisher", .kind = .publisher, .participant = "main", .resource = "other", .parent = "participant" };
    defs[5] = .{ .name = "other-writer", .kind = .datawriter, .participant = "main", .resource = "other", .parent = "publisher", .topic = "topic" };
    var fake: Fake = .{};
    var client = try B.Client.init(.{ .definitions = &defs }, fake.backend());
    defer client.clear() catch @panic("cleanup");
    try expect(.ok, client.create(.{ .object_id = participant, .definition = "participant", .domain = 42 }));
    try expect(.ok, client.create(.{ .object_id = topic, .definition = "topic", .parent = participant }));
    var wire: [256]u8 = undefined;
    const p = try (xrce.CreateBinary{ .session_id = 0x81, .sequence_nr = 0, .request_id = .{ 0, 1 }, .object_prefix = .{ 0, 0x10 }, .parent = participant, .definition = .{ .publisher = null } }).encodeMessage(&wire);
    try expect(.err_denied, client.createWire(try xrce.decodeCreateMessage(wire[0..p])));
    try testing.expectEqual(@as(usize, 2), fake.create_calls);
    try expect(.ok, client.create(.{ .object_id = publisher, .definition = "publisher", .parent = participant }));
    const w = try (xrce.CreateBinary{ .session_id = 0x81, .sequence_nr = 0, .request_id = .{ 0, 2 }, .object_prefix = .{ 0, 0x10 }, .parent = publisher, .definition = .{ .datawriter = "Reading" } }).encodeMessage(&wire);
    try expect(.err_denied, client.createWire(try xrce.decodeCreateMessage(wire[0..w])));
    try testing.expectEqual(@as(usize, 3), fake.create_calls);
}
