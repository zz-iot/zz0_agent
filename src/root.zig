const std = @import("std");
pub const xrce = @import("zz0_client").xrce;
pub const backend = @import("backend.zig");
pub const cli = @import("cli.zig");
pub const startup = @import("startup.zig");
pub const config = @import("config.zig");
pub const resources = @import("resources.zig");
pub const udp = @import("udp.zig");
pub const dds_backend = @import("dds_backend.zig");
pub const WriteLogMode = enum { none, summary, hex };
/// Synchronous acceptance observation; payload and definition are borrowed.
/// Fixture observation cannot change an already-accepted backend result.
pub const Observation = struct {
    client_key: [4]u8,
    write: xrce.DecodedWriteData,
    mode: WriteLogMode,
    hex_bytes: usize,
    total_writes: u64,
    definition: ?*const backend.Definition,
};
const NoFixture = struct {
    pub fn fresh(_: @This()) @This() {
        return .{};
    }
    pub fn create(_: *@This(), _: xrce.DecodedCreate) xrce.ResultStatus {
        return .{ .status = .err_unknown_reference };
    }
    pub fn validateWrite(_: *@This(), _: Observation) xrce.ResultStatus {
        return .{ .status = .err_unknown_reference };
    }
    pub fn observeAccepted(_: *@This(), _: Observation) bool {
        return false;
    }
};
pub const Agent = AgentWithPolicy(NoFixture);
/// Shared fake backend for test binaries only.
pub const test_support = if (@import("builtin").is_test) @import("test_support.zig") else struct {};
fn backendStatus(header: xrce.MessageHeader, request_id: xrce.RequestId, object_id: xrce.ObjectId, result: xrce.ResultStatus, output: []u8) !usize {
    return (xrce.Status{ .session_id = header.session_id, .stream_id = header.stream_id, .sequence_nr = header.sequence_nr, .request = .{ .request_id = request_id, .object_id = object_id }, .result = result }).encodeMessage(output);
}

