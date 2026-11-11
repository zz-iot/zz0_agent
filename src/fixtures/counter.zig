const std = @import("std");
const core = @import("zz0_agent_core");
const resources = core.resources;
const ReferenceDefinition = resources.ReferenceDefinition;
const ReferenceCatalog = resources.ReferenceCatalog;
const xrce = core.xrce;
const demo = @import("zz0_client").demo;
const counter_types = @import("counter_types");
const zidl_rt = @import("zidl_rt");
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

pub const default_reference_entries = [_]ReferenceDefinition{
    .{
        .object_kind = .application,
        .reference = "DemoApp",
    },
    .{
        .object_kind = .application,
        .reference = "OtherApp",
    },
    .{
        .object_kind = .participant,
        .reference = "MyLibrary::MyParticipant",
        .participant_domain_id = 0,
    },
    .{
        .object_kind = demo.participant.object_kind,
        .reference = demo.participant.reference,
        .participant_domain_id = demo.participant.participant_domain_id,
    },
    .{
        .object_kind = demo.topic.object_kind,
        .reference = demo.topic.reference,
        .related_object_id = demo.topic.related_object_id,
    },
    .{
        .object_kind = demo.publisher.object_kind,
        .reference = demo.publisher.reference,
        .related_object_id = demo.publisher.related_object_id,
    },
    .{
        .object_kind = demo.datawriter.object_kind,
        .reference = demo.datawriter.reference,
        .related_object_id = demo.datawriter.related_object_id,
    },
};

pub const default_reference_catalog = ReferenceCatalog{
    .entries = &default_reference_entries,
};

pub const Policy = struct {
    reference_catalog: resources.ReferenceCatalog = default_reference_catalog,
    resource_table: resources.ResourceTable = .{},
    counter_status_stats: CounterStatusStats = .{},
    writer_definition: []const u8 = "MyLibrary::CounterStatusWriter",
    pub fn fresh(self: @This()) @This() {
        return .{ .reference_catalog = self.reference_catalog, .writer_definition = self.writer_definition };
    }
    pub fn create(self: *@This(), create_: xrce.DecodedCreate) xrce.ResultStatus {
        const result = self.reference_catalog.validateCreate(create_);
        if (result.status != .ok) return result;
        return self.resource_table.createByReference(create_, .{
            .reuse = create_.submessage.flags & xrce.flag_create_reuse != 0,
            .replace = create_.submessage.flags & xrce.flag_create_replace != 0,
        });
    }
    fn selected(self: *@This(), context: core.Observation) bool {
        if (context.definition) |definition| return std.mem.eql(u8, definition.name, self.writer_definition);
        return std.mem.eql(u8, &context.write.object_id, &demo.datawriter.object_id);
    }
    fn decode(write: xrce.DecodedWriteData) !counter_types.CounterStatus {
        var framed: [516]u8 = undefined;
        if (write.serialized_data.len > framed.len - 4) return error.PayloadTooLarge;
        @memcpy(framed[0..4], &[_]u8{ 0, 7, 0, 0 });
        @memcpy(framed[4..][0..write.serialized_data.len], write.serialized_data);
        var reader = try zidl_rt.CdrReader.init(framed[0 .. write.serialized_data.len + 4]);
        var sample: counter_types.CounterStatus = undefined;
        try counter_types.CounterStatus.deserializeInto(&sample, &reader, std.heap.page_allocator);
        if (reader.pos != reader.data.len) return error.TrailingSampleBytes;
        return sample;
    }
    fn invalid(self: *@This(), context: core.Observation, err: anyerror) void {
        self.counter_status_stats.invalid += 1;
        if (context.mode != .none) std.debug.print("zz0_agent: client={x} CounterStatus decode failed object={x:0>2}{x:0>2} payload_len={d} error={s}\n", .{ context.client_key, context.write.object_id[0], context.write.object_id[1], context.write.serialized_data.len, @errorName(err) });
    }
    pub fn validateWrite(self: *@This(), context: core.Observation) xrce.ResultStatus {
        const resource = self.resource_table.lookup(context.write.object_id) orelse return .{ .status = .err_unknown_reference };
        if (resource.object_kind != .datawriter) return .{ .status = .err_mismatch };
        if (self.selected(context)) _ = decode(context.write) catch |err| {
            self.invalid(context, err);
            return .{ .status = .err_invalid_data };
        };
        return .{ .status = .ok };
    }
    pub fn observeAccepted(self: *@This(), context: core.Observation) bool {
        if (!self.selected(context)) return false;
        const sample = decode(context.write) catch |err| {
            self.invalid(context, err);
            return false;
        };
        self.counter_status_stats.record(sample);
        const write = context.write;
        switch (context.mode) {
            .none => {},
            .summary => std.debug.print("zz0_agent: client={x} CounterStatus object={x:0>2}{x:0>2} counter={d} board={s} payload_len={d} total_writes={d}\n", .{ context.client_key, write.object_id[0], write.object_id[1], sample.counter, sample.board.slice(), sample.payload.slice().len, context.total_writes }),
            .hex => std.debug.print("zz0_agent: client={x} CounterStatus object={x:0>2}{x:0>2} counter={d} board={s} payload={x} cdr_hex={x}\n", .{ context.client_key, write.object_id[0], write.object_id[1], sample.counter, sample.board.slice(), sample.payload.slice(), write.serialized_data[0..@min(write.serialized_data.len, context.hex_bytes)] }),
        }
        return true;
    }
};
test "empty XML publisher compatibility respects configured catalog context" {
    var wire: [128]u8 = undefined;
    const n = try (xrce.CreateByReference{
        .session_id = 0x81,
        .sequence_nr = 0,
        .request_id = .{ 0, 1 },
        .object_prefix = demo.publisher.object_prefix,
        .object_kind = .publisher,
        .representation_format = .as_xml_string,
        .reference = "",
        .related_object_id = demo.participant.object_id,
    }).encodeMessage(&wire);
    const create = try xrce.decodeCreateMessage(wire[0..n]);
    try std.testing.expectEqual(xrce.StatusValue.ok, default_reference_catalog.validateCreate(create).status);
    const empty = ReferenceCatalog{ .entries = &.{} };
    try std.testing.expectEqual(xrce.StatusValue.err_unknown_reference, empty.validateCreate(create).status);
    var other_parent = create;
    other_parent.related_object_id = .{ 0x20, 0x11 };
    try std.testing.expectEqual(xrce.StatusValue.err_unknown_reference, default_reference_catalog.validateCreate(other_parent).status);
}
