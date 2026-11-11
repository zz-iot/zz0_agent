const std = @import("std");
const root = @import("../fixture_root.zig");
const zz0_client = @import("zz0_client");
const net = std.Io.net;
const ClientSessions = root.udp.ClientSessions;
const UdpServer = root.udp.UdpServer;
const max_clients = @import("zz0_agent_core").udp.max_clients;
const timeoutMillis = @import("zz0_agent_core").udp.timeoutMillis;
fn connectTestClient(sessions: *ClientSessions, peer: net.IpAddress, key: [4]u8) !void {
    var request: [root.xrce.CreateClient.message_len]u8 = undefined;
    const n = try (root.xrce.CreateClient{ .client_key = key, .session_id = 0x81 }).encodeMessage(&request);
    var response: [128]u8 = undefined;
    _ = try sessions.handleDatagram(peer, request[0..n], &response);
}

fn createTestPath(sessions: *ClientSessions, peer: net.IpAddress) !void {
    for (zz0_client.demo.publish_path_entities, 0..) |spec, i| {
        var request: [160]u8 = undefined;
        const n = try (root.xrce.CreateByReference{
            .session_id = 0x81,
            .sequence_nr = @intCast(i + 1),
            .request_id = .{ @intCast(i + 1), 0 },
            .object_prefix = spec.object_prefix,
            .object_kind = spec.object_kind,
            .reference = spec.reference,
            .participant_domain_id = spec.participant_domain_id orelse 0,
            .related_object_id = spec.related_object_id,
        }).encodeMessage(&request);
        var response: [128]u8 = undefined;
        const len = try sessions.handleDatagram(peer, request[0..n], &response);
        const status = try root.xrce.decodeStatusMessage(response[0..len]);
        try std.testing.expectEqual(root.xrce.StatusValue.ok, status.result.status);
    }
}

fn writeTestSample(sessions: *ClientSessions, peer: net.IpAddress, board: []const u8, counter: u32) !root.xrce.StatusValue {
    const rt = @import("zidl_rt");
    const Sample = @import("counter_types").CounterStatus;
    var storage: [256]u8 = undefined;
    var arena = std.heap.FixedBufferAllocator.init(&storage);
    // The wire sample has bounded fields; the arena is only the writer buffer.
    var bytes = std.ArrayListUnmanaged(u8).empty;
    var writer = rt.CdrWriter(.xcdr2).init(&bytes, arena.allocator());
    try Sample.serialize(&writer, .{
        .counter = counter,
        .board = try rt.BoundedArray(u8, 16).fromSlice(board),
        .payload = try rt.BoundedArray(u8, 8).fromSlice(&.{ 1, 2, 3, 4 }),
    });
    var request: [256]u8 = undefined;
    const n = try (root.xrce.WriteData{
        .session_id = 0x81,
        .sequence_nr = 10,
        .request_id = .{ 10, 0 },
        .object_id = zz0_client.demo.datawriter.object_id,
        .serialized_data = bytes.items,
    }).encodeMessage(&request);
    var response: [128]u8 = undefined;
    const len = try sessions.handleDatagram(peer, request[0..n], &response);
    return (try root.xrce.decodeStatusMessage(response[0..len])).result.status;
}

test "clients isolate identical object IDs, sample statistics and reconnects" {
    var sessions: ClientSessions = .{};
    const first = net.IpAddress{ .ip4 = .loopback(11001) };
    const second = net.IpAddress{ .ip4 = .loopback(11002) };
    const moved = net.IpAddress{ .ip4 = .loopback(11003) };
    const key1 = [4]u8{ 1, 2, 3, 4 };
    const key2 = [4]u8{ 5, 6, 7, 8 };
    try connectTestClient(&sessions, first, key1);
    try connectTestClient(&sessions, second, key2);
    try createTestPath(&sessions, first);
    try std.testing.expectEqual(root.xrce.StatusValue.ok, try writeTestSample(&sessions, first, "pico-wh", 1));
    try std.testing.expectEqual(root.xrce.StatusValue.err_unknown_reference, try writeTestSample(&sessions, second, "pico2-wh", 100));
    try createTestPath(&sessions, second);
    try std.testing.expectEqual(root.xrce.StatusValue.ok, try writeTestSample(&sessions, second, "pico2-wh", 100));
    try std.testing.expectEqual(root.xrce.StatusValue.ok, try writeTestSample(&sessions, first, "pico-wh", 2));
    try std.testing.expectEqual(@as(u32, 2), sessions.clients[0].?.agent.policy.counter_status_stats.last_counter);
    try std.testing.expectEqual(@as(u32, 100), sessions.clients[1].?.agent.policy.counter_status_stats.last_counter);
    try std.testing.expectEqualStrings("pico-wh", sessions.clients[0].?.agent.policy.counter_status_stats.lastBoard());
    try std.testing.expectEqualStrings("pico2-wh", sessions.clients[1].?.agent.policy.counter_status_stats.lastBoard());
    try std.testing.expectEqual(@as(u64, 2), sessions.clients[0].?.agent.write_stats.total_writes);
    try std.testing.expectEqual(@as(u64, 1), sessions.clients[1].?.agent.write_stats.total_writes);

    try connectTestClient(&sessions, moved, key1);
    try std.testing.expectEqual(@as(usize, 0), sessions.clients[0].?.agent.policy.resource_table.len);
    try std.testing.expectError(error.UnknownClientSession, writeTestSample(&sessions, first, "pico-wh", 3));
    try std.testing.expectEqual(root.xrce.StatusValue.ok, try writeTestSample(&sessions, second, "pico2-wh", 101));
    try createTestPath(&sessions, moved);
    try std.testing.expectEqual(root.xrce.StatusValue.ok, try writeTestSample(&sessions, moved, "pico-wh", 3));
}

test "client slots are bounded and registration failures preserve existing state" {
    var sessions: ClientSessions = .{};
    const peer = net.IpAddress{ .ip4 = .loopback(12000) };
    const key = [4]u8{ 1, 0, 0, 1 };
    try connectTestClient(&sessions, peer, key);
    try createTestPath(&sessions, peer);
    try std.testing.expectError(error.SessionEndpointInUse, connectTestClient(&sessions, peer, .{ 9, 0, 0, 9 }));
    var request: [root.xrce.CreateClient.message_len]u8 = undefined;
    const n = try (root.xrce.CreateClient{ .client_key = key, .session_id = 0x81 }).encodeMessage(&request);
    var short_response: [1]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, sessions.handleDatagram(peer, request[0..n], &short_response));
    try std.testing.expectEqual(@as(usize, 4), sessions.clients[0].?.agent.policy.resource_table.len);
    try std.testing.expectError(error.InvalidClientKey, connectTestClient(&sessions, .{ .ip4 = .loopback(12999) }, @splat(0)));
    for (1..max_clients) |i| try connectTestClient(&sessions, .{ .ip4 = .loopback(@intCast(12000 + i)) }, .{ 1, 0, 0, @intCast(i + 1) });
    try std.testing.expectError(error.ClientCapacityExceeded, connectTestClient(&sessions, .{ .ip4 = .loopback(13000) }, .{ 9, 9, 9, 9 }));
    try std.testing.expectEqual(root.xrce.StatusValue.ok, try writeTestSample(&sessions, peer, "pico-wh", 7));
    try connectTestClient(&sessions, .{ .ip4 = .loopback(14000) }, key);
    try std.testing.expect(sessions.clients[max_clients - 1] != null);
}
