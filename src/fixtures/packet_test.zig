const zz0_client = @import("zz0_client");
const std = @import("std");
const root = @import("../fixture_root.zig");
const Agent = root.Agent;
const xrce = root.xrce;
const resources = root.resources;
const demo = @import("zz0_client").demo;
const zidl_rt = @import("zidl_rt");
const counter_types = @import("counter_types");
fn expectAgentDatagram(agent: *Agent, input: []const u8, output: []u8) !usize {
    return agent.handleDatagram(input, output);
}

test "agent replies to CREATE by-reference with STATUS OK" {
    var agent = Agent{};
    var request: [128]u8 = undefined;
    const request_len = try (xrce.CreateByReference{
        .session_id = 0x81,
        .sequence_nr = 14,
        .request_id = .{ 0xaa, 0x01 },
        .object_prefix = .{ 0xdd, 0xd0 },
        .object_kind = .application,
        .reference = "DemoApp",
    }).encodeMessage(&request);

    var response: [xrce.Status.message_len]u8 = undefined;
    const response_len = try expectAgentDatagram(&agent, request[0..request_len], &response);
    const status = try xrce.decodeStatusMessage(response[0..response_len]);

    try std.testing.expectEqual(@as(u8, 0x81), status.header.session_id);
    try std.testing.expectEqual(@as(u16, 14), status.header.sequence_nr);
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0x01 }, &status.related_request.request_id);
    try std.testing.expectEqualSlices(u8, &.{ 0xdd, 0xdc }, &status.related_request.object_id);
    try std.testing.expectEqual(xrce.StatusValue.ok, status.result.status);

    const saved = agent.policy.resource_table.lookup(.{ 0xdd, 0xdc }) orelse return error.ExpectedResource;
    try std.testing.expectEqual(xrce.ObjectKind.application, saved.object_kind);
    try std.testing.expectEqualSlices(u8, "DemoApp", saved.reference());
}

test "agent rejects CREATE by-reference for unknown catalog reference" {
    var agent = Agent{};
    var request: [128]u8 = undefined;
    const request_len = try (xrce.CreateByReference{
        .session_id = 0x81,
        .sequence_nr = 14,
        .request_id = .{ 0xaa, 0x01 },
        .object_prefix = .{ 0xdd, 0xd0 },
        .object_kind = .application,
        .reference = "UnknownApp",
    }).encodeMessage(&request);

    var response: [xrce.Status.message_len]u8 = undefined;
    const response_len = try expectAgentDatagram(&agent, request[0..request_len], &response);
    const status = try xrce.decodeStatusMessage(response[0..response_len]);

    try std.testing.expectEqual(xrce.StatusValue.err_unknown_reference, status.result.status);
    try std.testing.expectEqual(@as(usize, 0), agent.policy.resource_table.len);
}

test "agent accepts CREATE by-reference from configured catalog" {
    const entries = [_]resources.ReferenceDefinition{
        .{
            .object_kind = .application,
            .reference = "CustomApp",
        },
    };
    var agent = Agent{
        .policy = .{ .reference_catalog = .{ .entries = &entries } },
    };
    var request: [128]u8 = undefined;
    const request_len = try (xrce.CreateByReference{
        .session_id = 0x81,
        .sequence_nr = 14,
        .request_id = .{ 0xaa, 0x01 },
        .object_prefix = .{ 0xdd, 0xd0 },
        .object_kind = .application,
        .reference = "CustomApp",
    }).encodeMessage(&request);

    var response: [xrce.Status.message_len]u8 = undefined;
    const response_len = try expectAgentDatagram(&agent, request[0..request_len], &response);
    const status = try xrce.decodeStatusMessage(response[0..response_len]);

    try std.testing.expectEqual(xrce.StatusValue.ok, status.result.status);
    try std.testing.expectEqual(@as(usize, 1), agent.policy.resource_table.len);
}

test "agent rejects CREATE by-reference with mismatched catalog context" {
    var agent = Agent{};
    var request: [160]u8 = undefined;
    const request_len = try (xrce.CreateByReference{
        .session_id = 0x81,
        .sequence_nr = 14,
        .request_id = .{ 0xaa, 0x01 },
        .object_prefix = .{ 0xdd, 0xd0 },
        .object_kind = .participant,
        .reference = "MyLibrary::MyParticipant",
        .participant_domain_id = 3,
    }).encodeMessage(&request);

    var response: [xrce.Status.message_len]u8 = undefined;
    const response_len = try expectAgentDatagram(&agent, request[0..request_len], &response);
    const status = try xrce.decodeStatusMessage(response[0..response_len]);

    try std.testing.expectEqual(xrce.StatusValue.err_mismatch, status.result.status);
    try std.testing.expectEqual(@as(usize, 0), agent.policy.resource_table.len);
}