/// Compile-time bridge for explicit sample/compatibility fixtures.
/// Policy supplies fresh(), create(), validateWrite() and observeAccepted().
/// fresh() preserves configuration and resets per-client mutable state.
/// Managed writes always use the backend; observation only supplies diagnostics.
pub fn AgentWithPolicy(comptime Policy: type) type {
    return struct {
        const Self = @This();
        /// Single-client injection; the UDP registry uses a backend factory.
        /// The caller owns this stable context through successful cleanup.
        backend_client: ?*backend.Client = null,
        handshake_encoding: xrce.HandshakeEncoding = .omg_1_0,
        client_key: [4]u8 = @splat(0),
        vendor_id: [2]u8 = xrce.vendor_id_zenzen,
        policy: Policy = .{},
        write_stats: resources.WriteStats = .{},
        write_log_mode: WriteLogMode = .none,
        stats_every: ?u64 = null,
        hex_bytes: usize = 32,

        pub fn handleDatagram(self: *Self, input: []const u8, output: []u8) !usize {
            const message = try xrce.decodeMessage(input);
            var iterator = message.submessages();
            if (self.backend_client != null) {
                var scan = message.submessages();
                _ = try scan.next();
                if (try scan.next() != null) return error.UnsupportedMultipleSubmessages;
            }

            while (try iterator.next()) |submessage| {
                switch (submessage.header.id) {
                    .create_client => {
                        const create = try xrce.decodeCreateClientWithEncoding(message.header, submessage, self.handshake_encoding);
                        return try (xrce.StatusAgent{
                            .session_id = create.session_id,
                            .sequence_nr = create.header.sequence_nr,
                            .vendor_id = self.vendor_id,
                            .handshake_encoding = self.handshake_encoding,
                        }).encodeMessage(output);
                    },
                    .create => {
                        const create = try xrce.decodeCreate(message.header, submessage);
                        if (self.backend_client) |client| {
                            if (output.len < xrce.Status.message_len) return error.BufferTooSmall;
                            const result = client.createWire(create);
                            return backendStatus(message.header, create.request_id, create.request_object_id, result, output);
                        }
                        const result = self.policy.create(create);
                        return backendStatus(message.header, create.request_id, create.request_object_id, result, output);
                    },
                    .write_data => {
                        const write = try xrce.decodeWriteData(message.header, submessage);
                        if (self.backend_client) |client| {
                            if (output.len < xrce.Status.message_len) return error.BufferTooSmall;
                            const result = client.write(write.object_id, write.serialized_data);
                            if (result.status == .ok) {
                                self.write_stats.record(write);
                                self.observeWrite(write);
                            }
                            return backendStatus(message.header, write.request_id, write.object_id, result, output);
                        }
                        const result = self.policy.validateWrite(self.observation(write));
                        if (result.status == .ok) {
                            self.write_stats.record(write);
                            self.observeWrite(write);
                        }
                        return backendStatus(message.header, write.request_id, write.object_id, result, output);
                    },
                    .delete => {
                        if (self.backend_client) |client| {
                            const request = try xrce.decodeDelete(message.header, submessage);
                            if (output.len < xrce.Status.message_len) return error.BufferTooSmall;
                            const result = if (std.mem.eql(u8, &request.object_id, &[_]u8{ 0xff, 0xfe })) blk: {
                                client.clear() catch |err| break :blk xrce.ResultStatus{ .status = backend.statusFor(err) };
                                break :blk xrce.ResultStatus{ .status = .ok };
                            } else client.delete(request.object_id);
                            return backendStatus(message.header, request.request_id, request.object_id, result, output);
                        }
                    },
                    .reset => {
                        if (self.backend_client) |client| {
                            _ = try xrce.decodeReset(message.header, submessage);
                            try client.clear();
                            return 0;
                        }
                    },
                    else => {},
                }
            }

            return error.NoSupportedSubmessage;
        }

        fn observation(self: *Self, write: xrce.DecodedWriteData) Observation {
            return .{ .client_key = self.client_key, .write = write, .mode = self.write_log_mode, .hex_bytes = self.hex_bytes, .total_writes = self.write_stats.total_writes, .definition = if (self.backend_client) |client| client.definitionFor(write.object_id) else null };
        }
        fn observeWrite(self: *Self, write: xrce.DecodedWriteData) void {
            const object_stats = self.write_stats.lookup(write.object_id);
            if (!self.policy.observeAccepted(self.observation(write))) switch (self.write_log_mode) {
                .none => {},
                .summary => std.debug.print("zz0_agent: client={x} WRITE_DATA object={x:0>2}{x:0>2} payload_len={d} total_writes={d}\n", .{ self.client_key, write.object_id[0], write.object_id[1], write.serialized_data.len, self.write_stats.total_writes }),
                .hex => std.debug.print("zz0_agent: client={x} WRITE_DATA object={x:0>2}{x:0>2} payload_len={d} hex={x}\n", .{ self.client_key, write.object_id[0], write.object_id[1], write.serialized_data.len, write.serialized_data[0..@min(write.serialized_data.len, self.hex_bytes)] }),
            };
            if (self.stats_every) |every| {
                if (every != 0 and self.write_stats.total_writes % every == 0) {
                    std.debug.print(
                        "zz0_agent: client={x} WRITE_STATS total_writes={d} total_bytes={d} object={x:0>2}{x:0>2} object_writes={d} object_bytes={d}\n",
                        .{
                            self.client_key,
                            self.write_stats.total_writes,
                            self.write_stats.total_bytes,
                            write.object_id[0],
                            write.object_id[1],
                            if (object_stats) |stats| stats.writes else 0,
                            if (object_stats) |stats| stats.bytes else 0,
                        },
                    );
                }
            }
        }
    };
}

test {
    _ = @import("core_test.zig");
    _ = @import("config_test.zig");
    _ = @import("cli_test.zig");
    _ = @import("udp_test.zig");
    _ = @import("backend_test.zig");
}
