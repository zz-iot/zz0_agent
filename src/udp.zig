const std = @import("std");
const root = @import("root.zig");
const zz0_client = @import("zz0_client");

const net = std.Io.net;

pub const UdpServer = struct {
    socket: net.Socket,
    agent: root.Agent,

    pub fn bind(io: std.Io, address: net.IpAddress, agent: root.Agent) !UdpServer {
        const socket = try address.bind(io, .{
            .mode = .dgram,
            .protocol = .udp,
        });
        return .{ .socket = socket, .agent = agent };
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
        const response_len = try self.agent.handleDatagram(incoming.data, &response);
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
