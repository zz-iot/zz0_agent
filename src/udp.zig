const std = @import("std");
const root = @import("root.zig");
const zz0_client = @import("zz0_client");

const net = std.Io.net;

/// Bounded demo session registry. Object IDs and counters belong to a client,
/// while keyless XRCE messages are routed by their UDP peer and session ID.
pub const max_clients = 8;
pub const ClientSessions = struct {
    const Client = struct {
        key: [4]u8,
        peer: net.IpAddress,
        session_id: u8,
        agent: root.Agent,
    };

    template: root.Agent = .{},
    clients: [max_clients]?Client = @splat(null),

    pub fn handleDatagram(self: *ClientSessions, peer: net.IpAddress, input: []const u8, output: []u8) !usize {
        const message = try root.xrce.decodeMessage(input);
        var iterator = message.submessages();
        const first = (try iterator.next()) orelse return error.NoSupportedSubmessage;
        if (first.header.id == .create_client) {
            const create = try root.xrce.decodeCreateClientWithEncoding(message.header, first, self.template.handshake_encoding);
            if (create.session_id <= root.xrce.session_id_none_without_client_key) return error.UnsupportedSession;
            if (std.mem.eql(u8, &create.client_key, &@as([4]u8, @splat(0)))) return error.InvalidClientKey;

            var chosen: ?usize = null;
            var free: ?usize = null;
            for (&self.clients, 0..) |*slot, i| {
                if (slot.*) |*client| {
                    if (std.mem.eql(u8, &client.key, &create.client_key)) chosen = i;
                    if (net.IpAddress.eql(&client.peer, &peer) and client.session_id == create.session_id and
                        !std.mem.eql(u8, &client.key, &create.client_key)) return error.SessionEndpointInUse;
                } else if (free == null) free = i;
            }
            const index = chosen orelse free orelse return error.ClientCapacityExceeded;
            var agent = root.Agent{
                .handshake_encoding = self.template.handshake_encoding,
                .client_key = create.client_key,
                .vendor_id = self.template.vendor_id,
                .reference_catalog = self.template.reference_catalog,
                .write_log_mode = self.template.write_log_mode,
                .stats_every = self.template.stats_every,
                .hex_bytes = self.template.hex_bytes,
            };
            const n = try agent.handleDatagram(input, output);
            self.clients[index] = .{
                .key = create.client_key,
                .peer = peer,
                .session_id = create.session_id,
                .agent = agent,
            };
            if (agent.write_log_mode != .none) std.debug.print("zz0_agent: client={x} session=0x{x} peer={f} connected\n", .{ create.client_key, create.session_id, peer });
            return n;
        }
        for (&self.clients) |*slot| {
            if (slot.*) |*client| {
                if (client.session_id == message.header.session_id and net.IpAddress.eql(&client.peer, &peer)) {
                    return client.agent.handleDatagram(input, output);
                }
            }
        }
        return error.UnknownClientSession;
    }
};

pub const UdpServer = struct {
    socket: net.Socket,
    sessions: ClientSessions,

    pub fn bind(io: std.Io, address: net.IpAddress, agent: root.Agent) !UdpServer {
        const socket = try address.bind(io, .{
            .mode = .dgram,
            .protocol = .udp,
        });
        return .{ .socket = socket, .sessions = .{ .template = agent } };
    }

    pub fn close(self: *UdpServer, io: std.Io) void {
        self.socket.close(io);
        self.* = undefined;
    }

    pub fn localAddress(self: *const UdpServer) net.IpAddress {
        return self.socket.address;
    }

    pub fn serveOnce(self: *UdpServer, io: std.Io, timeout: std.Io.Timeout) !void {
        var request: [512]u8 = undefined;
        const incoming = try self.socket.receiveTimeout(io, &request, timeout);

        var response: [512]u8 = undefined;
        const response_len = self.sessions.handleDatagram(incoming.from, incoming.data, &response) catch |err| {
            // A stale session after an agent restart or a malformed packet must
            // not terminate service for all the other clients.
            if (err != error.UnknownClientSession) std.log.warn("ignoring XRCE datagram from {f}: {s}", .{ incoming.from, @errorName(err) });
            return;
        };
        try self.socket.send(io, &incoming.from, response[0..response_len]);
    }

    pub fn serveForever(self: *UdpServer, io: std.Io) !void {
        while (true) {
            try self.serveOnce(io, .none);
        }
    }
};

