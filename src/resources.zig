const std = @import("std");
const zz0_client = @import("zz0_client");

const xrce = zz0_client.xrce;
const demo = zz0_client.demo;

pub const max_resources = 32;
pub const max_reference_len = 128;
pub const max_write_objects = max_resources;

pub const ReferenceDefinition = struct {
    object_kind: xrce.ObjectKind,
    reference: []const u8,
    participant_domain_id: ?i16 = null,
    related_object_id: ?xrce.ObjectId = null,

    fn matchesContext(self: ReferenceDefinition, create: xrce.DecodedCreate) bool {
        if (self.participant_domain_id) |expected| {
            if (create.participant_domain_id == null or create.participant_domain_id.? != expected) return false;
        }

        if (self.related_object_id) |expected| {
            if (create.related_object_id == null or !std.mem.eql(u8, &expected, &create.related_object_id.?)) return false;
        }

        return true;
    }
};

pub const ReferenceCatalog = struct {
    entries: []const ReferenceDefinition,

    pub fn validateCreate(self: ReferenceCatalog, create: xrce.DecodedCreate) xrce.ResultStatus {
        if (create.representation_format != .by_reference) {
            return .{ .status = .err_invalid_data };
        }

        const definition = self.find(create) orelse return .{ .status = .err_unknown_reference };
        if (!definition.matchesContext(create)) return .{ .status = .err_mismatch };
        return .{ .status = .ok };
    }

    fn find(self: ReferenceCatalog, create: xrce.DecodedCreate) ?ReferenceDefinition {
        for (self.entries) |entry| {
            if (entry.object_kind != create.object_kind) continue;
            if (!std.mem.eql(u8, entry.reference, create.reference)) continue;
            return entry;
        }
        return null;
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

pub const CreateMode = struct {
    reuse: bool,
    replace: bool,
};

pub const Resource = struct {
    occupied: bool = false,
    object_id: xrce.ObjectId = .{ 0, 0 },
    object_kind: xrce.ObjectKind = .invalid,
    representation_format: xrce.RepresentationFormat = .by_reference,
    reference_buf: [max_reference_len]u8 = undefined,
    reference_len: usize = 0,
    participant_domain_id: ?i16 = null,
    related_object_id: ?xrce.ObjectId = null,

    pub fn reference(self: *const Resource) []const u8 {
        return self.reference_buf[0..self.reference_len];
    }

    fn matchesCreate(self: *const Resource, create: xrce.DecodedCreate) bool {
        if (self.object_kind != create.object_kind) return false;
        if (self.representation_format != create.representation_format) return false;
        if (!std.mem.eql(u8, self.reference(), create.reference)) return false;
        if (!optionalI16Eql(self.participant_domain_id, create.participant_domain_id)) return false;
        if (!optionalObjectIdEql(self.related_object_id, create.related_object_id)) return false;
        return true;
    }

    fn storeCreate(self: *Resource, create: xrce.DecodedCreate) xrce.ResultStatus {
        if (create.reference.len > max_reference_len) {
            return .{ .status = .err_invalid_data };
        }

        self.occupied = true;
        self.object_id = create.object_id;
        self.object_kind = create.object_kind;
        self.representation_format = create.representation_format;
        @memcpy(self.reference_buf[0..create.reference.len], create.reference);
        self.reference_len = create.reference.len;
        self.participant_domain_id = create.participant_domain_id;
        self.related_object_id = create.related_object_id;
        return .{ .status = .ok };
    }
};

pub const ResourceTable = struct {
    entries: [max_resources]Resource = @splat(.{}),
    len: usize = 0,

    pub fn createByReference(
        self: *ResourceTable,
        create: xrce.DecodedCreate,
        mode: CreateMode,
    ) xrce.ResultStatus {
        if (create.representation_format != .by_reference) {
            return .{ .status = .err_invalid_data };
        }

        if (self.findIndex(create.object_id)) |index| {
            const existing = &self.entries[index];
            if (existing.matchesCreate(create)) {
                return if (mode.reuse)
                    .{ .status = .ok_matched }
                else
                    .{ .status = .err_already_exists };
            }

            if (!mode.replace) return .{ .status = .err_mismatch };
            return existing.storeCreate(create);
        }

        const slot = self.findFree() orelse return .{ .status = .err_resources };
        const result = self.entries[slot].storeCreate(create);
        if (result.status == .ok) self.len += 1;
        return result;
    }

    pub fn lookup(self: *const ResourceTable, object_id: xrce.ObjectId) ?*const Resource {
        if (self.findIndex(object_id)) |index| return &self.entries[index];
        return null;
    }

    fn findIndex(self: *const ResourceTable, object_id: xrce.ObjectId) ?usize {
        for (&self.entries, 0..) |*entry, index| {
            if (entry.occupied and std.mem.eql(u8, &entry.object_id, &object_id)) return index;
        }
        return null;
    }

    fn findFree(self: *const ResourceTable) ?usize {
        for (&self.entries, 0..) |*entry, index| {
            if (!entry.occupied) return index;
        }
        return null;
    }
};

pub const ObjectWriteStats = struct {
    occupied: bool = false,
    object_id: xrce.ObjectId = .{ 0, 0 },
    writes: u64 = 0,
    bytes: u64 = 0,
    last_request_id: xrce.RequestId = .{ 0, 0 },
    last_payload_len: usize = 0,
};

pub const WriteStats = struct {
    total_writes: u64 = 0,
    total_bytes: u64 = 0,
    last_request_id: xrce.RequestId = .{ 0, 0 },
    last_object_id: xrce.ObjectId = .{ 0, 0 },
    last_payload_len: usize = 0,
    objects: [max_write_objects]ObjectWriteStats = @splat(.{}),

    pub fn record(self: *WriteStats, write: xrce.DecodedWriteData) void {
        self.total_writes += 1;
        self.total_bytes += write.serialized_data.len;
        self.last_request_id = write.request_id;
        self.last_object_id = write.object_id;
        self.last_payload_len = write.serialized_data.len;

        const slot = if (self.findIndex(write.object_id)) |index|
            &self.objects[index]
        else if (self.findFree()) |index| blk: {
            self.objects[index].occupied = true;
            self.objects[index].object_id = write.object_id;
            break :blk &self.objects[index];
        } else return;

        slot.writes += 1;
        slot.bytes += write.serialized_data.len;
        slot.last_request_id = write.request_id;
        slot.last_payload_len = write.serialized_data.len;
    }

    pub fn lookup(self: *const WriteStats, object_id: xrce.ObjectId) ?*const ObjectWriteStats {
        if (self.findIndex(object_id)) |index| return &self.objects[index];
        return null;
    }

    fn findIndex(self: *const WriteStats, object_id: xrce.ObjectId) ?usize {
        for (&self.objects, 0..) |*entry, index| {
            if (entry.occupied and std.mem.eql(u8, &entry.object_id, &object_id)) return index;
        }
        return null;
    }

    fn findFree(self: *const WriteStats) ?usize {
        for (&self.objects, 0..) |*entry, index| {
            if (!entry.occupied) return index;
        }
        return null;
    }
};

fn optionalI16Eql(a: ?i16, b: ?i16) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.? == b.?;
}

fn optionalObjectIdEql(a: ?xrce.ObjectId, b: ?xrce.ObjectId) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, &a.?, &b.?);
}
