const std = @import("std");
const zz0_client = @import("zz0_client");
const zidl_rt = @import("zidl_rt");
const counter_types = @import("counter_types");

pub const xrce = zz0_client.xrce;
const demo = zz0_client.demo;
pub const resources = @import("resources.zig");
pub const udp = @import("udp.zig");

pub const WriteLogMode = enum {
    none,
    summary,
    hex,
};

pub const CounterStatusStats = struct {
    decoded: u64 = 0,
    invalid: u64 = 0,
    last_counter: u32 = 0,
    last_board_buf: [16]u8 = @splat(0),
    last_board_len: usize = 0,
    last_payload_buf: [8]u8 = @splat(0),
    last_payload_len: usize = 0,

    pub fn lastBoard(self: *const CounterStatusStats) []const u8 {
        return self.last_board_buf[0..self.last_board_len];
    }

    pub fn lastPayload(self: *const CounterStatusStats) []const u8 {
        return self.last_payload_buf[0..self.last_payload_len];
    }

    fn record(self: *CounterStatusStats, sample: counter_types.CounterStatus) void {
        const board = sample.board.slice();
        const payload = sample.payload.slice();

        self.decoded += 1;
        self.last_counter = sample.counter;
        @memcpy(self.last_board_buf[0..board.len], board);
        self.last_board_len = board.len;
        @memcpy(self.last_payload_buf[0..payload.len], payload);
        self.last_payload_len = payload.len;
    }
};