test "agent CREATE duplicate same resource returns OK_MATCHED" {
    var agent = Agent{};
    var request: [128]u8 = undefined;
    const request_len = try (xrce.CreateByReference{
        .session_id = 0x81,
        .sequence_nr = 14,
        .request_id = .{ 0xaa, 0x01 },
        .object_prefix = .{ 0xdd, 0xd0 },
        .object_kind = .application,
        .reference = "DemoApp",
    }).encodeMessage(&request);

    var response: [xrce.Status.message_len]u8 = undefined;
    _ = try expectAgentDatagram(&agent, request[0..request_len], &response);
    const response_len = try expectAgentDatagram(&agent, request[0..request_len], &response);
    const status = try xrce.decodeStatusMessage(response[0..response_len]);
    try std.testing.expectEqual(xrce.StatusValue.ok_matched, status.result.status);
    try std.testing.expectEqual(@as(usize, 1), agent.policy.resource_table.len);
}

test "agent CREATE duplicate different resource without replace returns mismatch" {
    var agent = Agent{};
    var first: [128]u8 = undefined;
    const first_len = try (xrce.CreateByReference{
        .session_id = 0x81,
        .sequence_nr = 14,
        .request_id = .{ 0xaa, 0x01 },
        .object_prefix = .{ 0xdd, 0xd0 },
        .object_kind = .application,
        .reference = "DemoApp",
    }).encodeMessage(&first);

    var response: [xrce.Status.message_len]u8 = undefined;
    _ = try expectAgentDatagram(&agent, first[0..first_len], &response);

    var second: [128]u8 = undefined;
    const second_len = try (xrce.CreateByReference{
        .session_id = 0x81,
        .sequence_nr = 15,
        .request_id = .{ 0xab, 0x01 },
        .object_prefix = .{ 0xdd, 0xd0 },
        .object_kind = .application,
        .reference = "OtherApp",
        .reuse = false,
        .replace = false,
    }).encodeMessage(&second);

    const response_len = try expectAgentDatagram(&agent, second[0..second_len], &response);
    const status = try xrce.decodeStatusMessage(response[0..response_len]);
    try std.testing.expectEqual(xrce.StatusValue.err_mismatch, status.result.status);
    try std.testing.expectEqual(@as(usize, 1), agent.policy.resource_table.len);
    const saved = agent.policy.resource_table.lookup(.{ 0xdd, 0xdc }) orelse return error.ExpectedResource;
    try std.testing.expectEqualSlices(u8, "DemoApp", saved.reference());
}

test "agent CREATE duplicate different resource with replace updates resource" {
    var agent = Agent{};
    var first: [128]u8 = undefined;
    const first_len = try (xrce.CreateByReference{
        .session_id = 0x81,
        .sequence_nr = 14,
        .request_id = .{ 0xaa, 0x01 },
        .object_prefix = .{ 0xdd, 0xd0 },
        .object_kind = .application,
        .reference = "DemoApp",
    }).encodeMessage(&first);

    var response: [xrce.Status.message_len]u8 = undefined;
    _ = try expectAgentDatagram(&agent, first[0..first_len], &response);

    var second: [128]u8 = undefined;
    const second_len = try (xrce.CreateByReference{
        .session_id = 0x81,
        .sequence_nr = 15,
        .request_id = .{ 0xab, 0x01 },
        .object_prefix = .{ 0xdd, 0xd0 },
        .object_kind = .application,
        .reference = "OtherApp",
        .reuse = false,
        .replace = true,
    }).encodeMessage(&second);

    const response_len = try expectAgentDatagram(&agent, second[0..second_len], &response);
    const status = try xrce.decodeStatusMessage(response[0..response_len]);
    try std.testing.expectEqual(xrce.StatusValue.ok, status.result.status);
    try std.testing.expectEqual(@as(usize, 1), agent.policy.resource_table.len);
    const saved = agent.policy.resource_table.lookup(.{ 0xdd, 0xdc }) orelse return error.ExpectedResource;
    try std.testing.expectEqualSlices(u8, "OtherApp", saved.reference());
}

