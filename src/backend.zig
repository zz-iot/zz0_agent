//! Client-owned, normalized resource requests. Packet decoding and DDS construction
//! stay at opposite sides of this boundary. This module does not implement a wire codec.
const std = @import("std");
const xrce = @import("zz0_client").xrce;
const R = @import("resources.zig");

pub const xcdr_revision = xrce.xcdr_revision;

/// Modern XTypes 1.3 RTPS encapsulation identifiers.
pub const Encoding = enum(u8) { plain_cdr2_le = 7, delimited_cdr2_le = 9, parameter_list_cdr2_le = 11 };
pub const Definition = struct {
    name: []const u8,
    kind: xrce.ObjectKind,
    /// Names in the prepared DDS plan; no client object IDs or library paths.
    participant: []const u8,
    resource: []const u8,
    parent: ?[]const u8 = null,
    topic: ?[]const u8 = null,
    /// DDS topic name used by binary writer requests (distinct from the plan key).
    topic_name: ?[]const u8 = null,
    domain: ?i16 = null,
    /// Selected from the configured type's extensibility, never sample sniffing.
    encoding: Encoding = .plain_cdr2_le,
};
pub const Catalog = struct {
    definitions: []const Definition,
    pub fn validate(self: Catalog) !void {
        if (self.definitions.len > 128) return error.CatalogLimit;
        for (self.definitions, 0..) |d, i| {
            if (!validName(d.name) or !validName(d.participant) or !validName(d.resource)) return error.InvalidDefinition;
            for (self.definitions[0..i]) |prior| if (same(prior.name, d.name)) return error.DuplicateDefinition;
            if (d.topic_name) |name| {
                if (d.kind != .topic or name.len == 0 or name.len > 256 or std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidDefinition;
            }
            if (d.kind == .participant) {
                if (!same(d.participant, d.resource) or d.parent != null or d.topic != null or d.domain == null or d.domain.? < 0 or d.domain.? > 232) return error.InvalidDefinition;
                continue;
            }
            if (d.domain != null) return error.InvalidDefinition;
            const expected_parent: xrce.ObjectKind = switch (d.kind) {
                .topic, .publisher, .subscriber => .participant,
                .datawriter => .publisher,
                .datareader => .subscriber,
                else => return error.UnsupportedObjectKind,
            };
            const parent_index = self.find(d.parent orelse return error.InvalidDefinition) orelse return error.UnknownDefinition;
            const parent = self.definitions[parent_index];
            if (parent.kind != expected_parent or !same(d.participant, parent.participant)) return error.InvalidDefinition;
            if (d.kind == .datawriter or d.kind == .datareader) {
                const t = self.definitions[self.find(d.topic orelse return error.InvalidDefinition) orelse return error.UnknownDefinition];
                if (t.kind != .topic or !same(t.participant, d.participant) or !optionalName(t.parent, parent.parent)) return error.InvalidDefinition;
            } else if (d.topic != null) return error.InvalidDefinition;
        }
    }
    fn find(self: Catalog, name: []const u8) ?usize {
        for (self.definitions, 0..) |d, i| if (same(d.name, name)) return i;
        return null;
    }
};

/// Backend-local identity. The real adapter can reconstruct an Incremental.Handle
/// with its own owner address; handles never cross backend/client contexts.
/// All handles are invalid after successful clear; the Client drops its mappings.
pub const Handle = struct { slot: usize, generation: u64 };
pub const Backend = struct {
    context: *anyopaque,
    vtable: *const Vtable,
    pub const Vtable = struct {
        create: *const fn (*anyopaque, *const Definition, ?Handle, ?Handle) anyerror!Handle,
        /// Receives a bounded, encapsulated XCDR2 sample. Must validate and write
        /// synchronously, and must not retain the borrowed bytes after returning.
        write: *const fn (*anyopaque, Handle, []const u8) anyerror!void,
        delete: *const fn (*anyopaque, Handle) anyerror!void,
        /// Remove all resources, leaving an empty usable backend. Failure retains
        /// a retryable cleanup owner even if some DDS objects were already removed.
        clear: *const fn (*anyopaque) anyerror!void,
        needs_cleanup: *const fn (*anyopaque) bool,
    };
};
/// Allocates stable independent client contexts. Failed close must retain a
/// retryable owner; successful close invalidates the returned pointer.
pub const ClientFactory = struct {
    context: *anyopaque,
    open: *const fn (*anyopaque, [4]u8, u8) anyerror!*Client,
    close: *const fn (*anyopaque, *Client) anyerror!void,
};

pub const Create = struct {
    object_id: xrce.ObjectId,
    definition: []const u8,
    parent: ?xrce.ObjectId = null,
    topic: ?xrce.ObjectId = null,
    domain: ?i16 = null,
    mode: R.CreateMode = .{ .reuse = false, .replace = false },
};
pub const Stats = struct { received: u64 = 0, rejected: u64 = 0, accepted: u64 = 0 };
pub const Client = struct {
    const Association = struct { object_id: xrce.ObjectId, definition: usize, handle: Handle, parent: ?usize, topic: ?usize };
    backend: Backend,
    catalog: Catalog,
    entries: [R.max_resources]?Association = @splat(null),
    state: enum { ready, busy, cleanup_required } = .ready,
    /// Keep the original failure independently of its protocol-facing status.
    last_error: ?anyerror = null,
    /// Failure that blocked the owner; later rejected requests must not erase it.
    cleanup_cause: ?anyerror = null,
    stats: Stats = .{},

    /// Catalog strings are borrowed and immutable through successful clear.
    /// Supply a fresh, empty, independent Backend context for each client and
    /// keep it alive through cleanup. Do not copy a populated owner.
    /// Construct this owner in stable client storage before exposing it to callbacks.
    pub fn init(catalog: Catalog, backend: Backend) !Client {
        try catalog.validate();
        if (backend.vtable.needs_cleanup(backend.context)) return error.CleanupRequired;
        return .{ .catalog = catalog, .backend = backend };
    }
    fn lookup(self: *const Client, id: xrce.ObjectId) ?usize {
        for (self.entries, 0..) |maybe, i| if (maybe) |e| {
            if (std.mem.eql(u8, &e.object_id, &id)) return i;
        };
        return null;
    }
    pub fn count(self: *const Client) usize {
        var n: usize = 0;
        for (self.entries) |e| if (e != null) {
            n += 1;
        };
        return n;
    }
    fn failure(self: *Client, err: anyerror) xrce.ResultStatus {
        self.last_error = err;
        return .{ .status = statusFor(err) };
    }
    fn contextIndex(self: *const Client, id: ?xrce.ObjectId, definition: ?[]const u8) !?usize {
        if (definition == null) {
            if (id != null) return error.WrongParent;
            return null;
        }
        const index = self.lookup(id orelse return error.WrongParent) orelse return error.UnknownObject;
        if (!same(self.catalog.definitions[self.entries[index].?.definition].name, definition.?)) return error.WrongParent;
        return index;
    }
    /// Resolve the selected wire subset into authorized immutable definitions.
    pub fn createWire(self: *Client, wire: xrce.DecodedCreate) xrce.ResultStatus {
        if (self.state != .ready) return self.failure(error.ClientNotReady);
        const mode: R.CreateMode = .{ .reuse = wire.submessage.flags & xrce.flag_create_reuse != 0, .replace = wire.submessage.flags & xrce.flag_create_replace != 0 };
        if (!mode.reuse and !mode.replace and self.lookup(wire.object_id) != null) return self.failure(error.AlreadyExists);
        if (wire.representation == .by_reference) {
            if (wire.object_kind != .participant and wire.object_kind != .topic) return self.failure(error.UnsupportedRepresentation);
            return self.create(.{ .object_id = wire.object_id, .definition = wire.representation.by_reference, .parent = wire.related_object_id, .domain = wire.participant_domain_id, .mode = mode });
        }
        if (wire.representation != .in_binary) return self.failure(error.UnsupportedRepresentation);
        const parent_id = wire.related_object_id orelse return self.failure(error.WrongParent);
        const parent_index = self.lookup(parent_id) orelse return self.failure(error.UnknownObject);
        const parent = self.entries[parent_index].?;
        const parent_def = self.catalog.definitions[parent.definition];
        var selected: ?usize = null;
        var selected_topic: ?usize = null;
        for (self.catalog.definitions, 0..) |d, i| {
            if (d.kind != wire.object_kind or !optionalName(d.parent, parent_def.name)) continue;
            var topic_index: ?usize = null;
            switch (wire.representation.in_binary) {
                .publisher => |name| {
                    if (name) |value| {
                        if (!same(value, d.resource)) continue;
                    }
                },
                .datawriter => |name| {
                    const topic_def = self.catalog.definitions[self.catalog.find(d.topic.?).?];
                    if (topic_def.topic_name == null or !same(topic_def.topic_name.?, name)) continue;
                    for (self.entries, 0..) |maybe, t| if (maybe) |entry| {
                        if (entry.definition == self.catalog.find(d.topic.?).? and entry.parent == parent.parent) {
                            if (topic_index != null) return self.failure(error.AmbiguousDefinition);
                            topic_index = t;
                        }
                    };
                    if (topic_index == null) continue;
                },
            }
            if (selected != null) return self.failure(error.AmbiguousDefinition);
            selected = i;
            selected_topic = topic_index;
        }
        const definition = self.catalog.definitions[selected orelse return self.failure(error.UnknownDefinition)];
        return self.create(.{ .object_id = wire.object_id, .definition = definition.name, .parent = parent_id, .topic = if (selected_topic) |t| self.entries[t].?.object_id else null, .mode = mode });
    }
    pub fn create(self: *Client, request: Create) xrce.ResultStatus {
        if (self.state != .ready) return self.failure(error.ClientNotReady);
        self.last_error = null;
        if (self.lookup(request.object_id)) |_| {
            if (!request.mode.reuse and !request.mode.replace) return self.failure(error.AlreadyExists);
        }
        const index = self.catalog.find(request.definition) orelse return self.failure(error.UnknownDefinition);
        const d = &self.catalog.definitions[index];
        if (request.object_id[1] & 0x0f != @backingInt(d.kind)) return self.failure(error.WrongObjectKind);
        if (request.domain != d.domain) return self.failure(error.WrongDomain);
        const parent = self.contextIndex(request.parent, d.parent) catch |err| return self.failure(err);
        const topic = self.contextIndex(request.topic, d.topic) catch |err| return self.failure(err);
        if (d.kind == .datawriter or d.kind == .datareader) {
            if (self.entries[parent.?].?.parent != self.entries[topic.?].?.parent) return self.failure(error.WrongParent);
        }
        if (self.lookup(request.object_id)) |existing| {
            const e = self.entries[existing].?;
            if (request.mode.reuse and e.definition == index and e.parent == parent and e.topic == topic) return .{ .status = .ok_matched };
            if (request.mode.replace) return self.failure(error.ReplacementUnsupported);
            return self.failure(error.DefinitionMismatch);
        }
        var slot: ?usize = null;
        for (self.entries, 0..) |entry, i| if (entry == null) {
            slot = i;
            break;
        };
        const reserved = slot orelse return self.failure(error.ResourceLimit);
        // Fixed storage reserves the commit slot before making backend calls.
        self.state = .busy;
        defer if (self.state == .busy) {
            self.state = .ready;
        };
        const handle = self.backend.vtable.create(self.backend.context, d, if (parent) |p| self.entries[p].?.handle else null, if (topic) |t| self.entries[t].?.handle else null) catch |err| {
            if (self.backend.vtable.needs_cleanup(self.backend.context)) {
                self.state = .cleanup_required;
                self.cleanup_cause = err;
            }
            return self.failure(err);
        };
        self.entries[reserved] = .{ .object_id = request.object_id, .definition = index, .handle = handle, .parent = parent, .topic = topic };
        return .{ .status = .ok };
    }
    pub fn write(self: *Client, id: xrce.ObjectId, plain_cdr2_le: []const u8) xrce.ResultStatus {
        self.stats.received +|= 1;
        const result = self.writeImpl(id, plain_cdr2_le);
        if (result.status == .ok) self.stats.accepted +|= 1 else self.stats.rejected +|= 1;
        return result;
    }
    fn writeImpl(self: *Client, id: xrce.ObjectId, data: []const u8) xrce.ResultStatus {
        if (self.state != .ready) return self.failure(error.ClientNotReady);
        self.last_error = null;
        const e = self.entries[self.lookup(id) orelse return self.failure(error.UnknownObject)].?;
        const definition = self.catalog.definitions[e.definition];
        if (definition.kind != .datawriter) return self.failure(error.WrongObjectKind);
        if (data.len > 512) return self.failure(error.PayloadTooLarge);
        var sample: [516]u8 = undefined;
        @memcpy(sample[0..4], &[_]u8{ 0, @backingInt(definition.encoding), 0, 0 });
        @memcpy(sample[4..][0..data.len], data);
        self.state = .busy;
        defer if (self.state == .busy) {
            self.state = .ready;
        };
        self.backend.vtable.write(self.backend.context, e.handle, sample[0 .. data.len + 4]) catch |err| {
            if (self.backend.vtable.needs_cleanup(self.backend.context)) {
                self.state = .cleanup_required;
                self.cleanup_cause = err;
            }
            return self.failure(err);
        };
        return .{ .status = .ok };
    }
    pub fn delete(self: *Client, id: xrce.ObjectId) xrce.ResultStatus {
        if (self.state != .ready) return self.failure(error.ClientNotReady);
        self.last_error = null;
        const index = self.lookup(id) orelse return self.failure(error.UnknownObject);
        for (self.entries) |maybe| if (maybe) |e| {
            if (e.parent == index or e.topic == index) return self.failure(error.LiveDependents);
        };
        self.state = .busy;
        defer if (self.state == .busy) {
            self.state = .ready;
        };
        self.backend.vtable.delete(self.backend.context, self.entries[index].?.handle) catch |err| {
            self.state = .cleanup_required;
            self.cleanup_cause = err;
            return self.failure(err);
        };
        self.entries[index] = null;
        return .{ .status = .ok };
    }
    /// Explicit RESET/session replacement/shutdown use this operation, not a
    /// plain struct overwrite. Same-session repeat login must not call it.
    pub fn clear(self: *Client) !void {
        if (self.state == .busy) return error.OperationInProgress;
        self.state = .busy;
        self.backend.vtable.clear(self.backend.context) catch |err| {
            self.last_error = err;
            if (self.cleanup_cause == null) self.cleanup_cause = err;
            self.state = .cleanup_required;
            return err;
        };
        self.entries = @splat(null);
        self.cleanup_cause = null;
        self.last_error = null;
        self.state = .ready;
    }
    /// Borrowed catalog definition for a currently usable object.
    pub fn definitionFor(self: *const Client, id: xrce.ObjectId) ?*const Definition {
        if (self.state != .ready) return null;
        const e = self.entries[self.lookup(id) orelse return null].?;
        return &self.catalog.definitions[e.definition];
    }
};
/// Provisional adapter policy; exact operation mappings remain in the protocol audit.
pub fn statusFor(err: anyerror) xrce.StatusValue {
    return switch (err) {
        error.UnknownDefinition, error.UnknownObject, error.UnknownReference => .err_unknown_reference,
        error.WrongParent, error.WrongDomain, error.DefinitionMismatch, error.WrongObjectKind => .err_mismatch,
        error.AlreadyExists => .err_already_exists,
        error.ReplacementUnsupported, error.LiveDependents, error.PermissionDenied, error.AmbiguousDefinition => .err_denied,
        error.InvalidSample, error.PayloadTooLarge, error.UnsupportedRepresentation => .err_invalid_data,
        error.ResourceLimit, error.OutOfMemory, error.OutOfResources => .err_resources,
        else => .err_dds_error,
    };
}
fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn optionalName(a: ?[]const u8, b: ?[]const u8) bool {
    if (a) |av| {
        return b != null and same(av, b.?);
    }
    return b == null;
}
fn validName(s: []const u8) bool {
    return s.len > 0 and s.len <= R.max_reference_len and std.mem.indexOfScalar(u8, s, 0) == null;
}
