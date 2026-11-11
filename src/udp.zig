const std = @import("std");
const root = @import("root.zig");
const net = std.Io.net;
pub const max_clients = 8;
pub const ClientSessions = Sessions(root.Agent);
pub const UdpServer = Server(root.Agent);
pub fn Sessions(comptime Agent: type) type {
    return struct {
        const Self = @This();
        const Client = struct {
            key: [4]u8,
            peer: net.IpAddress,
            session_id: u8,
            agent: Agent,
            closing: bool = false,
        };

        template: Agent = .{},
        backend_factory: ?root.backend.ClientFactory = null,
        clients: [max_clients]?Client = @splat(null),

        pub fn handleDatagram(self: *Self, peer: net.IpAddress, input: []const u8, output: []u8) !usize {
            if (self.template.backend_client != null) return error.BackendRequiresClientFactory;
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
                if (self.backend_factory) |factory| {
                    if (try iterator.next() != null) return error.UnsupportedMultipleSubmessages;
                    // Encode the response first: no cleanup/allocation on a short buffer.
                    var response_agent: Agent = .{ .handshake_encoding = self.template.handshake_encoding, .vendor_id = self.template.vendor_id };
                    const n = try response_agent.handleDatagram(input, output);
                    if (self.clients[index]) |*existing| {
                        if (existing.session_id == create.session_id) {
                            if (existing.closing) return error.ClientCleanupRequired;
                            existing.peer = peer;
                            return n; // Same session preserves graph, generation and counters.
                        }
                        try retire(factory, existing);
                        self.clients[index] = null;
                    }
                    const owner = try factory.open(factory.context, create.client_key, create.session_id);
                    self.clients[index] = .{ .key = create.client_key, .peer = peer, .session_id = create.session_id, .agent = .{
                        .backend_client = owner,
                        .policy = self.template.policy.fresh(),
                        .handshake_encoding = self.template.handshake_encoding,
                        .client_key = create.client_key,
                        .vendor_id = self.template.vendor_id,
                        .write_log_mode = self.template.write_log_mode,
                        .stats_every = self.template.stats_every,
                        .hex_bytes = self.template.hex_bytes,
                    } };
                    return n;
                }

                var agent = Agent{
                    .handshake_encoding = self.template.handshake_encoding,
                    .client_key = create.client_key,
                    .vendor_id = self.template.vendor_id,
                    .policy = self.template.policy.fresh(),
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
                        if (self.backend_factory) |factory| {
                            if (first.header.id == .delete) {
                                const request = try root.xrce.decodeDelete(message.header, first);
                                if (std.mem.eql(u8, &request.object_id, &[_]u8{ 0xff, 0xfe })) {
                                    if (try iterator.next() != null) return error.UnsupportedMultipleSubmessages;
                                    if (output.len < root.xrce.Status.message_len) return error.BufferTooSmall;
                                    retire(factory, client) catch |err| {
                                        return (root.xrce.Status{ .session_id = message.header.session_id, .stream_id = message.header.stream_id, .sequence_nr = message.header.sequence_nr, .request = .{ .request_id = request.request_id, .object_id = request.object_id }, .result = .{ .status = root.backend.statusFor(err) } }).encodeMessage(output);
                                    };
                                    slot.* = null;
                                    return (root.xrce.Status{ .session_id = message.header.session_id, .stream_id = message.header.stream_id, .sequence_nr = message.header.sequence_nr, .request = .{ .request_id = request.request_id, .object_id = request.object_id }, .result = .{ .status = .ok } }).encodeMessage(output);
                                }
                            }
                            if (client.closing and first.header.id == .reset) return error.ClientCleanupRequired;
                        }
                        return client.agent.handleDatagram(input, output);
                    }
                }
            }
            return error.UnknownClientSession;
        }
        fn retire(factory: root.backend.ClientFactory, client: *Client) !void {
            client.closing = true;
            factory.close(factory.context, client.agent.backend_client.?) catch |err| {
                const owner = client.agent.backend_client.?;
                owner.state = .cleanup_required;
                owner.last_error = err;
                if (owner.cleanup_cause == null) owner.cleanup_cause = err;
                return err;
            };
        }
        /// Retains the failed slot and all later slots if cleanup fails. Retry before
        /// releasing factory, provider preparation or allocators.
        pub fn close(self: *Self) !void {
            if (self.backend_factory) |factory| {
                for (&self.clients) |*slot| if (slot.*) |*client| {
                    try retire(factory, client);
                    slot.* = null;
                };
            } else self.clients = @splat(null);
        }
    };
}
pub fn Server(comptime Agent: type) type {
    return struct {
        const Self = @This();
        socket: net.Socket,
        sessions: Sessions(Agent),

        pub fn bind(io: std.Io, address: net.IpAddress, agent: Agent) !Self {
            if (agent.backend_client != null) return error.BackendRequiresClientFactory;
            const socket = try address.bind(io, .{
                .mode = .dgram,
                .protocol = .udp,
            });
            return .{ .socket = socket, .sessions = .{ .template = agent } };
        }

        pub fn bindBackend(io: std.Io, address: net.IpAddress, agent: Agent, factory: root.backend.ClientFactory) !Self {
            var server = try bind(io, address, agent);
            server.sessions.backend_factory = factory;
            return server;
        }
        pub fn close(self: *Self, io: std.Io) !void {
            try self.sessions.close();
            self.socket.close(io);
            self.* = undefined;
        }

        pub fn localAddress(self: *const Self) net.IpAddress {
            return self.socket.address;
        }

        pub fn serveOnce(self: *Self, io: std.Io, timeout: std.Io.Timeout) !void {
            var request: [512]u8 = undefined;
            const incoming = try self.socket.receiveTimeout(io, &request, timeout);

            var response: [512]u8 = undefined;
            const response_len = self.sessions.handleDatagram(incoming.from, incoming.data, &response) catch |err| {
                // A stale session after an agent restart or a malformed packet must
                // not terminate service for all the other clients.
                if (err != error.UnknownClientSession) std.log.warn("ignoring XRCE datagram from {f}: {s}", .{ incoming.from, @errorName(err) });
                return;
            };
            if (response_len != 0) try self.socket.send(io, &incoming.from, response[0..response_len]);
        }

        pub fn serveForever(self: *Self, io: std.Io) !void {
            while (true) {
                try self.serveOnce(io, .none);
            }
        }
    };
}
pub fn timeoutMillis(ms: i64) std.Io.Timeout {
    return .{ .duration = .{
        .clock = .awake,
        .raw = std.Io.Duration.fromMilliseconds(ms),
    } };
}