test "agent accepts WRITE_DATA for created datawriter" {
    var agent = Agent{};

    const create_specs = [_]zz0_client.demo.ReferenceCreate{
        zz0_client.demo.participant,
        zz0_client.demo.publisher,
        zz0_client.demo.datawriter,
    };

    var create_request: [160]u8 = undefined;
    var response: [xrce.Status.message_len]u8 = undefined;
    for (create_specs, 0..) |spec, index| {
        const request_len = try (xrce.CreateByReference{
            .session_id = 0x81,
            .sequence_nr = @intCast(index + 1),
            .request_id = .{ @intCast(index + 1), 0x00 },
            .object_prefix = spec.object_prefix,
            .object_kind = spec.object_kind,
            .reference = spec.reference,
            .participant_domain_id = spec.participant_domain_id orelse 0,
            .related_object_id = spec.related_object_id,
        }).encodeMessage(&create_request);
        _ = try expectAgentDatagram(&agent, create_request[0..request_len], &response);
    }

    var payload_buf: [128]u8 = undefined;
    const payload = try encodeCounterStatusForTest(payload_buf[0..], .{
        .counter = 42,
        .board = try zidl_rt.BoundedArray(u8, 16).fromSlice("agent-test"),
        .payload = try zidl_rt.BoundedArray(u8, 8).fromSlice(&.{ 1, 2, 3, 4 }),
    });

    var write_request: [256]u8 = undefined;
    const write_len = try (xrce.WriteData{
        .session_id = 0x81,
        .sequence_nr = 10,
        .request_id = .{ 0x55, 0x00 },
        .object_id = zz0_client.demo.datawriter.object_id,
        .serialized_data = payload,
    }).encodeMessage(&write_request);

    const response_len = try expectAgentDatagram(&agent, write_request[0..write_len], &response);
    const status = try xrce.decodeStatusMessage(response[0..response_len]);
    try std.testing.expectEqual(xrce.StatusValue.ok, status.result.status);
    try std.testing.expectEqual(@as(u64, 1), agent.write_stats.total_writes);
    try std.testing.expectEqual(@as(u64, payload.len), agent.write_stats.total_bytes);
    try std.testing.expectEqual(@as(u64, 1), agent.policy.counter_status_stats.decoded);
    try std.testing.expectEqual(@as(u32, 42), agent.policy.counter_status_stats.last_counter);
    try std.testing.expectEqualSlices(u8, "agent-test", agent.policy.counter_status_stats.lastBoard());
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, agent.policy.counter_status_stats.lastPayload());
    const stats = agent.write_stats.lookup(zz0_client.demo.datawriter.object_id) orelse return error.ExpectedObjectStats;
    try std.testing.expectEqual(@as(u64, 1), stats.writes);
    try std.testing.expectEqual(@as(u64, payload.len), stats.bytes);
}

test "agent rejects malformed CounterStatus WRITE_DATA for demo datawriter" {
    var agent = Agent{};

    const create_specs = [_]zz0_client.demo.ReferenceCreate{
        zz0_client.demo.participant,
        zz0_client.demo.publisher,
        zz0_client.demo.datawriter,
    };

    var create_request: [160]u8 = undefined;
    var response: [xrce.Status.message_len]u8 = undefined;
    for (create_specs, 0..) |spec, index| {
        const request_len = try (xrce.CreateByReference{
            .session_id = 0x81,
            .sequence_nr = @intCast(index + 1),
            .request_id = .{ @intCast(index + 1), 0x00 },
            .object_prefix = spec.object_prefix,
            .object_kind = spec.object_kind,
            .reference = spec.reference,
            .participant_domain_id = spec.participant_domain_id orelse 0,
            .related_object_id = spec.related_object_id,
        }).encodeMessage(&create_request);
        _ = try expectAgentDatagram(&agent, create_request[0..request_len], &response);
    }

    var write_request: [256]u8 = undefined;
    const write_len = try (xrce.WriteData{
        .session_id = 0x81,
        .sequence_nr = 10,
        .request_id = .{ 0x55, 0x00 },
        .object_id = zz0_client.demo.datawriter.object_id,
        .serialized_data = &.{ 0x00, 0x01 },
    }).encodeMessage(&write_request);

    const response_len = try expectAgentDatagram(&agent, write_request[0..write_len], &response);
    const status = try xrce.decodeStatusMessage(response[0..response_len]);
    try std.testing.expectEqual(xrce.StatusValue.err_invalid_data, status.result.status);
    try std.testing.expectEqual(@as(u64, 0), agent.write_stats.total_writes);
    try std.testing.expectEqual(@as(u64, 0), agent.policy.counter_status_stats.decoded);
    try std.testing.expectEqual(@as(u64, 1), agent.policy.counter_status_stats.invalid);
}

