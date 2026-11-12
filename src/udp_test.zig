const std = @import("std");
const root = @import("root.zig");
const zz0_client = @import("zz0_client");
const net = std.Io.net;
const UdpServer = root.udp.UdpServer;
const timeoutMillis = root.udp.timeoutMillis;
test "UDP server replies to CREATE_CLIENT with STATUS_AGENT" {
    const io = std.testing.io;
    const bind_address = net.IpAddress{ .ip4 = .loopback(0) };
    var server = try UdpServer.bind(io, bind_address, .{});
    defer server.close(io) catch @panic("server cleanup");

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
    defer server.close(io) catch @panic("server cleanup");

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

test "UDP service survives a malformed packet and registers two clients" {
    const old_level = std.testing.log_level;
    std.testing.log_level = .err; // malformed packet rejection is intentional
    defer std.testing.log_level = old_level;
    const io = std.testing.io;
    var server = try UdpServer.bind(io, .{ .ip4 = .loopback(0) }, .{});
    defer server.close(io) catch @panic("server cleanup");
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

test "UDP idle maintenance runs without datagrams and preserves caller timeout" {
    const io = std.testing.io;
    var server = try UdpServer.bind(io, .{ .ip4 = .loopback(0) }, .{});
    defer server.close(io) catch @panic("cleanup");
    server.sessions.idle_timeout = .fromMilliseconds(10);
    server.sessions.maintain(std.Io.Clock.awake.now(io).nanoseconds);
    var request: [64]u8 = undefined;
    var response: [64]u8 = undefined;
    const n = try (root.xrce.CreateClient{ .client_key = .{ 1, 2, 3, 4 }, .session_id = 0x81 }).encodeMessage(&request);
    _ = try server.sessions.handleDatagram(.{ .ip4 = .loopback(23400) }, request[0..n], &response);
    // Internal maintenance must neither return as a datagram nor extend the
    // caller's original deadline when it resumes receiving.
    try std.testing.expectError(error.Timeout, server.serveOnce(io, timeoutMillis(200)));
    try std.testing.expect(server.sessions.clients[0] == null);
}

test "UDP dispatch performs maintenance even when receive is already ready" {
    const io = std.testing.io;
    var server = try UdpServer.bind(io, .{ .ip4 = .loopback(0) }, .{});
    defer server.close(io) catch @panic("cleanup");
    server.sessions.idle_timeout = .fromMilliseconds(10);
    var request: [64]u8 = undefined;
    var response: [64]u8 = undefined;
    const n = try (root.xrce.CreateClient{ .client_key = .{ 1, 2, 3, 4 }, .session_id = 0x81 }).encodeMessage(&request);
    // An old timestamp makes this registration deterministically overdue.
    _ = try server.sessions.handleDatagram(.{ .ip4 = .loopback(23400) }, request[0..n], &response);
    const sender = try (net.IpAddress{ .ip4 = .loopback(0) }).bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer sender.close(io);
    const address = server.localAddress();
    try sender.send(io, &address, request[0..n]);
    try server.serveOnce(io, timeoutMillis(1000));
    _ = try sender.receiveTimeout(io, &response, timeoutMillis(1000));
    try std.testing.expect(net.IpAddress.eql(&server.sessions.clients[0].?.peer, &sender.address));
    try std.testing.expect(server.sessions.clients[0].?.last_activity > 0);
}