pub fn timeoutMillis(ms: i64) std.Io.Timeout {
    return .{ .duration = .{
        .clock = .awake,
        .raw = std.Io.Duration.fromMilliseconds(ms),
    } };
}

test "UDP server replies to CREATE_CLIENT with STATUS_AGENT" {
    const io = std.testing.io;
    const bind_address = net.IpAddress{ .ip4 = .loopback(0) };
    var server = try UdpServer.bind(io, bind_address, .{});
    defer server.close(io);

    const ServerTask = struct {
        server: *UdpServer,
        result: anyerror!void = {},

        fn run(self: *@This()) void {
            self.result = self.server.serveOnce(std.testing.io, timeoutMillis(1000));
        }
    };

    var task = ServerTask{ .server = &server };
    var server_thread = try std.Thread.spawn(.{}, ServerTask.run, .{&task});

    const client_bind_address = net.IpAddress{ .ip4 = .loopback(0) };
    const client = try client_bind_address.bind(io, .{
        .mode = .dgram,
        .protocol = .udp,
    });
    defer client.close(io);

    var request: [root.xrce.CreateClient.message_len]u8 = undefined;
    const request_len = try (root.xrce.CreateClient{
        .client_key = .{ 0xaa, 0xbb, 0xcc, 0xdd },
        .session_id = 0x81,
        .sequence_nr = 13,
    }).encodeMessage(&request);

    const server_address = server.localAddress();
    try client.send(io, &server_address, request[0..request_len]);

    var response: [root.xrce.StatusAgent.message_len + 32]u8 = undefined;
    const incoming = try client.receiveTimeout(io, &response, timeoutMillis(1000));
    const status = try root.xrce.decodeStatusAgentMessage(incoming.data);

    server_thread.join();
    try task.result;

    try std.testing.expectEqual(@as(u8, 0x81), status.header.session_id);
    try std.testing.expectEqual(@as(u16, 13), status.header.sequence_nr);
    try std.testing.expectEqualSlices(u8, &root.xrce.vendor_id_zenzen, &status.vendor_id);
}