test "agent rejects WRITE_DATA for unknown object id" {
    var agent = Agent{};
    var request: [128]u8 = undefined;
    const request_len = try (xrce.WriteData{
        .session_id = 0x81,
        .sequence_nr = 10,
        .request_id = .{ 0x33, 0x00 },
        .object_id = .{ 0x10, 0x55 },
        .serialized_data = &.{ 0x01, 0x02 },
    }).encodeMessage(&request);

    var response: [xrce.Status.message_len]u8 = undefined;
    const response_len = try expectAgentDatagram(&agent, request[0..request_len], &response);
    const status = try xrce.decodeStatusMessage(response[0..response_len]);
    try std.testing.expectEqual(xrce.StatusValue.err_unknown_reference, status.result.status);
}

test "agent accepts many WRITE_DATA samples without resource exhaustion" {
    var agent = Agent{};

    const create_specs = [_]zz0_client.demo.ReferenceCreate{
        zz0_client.demo.participant,
        zz0_client.demo.publisher,
        zz0_client.demo.datawriter,
    };

    var create_request: [160]u8 = undefined;
    var response: [xrce.Status.message_len]u8 = undefined;
    for (create_specs, 0..) |spec, index| {
        const request_len = try (xrce.CreateByReference{
            .session_id = 0x81,
            .sequence_nr = @intCast(index + 1),
            .request_id = .{ @intCast(index + 1), 0x00 },
            .object_prefix = spec.object_prefix,
            .object_kind = spec.object_kind,
            .reference = spec.reference,
            .participant_domain_id = spec.participant_domain_id orelse 0,
            .related_object_id = spec.related_object_id,
        }).encodeMessage(&create_request);
        _ = try expectAgentDatagram(&agent, create_request[0..request_len], &response);
    }

    var write_request: [256]u8 = undefined;
    var i: u16 = 0;
    while (i < 128) : (i += 1) {
        var payload_buf: [128]u8 = undefined;
        const payload = try encodeCounterStatusForTest(payload_buf[0..], .{
            .counter = i,
            .board = try zidl_rt.BoundedArray(u8, 16).fromSlice("agent-test"),
            .payload = try zidl_rt.BoundedArray(u8, 8).fromSlice(&.{ @truncate(i & 0xff), @truncate(i >> 8) }),
        });

        const write_len = try (xrce.WriteData{
            .session_id = 0x81,
            .sequence_nr = i,
            .request_id = .{ @truncate(i & 0xff), @truncate(i >> 8) },
            .object_id = zz0_client.demo.datawriter.object_id,
            .serialized_data = payload,
        }).encodeMessage(&write_request);
        const response_len = try expectAgentDatagram(&agent, write_request[0..write_len], &response);
        const status = try xrce.decodeStatusMessage(response[0..response_len]);
        try std.testing.expectEqual(xrce.StatusValue.ok, status.result.status);
    }

    try std.testing.expectEqual(@as(u64, 128), agent.write_stats.total_writes);
    try std.testing.expectEqual(@as(u64, 128), agent.policy.counter_status_stats.decoded);
    try std.testing.expectEqual(@as(u32, 127), agent.policy.counter_status_stats.last_counter);
}

fn encodeCounterStatusForTest(out: []u8, sample: counter_types.CounterStatus) ![]const u8 {
    const allocator = std.testing.allocator;
    var bytes = std.ArrayListUnmanaged(u8).empty;
    defer bytes.deinit(allocator);

    var writer = zidl_rt.CdrWriter(.xcdr2).init(&bytes, allocator);
    try counter_types.CounterStatus.serialize(&writer, sample);
    if (bytes.items.len > out.len) return error.BufferTooSmall;
    @memcpy(out[0..bytes.items.len], bytes.items);
    return out[0..bytes.items.len];
}

test "CREATE prefix derives resource identity while STATUS preserves correlation bytes" {
    const demo_entity = demo.participant;
    var request: [128]u8 = undefined;
    const n = try (xrce.CreateByReference{
        .session_id = 0x81,
        .sequence_nr = 0,
        .request_id = .{ 0, 1 },
        .object_prefix = demo_entity.object_prefix,
        .object_kind = demo_entity.object_kind,
        .reference = demo_entity.reference,
    }).encodeMessage(&request);
    request[11] &= 0xf0; // §7.7.8 also permits the prefix in a CREATE request.
    var agent: Agent = .{};
    var response: [128]u8 = undefined;
    const m = try agent.handleDatagram(request[0..n], &response);
    const status = try xrce.decodeStatusMessage(response[0..m]);
    try std.testing.expectEqual(xrce.StatusValue.ok, status.result.status);
    try std.testing.expectEqualSlices(u8, request[10..12], &status.related_request.object_id);
    try std.testing.expect(agent.policy.resource_table.lookup(demo_entity.object_id) != null);
}
