const std = @import("std");
const B = @import("backend.zig");
const xrce = @import("zz0_client").xrce;
const testing = std.testing;
const support = @import("test_support.zig");
const definitions = support.definitions;
const catalog = support.catalog;
const participant = support.participant;
const topic = support.topic;
const publisher = support.publisher;
const writer = support.writer;
const Fake = support.Fake;
const expect = support.expect;
const populate = support.populate;
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
test "backend clients isolate overlapping IDs and resolve configured definitions" {
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
    try testing.expectEqualStrings("writer", a.definitionFor(writer).?.name);
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
    const named = try (xrce.CreateBinary{ .session_id = 0x81, .sequence_nr = 0, .request_id = .{ 0, 2 }, .object_prefix = .{ 0, 0x10 }, .parent = participant, .definition = .{ .publisher = "pub" } }).encodeMessage(&wire);
    try expect(.ok, client.createWire(try xrce.decodeCreateMessage(wire[0..named])));
    const other = try (xrce.CreateBinary{ .session_id = 0x81, .sequence_nr = 0, .request_id = .{ 0, 3 }, .object_prefix = .{ 0, 0x20 }, .parent = participant, .definition = .{ .publisher = "other" } }).encodeMessage(&wire);
    try expect(.ok, client.createWire(try xrce.decodeCreateMessage(wire[0..other])));
    try testing.expectEqualStrings("other-publisher", client.definitionFor(.{ 0, 0x23 }).?.name);
    const w = try (xrce.CreateBinary{ .session_id = 0x81, .sequence_nr = 0, .request_id = .{ 0, 2 }, .object_prefix = .{ 0, 0x10 }, .parent = publisher, .definition = .{ .datawriter = "Reading" } }).encodeMessage(&wire);
    try expect(.err_denied, client.createWire(try xrce.decodeCreateMessage(wire[0..w])));
    try testing.expectEqual(@as(usize, 4), fake.create_calls);
}
