const std = @import("std");
const B = @import("backend.zig");
const xrce = @import("zz0_client").xrce;
const testing = std.testing;
pub const definitions = [_]B.Definition{
    .{ .name = "participant", .kind = .participant, .participant = "main", .resource = "main", .domain = 42 },
    .{ .name = "topic", .kind = .topic, .participant = "main", .resource = "reading", .parent = "participant", .topic_name = "Reading" },
    .{ .name = "publisher", .kind = .publisher, .participant = "main", .resource = "pub", .parent = "participant" },
    .{ .name = "writer", .kind = .datawriter, .participant = "main", .resource = "reading", .parent = "publisher", .topic = "topic" },
};
pub const catalog: B.Catalog = .{ .definitions = &definitions };
pub const participant: xrce.ObjectId = .{ 0, 0x11 };
pub const topic: xrce.ObjectId = .{ 0, 0x12 };
pub const publisher: xrce.ObjectId = .{ 0, 0x13 };
pub const writer: xrce.ObjectId = .{ 0, 0x15 };
pub const Fake = struct {
    next: usize = 0,
    live: [64]bool = @splat(false),
    create_calls: usize = 0,
    write_calls: usize = 0,
    fail_create: bool = false,
    fail_delete: bool = false,
    fail_clear: bool = false,
    dirty: bool = false,
    sample: [516]u8 = undefined,
    sample_len: usize = 0,
    reentrant: ?*B.Client = null,
    fn cast(ctx: *anyopaque) *@This() {
        return @ptrCast(@alignCast(ctx));
    }
    fn create(ctx: *anyopaque, _: *const B.Definition, parent: ?B.Handle, topic_: ?B.Handle) !B.Handle {
        const self = cast(ctx);
        self.create_calls += 1;
        if (self.reentrant) |owner| try testing.expectError(error.OperationInProgress, owner.clear());
        if (self.fail_create) return error.OutOfMemory;
        if (parent) |p| try testing.expect(self.live[p.slot]);
        if (topic_) |t| try testing.expect(self.live[t.slot]);
        const slot = self.next;
        self.next += 1;
        self.live[slot] = true;
        return .{ .slot = slot, .generation = 1 };
    }
    fn write(ctx: *anyopaque, handle: B.Handle, data: []const u8) !void {
        const self = cast(ctx);
        try testing.expect(self.live[handle.slot]);
        self.write_calls += 1;
        if (data.len != 8) return error.InvalidSample;
        self.sample_len = data.len;
        @memcpy(self.sample[0..data.len], data);
    }
    fn delete(ctx: *anyopaque, handle: B.Handle) !void {
        const self = cast(ctx);
        if (self.fail_delete) return error.CleanupFailed;
        try testing.expect(self.live[handle.slot]);
        self.live[handle.slot] = false;
    }
    fn clear(ctx: *anyopaque) !void {
        const self = cast(ctx);
        // Simulate partial backend cleanup before failure.
        self.live[0] = false;
        if (self.fail_clear) return error.CleanupFailed;
        self.live = @splat(false);
        self.dirty = false;
    }
    fn dirtyState(ctx: *anyopaque) bool {
        return cast(ctx).dirty;
    }
    pub const vtable: B.Backend.Vtable = .{ .create = create, .write = write, .delete = delete, .clear = clear, .needs_cleanup = dirtyState };
    pub fn backend(self: *@This()) B.Backend {
        return .{ .context = self, .vtable = &vtable };
    }
};
pub fn expect(status: xrce.StatusValue, result: xrce.ResultStatus) !void {
    try testing.expectEqual(status, result.status);
}
pub fn populate(client: *B.Client) !void {
    try expect(.ok, client.create(.{ .object_id = participant, .definition = "participant", .domain = 42 }));
    try expect(.ok, client.create(.{ .object_id = topic, .definition = "topic", .parent = participant }));
    try expect(.ok, client.create(.{ .object_id = publisher, .definition = "publisher", .parent = participant }));
    try expect(.ok, client.create(.{ .object_id = writer, .definition = "writer", .parent = publisher, .topic = topic }));
}