pub const Agent = struct {
    vendor_id: [2]u8 = xrce.vendor_id_zenzen,
    reference_catalog: resources.ReferenceCatalog = resources.default_reference_catalog,
    resource_table: resources.ResourceTable = .{},
    write_stats: resources.WriteStats = .{},
    counter_status_stats: CounterStatusStats = .{},
    write_log_mode: WriteLogMode = .none,
    stats_every: ?u64 = null,
    hex_bytes: usize = 32,

    pub fn handleDatagram(self: *Agent, input: []const u8, output: []u8) !usize {
        const message = try xrce.decodeMessage(input);
        var iterator = message.submessages();

        while (try iterator.next()) |submessage| {
            switch (submessage.header.id) {
                .create_client => {
                    const create = try xrce.decodeCreateClient(message.header, submessage);
                    return try (xrce.StatusAgent{
                        .session_id = create.session_id,
                        .sequence_nr = create.header.sequence_nr,
                        .vendor_id = self.vendor_id,
                    }).encodeMessage(output);
                },
                .create => {
                    const create = try xrce.decodeCreate(message.header, submessage);
                    const validation = self.reference_catalog.validateCreate(create);
                    const result = if (validation.status == .ok)
                        self.resource_table.createByReference(create, .{
                            .reuse = (submessage.header.flags & xrce.flag_create_reuse) != 0,
                            .replace = (submessage.header.flags & xrce.flag_create_replace) != 0,
                        })
                    else
                        validation;
                    return try (xrce.Status{
                        .session_id = message.header.session_id,
                        .stream_id = message.header.stream_id,
                        .sequence_nr = message.header.sequence_nr,
                        .request = .{
                            .request_id = create.request_id,
                            .object_id = create.object_id,
                        },
                        .result = result,
                    }).encodeMessage(output);
                },
                .write_data => {
                    const write = try xrce.decodeWriteData(message.header, submessage);
                    const resource = self.resource_table.lookup(write.object_id) orelse {
                        return try (xrce.Status{
                            .session_id = message.header.session_id,
                            .stream_id = message.header.stream_id,
                            .sequence_nr = message.header.sequence_nr,
                            .request = .{
                                .request_id = write.request_id,
                                .object_id = write.object_id,
                            },
                            .result = .{ .status = .err_unknown_reference },
                        }).encodeMessage(output);
                    };

                    const result = if (resource.object_kind != .datawriter)
                        xrce.ResultStatus{ .status = .err_mismatch }
                    else blk: {
                        const counter_status = self.decodeCounterStatusWrite(write) catch |err| {
                            self.counter_status_stats.invalid += 1;
                            self.observeInvalidCounterStatus(write, err);
                            break :blk xrce.ResultStatus{ .status = .err_invalid_data };
                        };
                        self.write_stats.record(write);
                        self.observeWrite(write, counter_status);
                        break :blk xrce.ResultStatus{ .status = .ok };
                    };

                    return try (xrce.Status{
                        .session_id = message.header.session_id,
                        .stream_id = message.header.stream_id,
                        .sequence_nr = message.header.sequence_nr,
                        .request = .{
                            .request_id = write.request_id,
                            .object_id = write.object_id,
                        },
                        .result = result,
                    }).encodeMessage(output);
                },
                else => {},
            }
        }

        return error.NoSupportedSubmessage;
    }

    fn decodeCounterStatusWrite(
        self: *Agent,
        write: xrce.DecodedWriteData,
    ) !?counter_types.CounterStatus {
        if (!std.mem.eql(u8, &write.object_id, &demo.datawriter.object_id)) return null;

        var reader = try zidl_rt.CdrReader.init(write.serialized_data);
        var sample: counter_types.CounterStatus = undefined;
        try counter_types.CounterStatus.deserializeInto(&sample, &reader, std.heap.page_allocator);
        self.counter_status_stats.record(sample);
        return sample;
    }

    fn observeWrite(self: *Agent, write: xrce.DecodedWriteData, counter_status: ?counter_types.CounterStatus) void {
        const object_stats = self.write_stats.lookup(write.object_id);

        switch (self.write_log_mode) {
            .none => {},
            .summary => {
                if (counter_status) |sample| {
                    std.debug.print(
                        "zz0_agent: CounterStatus object={x:0>2}{x:0>2} counter={d} board={s} payload_len={d} total_writes={d}\n",
                        .{
                            write.object_id[0],
                            write.object_id[1],
                            sample.counter,
                            sample.board.slice(),
                            sample.payload.slice().len,
                            self.write_stats.total_writes,
                        },
                    );
                } else {
                    std.debug.print(
                        "zz0_agent: WRITE_DATA object={x:0>2}{x:0>2} payload_len={d} total_writes={d}\n",
                        .{
                            write.object_id[0],
                            write.object_id[1],
                            write.serialized_data.len,
                            self.write_stats.total_writes,
                        },
                    );
                }
            },
            .hex => {
                const limit = @min(write.serialized_data.len, self.hex_bytes);
                if (counter_status) |sample| {
                    std.debug.print(
                        "zz0_agent: CounterStatus object={x:0>2}{x:0>2} counter={d} board={s} payload={x} cdr_hex={x}\n",
                        .{
                            write.object_id[0],
                            write.object_id[1],
                            sample.counter,
                            sample.board.slice(),
                            sample.payload.slice(),
                            write.serialized_data[0..limit],
                        },
                    );
                } else {
                    std.debug.print(
                        "zz0_agent: WRITE_DATA object={x:0>2}{x:0>2} payload_len={d} hex={x}\n",
                        .{
                            write.object_id[0],
                            write.object_id[1],
                            write.serialized_data.len,
                            write.serialized_data[0..limit],
                        },
                    );
                }
            },
        }

        if (self.stats_every) |every| {
            if (every != 0 and self.write_stats.total_writes % every == 0) {
                std.debug.print(
                    "zz0_agent: WRITE_STATS total_writes={d} total_bytes={d} object={x:0>2}{x:0>2} object_writes={d} object_bytes={d}\n",
                    .{
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

    fn observeInvalidCounterStatus(self: *Agent, write: xrce.DecodedWriteData, err: anyerror) void {
        if (self.write_log_mode == .none) return;
        std.debug.print(
            "zz0_agent: CounterStatus decode failed object={x:0>2}{x:0>2} payload_len={d} error={s}\n",
            .{
                write.object_id[0],
                write.object_id[1],
                write.serialized_data.len,
                @errorName(err),
            },
        );
    }
};

fn expectAgentDatagram(agent: *Agent, input: []const u8, output: []u8) !usize {
    return agent.handleDatagram(input, output);
}

test "agent replies to CREATE_CLIENT with STATUS_AGENT" {
    var agent = Agent{};
    var request: [xrce.CreateClient.message_len]u8 = undefined;
    _ = try (xrce.CreateClient{
        .client_key = .{ 0xaa, 0xbb, 0xcc, 0xdd },
        .session_id = 0x81,
        .sequence_nr = 7,
    }).encodeMessage(&request);

    var response: [xrce.StatusAgent.message_len]u8 = undefined;
    const n = try expectAgentDatagram(&agent, &request, &response);
    try std.testing.expectEqual(@as(usize, xrce.StatusAgent.message_len), n);

    const status = try xrce.decodeStatusAgentMessage(response[0..n]);
    try std.testing.expectEqual(@as(u8, 0x81), status.header.session_id);
    try std.testing.expectEqual(@as(u16, 7), status.header.sequence_nr);
}

test "agent dispatches CREATE_CLIENT after another known submessage" {
    var agent = Agent{};
    var create: [xrce.CreateClient.message_len]u8 = undefined;
    _ = try (xrce.CreateClient{
        .client_key = .{ 0xaa, 0xbb, 0xcc, 0xdd },
        .session_id = 0x81,
        .sequence_nr = 11,
    }).encodeMessage(&create);

    var request: [xrce.MessageHeader.encoded_len + xrce.SubmessageHeader.encoded_len + (xrce.SubmessageHeader.encoded_len + xrce.CreateClient.payload_len)]u8 = undefined;
    @memcpy(request[0..xrce.MessageHeader.encoded_len], create[0..xrce.MessageHeader.encoded_len]);
    try (xrce.SubmessageHeader{
        .id = .timestamp,
        .flags = xrce.flag_little_endian,
        .length = 0,
    }).encode(request[4..8]);
    @memcpy(request[8..], create[4..]);

    var response: [xrce.StatusAgent.message_len]u8 = undefined;
    const n = try expectAgentDatagram(&agent, &request, &response);
    const status = try xrce.decodeStatusAgentMessage(response[0..n]);
    try std.testing.expectEqual(@as(u8, 0x81), status.header.session_id);
    try std.testing.expectEqual(@as(u16, 11), status.header.sequence_nr);
}

test "agent rejects datagram without a supported submessage" {
    var agent = Agent{};
    var request: [xrce.CreateClient.message_len]u8 = undefined;
    _ = try (xrce.CreateClient{
        .client_key = .{ 0xaa, 0xbb, 0xcc, 0xdd },
        .session_id = 0x81,
    }).encodeMessage(&request);
    request[4] = @backingInt(xrce.SubmessageId.status);
    request[6] = 0;
    request[7] = 0;

    var response: [xrce.StatusAgent.message_len]u8 = undefined;
    try std.testing.expectError(error.NoSupportedSubmessage, expectAgentDatagram(&agent, request[0..8], &response));
}

test "agent rejects truncated submessage payload" {
    var agent = Agent{};
    var request: [xrce.MessageHeader.encoded_len + xrce.SubmessageHeader.encoded_len + 1]u8 = undefined;
    try (xrce.MessageHeader{
        .session_id = xrce.session_id_none_without_client_key,
        .stream_id = xrce.stream_id_none,
        .sequence_nr = 1,
    }).encode(request[0..4]);
    try (xrce.SubmessageHeader{
        .id = .create_client,
        .flags = xrce.flag_little_endian,
        .length = xrce.CreateClient.payload_len,
    }).encode(request[4..8]);
    request[8] = 0;

    var response: [xrce.StatusAgent.message_len]u8 = undefined;
    try std.testing.expectError(error.TruncatedSubmessage, expectAgentDatagram(&agent, &request, &response));
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

    const saved = agent.resource_table.lookup(.{ 0xdd, 0xdc }) orelse return error.ExpectedResource;
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
    try std.testing.expectEqual(@as(usize, 0), agent.resource_table.len);
}

test "agent accepts CREATE by-reference from configured catalog" {
    const entries = [_]resources.ReferenceDefinition{
        .{
            .object_kind = .application,
            .reference = "CustomApp",
        },
    };
    var agent = Agent{
        .reference_catalog = .{ .entries = &entries },
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
    try std.testing.expectEqual(@as(usize, 1), agent.resource_table.len);
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
    try std.testing.expectEqual(@as(usize, 0), agent.resource_table.len);
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
    try std.testing.expectEqual(@as(usize, 1), agent.resource_table.len);
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
    try std.testing.expectEqual(@as(usize, 1), agent.resource_table.len);
    const saved = agent.resource_table.lookup(.{ 0xdd, 0xdc }) orelse return error.ExpectedResource;
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
    try std.testing.expectEqual(@as(usize, 1), agent.resource_table.len);
    const saved = agent.resource_table.lookup(.{ 0xdd, 0xdc }) orelse return error.ExpectedResource;
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
    try std.testing.expectEqual(@as(u64, 1), agent.counter_status_stats.decoded);
    try std.testing.expectEqual(@as(u32, 42), agent.counter_status_stats.last_counter);
    try std.testing.expectEqualSlices(u8, "agent-test", agent.counter_status_stats.lastBoard());
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, agent.counter_status_stats.lastPayload());
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
    try std.testing.expectEqual(@as(u64, 0), agent.counter_status_stats.decoded);
    try std.testing.expectEqual(@as(u64, 1), agent.counter_status_stats.invalid);
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
    try std.testing.expectEqual(@as(u64, 128), agent.counter_status_stats.decoded);
    try std.testing.expectEqual(@as(u32, 127), agent.counter_status_stats.last_counter);
}

fn encodeCounterStatusForTest(out: []u8, sample: counter_types.CounterStatus) ![]const u8 {
    const allocator = std.testing.allocator;
    var bytes = std.ArrayListUnmanaged(u8).empty;
    defer bytes.deinit(allocator);

    var writer = zidl_rt.CdrWriter(.xcdr1).init(&bytes, allocator);
    try writer.writeEncapHeader();
    try counter_types.CounterStatus.serialize(&writer, sample);
    if (bytes.items.len > out.len) return error.BufferTooSmall;
    @memcpy(out[0..bytes.items.len], bytes.items);
    return out[0..bytes.items.len];
}