test "UDP server exchanges CREATE_CLIENT with zero-client session" {
    const io = std.testing.io;
    const bind_address = net.IpAddress{ .ip4 = .loopback(0) };
    var server = try UdpServer.bind(io, bind_address, .{});
    defer server.close(io);

    const ServerTask = struct {
        server: *UdpServer,
        result: anyerror!void = {},

        fn run(self: *@This()) void {
            self.result = self.server.serveOnce(std.testing.io, timeoutMillis(1000));
        }
    };

    var task = ServerTask{ .server = &server };
    var server_thread = try std.Thread.spawn(.{}, ServerTask.run, .{&task});

    const client_bind_address = net.IpAddress{ .ip4 = .loopback(0) };
    const socket = try client_bind_address.bind(io, .{
        .mode = .dgram,
        .protocol = .udp,
    });
    defer socket.close(io);

    var session = zz0_client.session.ClientSession.init(.{
        .client_key = .{ 0x5a, 0x45, 0x52, 0x4f },
        .session_id = 0x81,
        .initial_sequence_nr = 21,
    });

    var request: [root.xrce.CreateClient.message_len]u8 = undefined;
    const request_bytes = try session.encodeCreateClient(&request);

    const server_address = server.localAddress();
    try socket.send(io, &server_address, request_bytes);

    var response: [root.xrce.StatusAgent.message_len + 32]u8 = undefined;
    const incoming = try socket.receiveTimeout(io, &response, timeoutMillis(1000));
    const event = try session.handleDatagram(incoming.data);

    server_thread.join();
    try task.result;

    switch (event) {
        .status_agent => |status| {
            try std.testing.expectEqual(@as(u8, 0x81), status.header.session_id);
            try std.testing.expectEqual(@as(u16, 21), status.header.sequence_nr);
        },
        else => return error.ExpectedStatusAgent,
    }
    try std.testing.expectEqual(zz0_client.session.ClientSession.State.connected, session.state);
}

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
    try std.testing.expectEqual(@as(u32, 2), sessions.clients[0].?.agent.counter_status_stats.last_counter);
    try std.testing.expectEqual(@as(u32, 100), sessions.clients[1].?.agent.counter_status_stats.last_counter);
    try std.testing.expectEqualStrings("pico-wh", sessions.clients[0].?.agent.counter_status_stats.lastBoard());
    try std.testing.expectEqualStrings("pico2-wh", sessions.clients[1].?.agent.counter_status_stats.lastBoard());
    try std.testing.expectEqual(@as(u64, 2), sessions.clients[0].?.agent.write_stats.total_writes);
    try std.testing.expectEqual(@as(u64, 1), sessions.clients[1].?.agent.write_stats.total_writes);

    try connectTestClient(&sessions, moved, key1);
    try std.testing.expectEqual(@as(usize, 0), sessions.clients[0].?.agent.resource_table.len);
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
    try std.testing.expectEqual(@as(usize, 4), sessions.clients[0].?.agent.resource_table.len);
    try std.testing.expectError(error.InvalidClientKey, connectTestClient(&sessions, .{ .ip4 = .loopback(12999) }, @splat(0)));
    for (1..max_clients) |i| try connectTestClient(&sessions, .{ .ip4 = .loopback(@intCast(12000 + i)) }, .{ 1, 0, 0, @intCast(i + 1) });
    try std.testing.expectError(error.ClientCapacityExceeded, connectTestClient(&sessions, .{ .ip4 = .loopback(13000) }, .{ 9, 9, 9, 9 }));
    try std.testing.expectEqual(root.xrce.StatusValue.ok, try writeTestSample(&sessions, peer, "pico-wh", 7));
    try connectTestClient(&sessions, .{ .ip4 = .loopback(14000) }, key);
    try std.testing.expect(sessions.clients[max_clients - 1] != null);
}

test "UDP service survives a malformed packet and registers two clients" {
    const old_level = std.testing.log_level;
    std.testing.log_level = .err; // malformed packet rejection is intentional
    defer std.testing.log_level = old_level;
    const io = std.testing.io;
    var server = try UdpServer.bind(io, .{ .ip4 = .loopback(0) }, .{});
    defer server.close(io);
    const local: net.IpAddress = .{ .ip4 = .loopback(0) };
    const first = try local.bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer first.close(io);
    const second = try local.bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer second.close(io);
    const Task = struct {
        server: *UdpServer,
        result: anyerror!void = {},
        fn run(self: *@This()) void {
            self.result = self.serve();
        }
        fn serve(self: *@This()) !void {
            for (0..3) |_| try self.server.serveOnce(std.testing.io, timeoutMillis(1000));
        }
    };
    var task = Task{ .server = &server };
    {
        const thread = try std.Thread.spawn(.{}, Task.run, .{&task});
        defer thread.join();
        const address = server.localAddress();
        try first.send(io, &address, "bad");
        for ([_]net.Socket{ first, second }, 0..) |socket, i| {
            var request: [root.xrce.CreateClient.message_len]u8 = undefined;
            const n = try (root.xrce.CreateClient{ .client_key = .{ 1, 0, 0, @intCast(i + 1) }, .session_id = 0x81 }).encodeMessage(&request);
            try socket.send(io, &address, request[0..n]);
            var response: [128]u8 = undefined;
            const incoming = try socket.receiveTimeout(io, &response, timeoutMillis(1000));
            const status = try root.xrce.decodeStatusAgentMessage(incoming.data);
            try std.testing.expectEqual(@as(u8, 0x81), status.header.session_id);
        }
    }
    try task.result;
    try std.testing.expect(server.sessions.clients[0] != null);
    try std.testing.expect(server.sessions.clients[1] != null);
    try std.testing.expect(!net.IpAddress.eql(&server.sessions.clients[0].?.peer, &server.sessions.clients[1].?.peer));
}
