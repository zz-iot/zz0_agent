//! Real DDS adapter. Each context owns a separate incremental graph; immutable
//! preparations, the catalog and the caller-owned DDS factory may be shared.
const std = @import("std");
const dds = @import("zzdds");
const B = @import("backend.zig");
const R = dds.resources;
const P = R.providers;
const DDS = dds.DDS;

pub fn validateCatalog(prepared: *const P.Prepared, catalog: B.Catalog) !void {
    try catalog.validate();
    for (catalog.definitions) |d| {
        const p = prepared.plan.application.participants[find(prepared.plan.application.participants, d.participant) orelse return error.UnknownDefinition];
        switch (d.kind) {
            .participant => if (p.domain_id != d.domain.?) {
                return error.CatalogMismatch;
            },
            .topic => {
                const t = p.topics[find(p.topics, d.resource) orelse return error.UnknownDefinition];
                if (d.topic_name == null or !same(t.topic_name, d.topic_name.?)) return error.CatalogMismatch;
            },
            .publisher => {
                _ = find(p.publishers, d.resource) orelse return error.UnknownDefinition;
            },
            .subscriber => {
                _ = find(p.subscribers, d.resource) orelse return error.UnknownDefinition;
            },
            .datawriter, .datareader => {
                const endpoints = if (d.kind == .datawriter) p.writers else p.readers;
                const e = endpoints[find(endpoints, d.resource) orelse return error.UnknownDefinition];
                const parent = catalog.definitions[find(catalog.definitions, d.parent.?).?];
                const topic = catalog.definitions[find(catalog.definitions, d.topic.?).?];
                if (!same(e.container_ref, parent.resource) or !same(e.topic_ref, topic.resource)) return error.CatalogMismatch;
                if (e.qos.data_representation != .XCDR2 or d.encoding != .plain_cdr2_le) return error.UnsupportedRepresentation;
                // The current loadable-provider contract supports bounded final
                // types. Appendable/mutable packet tests do not extend that ABI.
                const t = p.topics[find(p.topics, e.topic_ref).?];
                var found = false;
                for (0..prepared.bindings.len) |i| {
                    const info = prepared.info(i);
                    if (same(info.participant, p.name) and same(info.type_name, t.type_ref)) {
                        if (info.provider == null or !info.wire_validation) return error.MissingWireValidation;
                        if (info.representations & 2 == 0) return error.UnsupportedRepresentation;
                        found = true;
                    }
                }
                if (!found) return error.MissingBinding;
            },
            else => return error.UnsupportedObjectKind,
        }
    }
}

pub const Context = struct {
    alloc: std.mem.Allocator,
    prepared: *const P.Prepared,
    factory: DDS.DomainParticipantFactory,
    graph: ?R.Incremental = null,
    capacity: usize = 32,
    pub fn backend(self: *Context) B.Backend {
        return .{ .context = self, .vtable = &vtable };
    }
    fn cast(ctx: *anyopaque) *Context {
        return @ptrCast(@alignCast(ctx));
    }
    fn ensure(self: *Context) !*R.Incremental {
        if (self.graph == null) self.graph = try self.prepared.incremental(self.alloc, self.factory, self.capacity);
        return &self.graph.?;
    }
    fn lift(self: *Context, h: B.Handle) R.Incremental.Handle {
        return .{ .owner = &self.graph.?, .slot = h.slot, .generation = h.generation };
    }
    fn create(ctx: *anyopaque, d: *const B.Definition, parent: ?B.Handle, topic: ?B.Handle) !B.Handle {
        const self = cast(ctx);
        const g = try self.ensure();
        const h = switch (d.kind) {
            .participant => try g.createParticipant(d.resource),
            .topic => try g.createTopic(self.lift(parent orelse return error.WrongParent), d.resource),
            .publisher => try g.createPublisher(self.lift(parent orelse return error.WrongParent), d.resource),
            .subscriber => try g.createSubscriber(self.lift(parent orelse return error.WrongParent), d.resource),
            .datawriter => try g.createWriter(self.lift(parent orelse return error.WrongParent), self.lift(topic orelse return error.WrongParent), d.resource),
            .datareader => try g.createReader(self.lift(parent orelse return error.WrongParent), self.lift(topic orelse return error.WrongParent), d.resource),
            else => return error.UnsupportedObjectKind,
        };
        return .{ .slot = h.slot, .generation = h.generation };
    }
    fn write(ctx: *anyopaque, handle: B.Handle, bytes: []const u8) !void {
        const self = cast(ctx);
        if (self.graph == null) return error.UnknownObject;
        try self.prepared.writeIncremental(&self.graph.?, self.lift(handle), .alive, bytes);
    }
    fn delete(ctx: *anyopaque, handle: B.Handle) !void {
        const self = cast(ctx);
        if (self.graph == null) return error.UnknownObject;
        try self.graph.?.delete(self.lift(handle));
    }
    pub fn clear(self: *Context) !void {
        if (self.graph) |*g| {
            try g.deinit();
            self.graph = null;
        }
    }
    fn clearCallback(ctx: *anyopaque) !void {
        try cast(ctx).clear();
    }
    fn needsCleanup(ctx: *anyopaque) bool {
        if (cast(ctx).graph) |g| return g.cancelled or g.state == .failed;
        return false;
    }
    const vtable: B.Backend.Vtable = .{ .create = create, .write = write, .delete = delete, .clear = clearCallback, .needs_cleanup = needsCleanup };
};
/// Borrows the prepared definitions, catalog and factory through all client
/// cleanup. Keep this allocator/runtime at a stable address while clients exist.
pub const Runtime = struct {
    alloc: std.mem.Allocator,
    prepared: *const P.Prepared,
    catalog: B.Catalog,
    factory: DDS.DomainParticipantFactory,
    live_clients: usize = 0,
    const Owner = struct { runtime: *Runtime, context: Context, client: B.Client };
    pub fn init(alloc: std.mem.Allocator, prepared: *const P.Prepared, catalog: B.Catalog, factory: DDS.DomainParticipantFactory) !Runtime {
        if (factory.ptr == dds.dcps.NIL_PTR) return error.InvalidFactory;
        try validateCatalog(prepared, catalog);
        return .{ .alloc = alloc, .prepared = prepared, .catalog = catalog, .factory = factory };
    }
    pub fn clientFactory(self: *Runtime) B.ClientFactory {
        return .{ .context = self, .open = open, .close = close };
    }
    fn open(ctx: *anyopaque, _: [4]u8, _: u8) !*B.Client {
        const self: *Runtime = @ptrCast(@alignCast(ctx));
        const owner = try self.alloc.create(Owner);
        errdefer self.alloc.destroy(owner);
        owner.runtime = self;
        owner.context = .{ .alloc = self.alloc, .prepared = self.prepared, .factory = self.factory };
        owner.client = try B.Client.init(self.catalog, owner.context.backend());
        self.live_clients += 1;
        return &owner.client;
    }
    fn close(ctx: *anyopaque, client: *B.Client) !void {
        const self: *Runtime = @ptrCast(@alignCast(ctx));
        const owner: *Owner = @fieldParentPtr("client", client);
        if (owner.runtime != self) return error.WrongOwner;
        try client.clear();
        self.live_clients -= 1;
        self.alloc.destroy(owner);
    }
    pub fn deinit(self: *Runtime) !void {
        if (self.live_clients != 0) return error.LiveClients;
        self.* = undefined;
    }
};

fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn find(items: anytype, name: []const u8) ?usize {
    for (items, 0..) |item, i| if (same(item.name, name)) return i;
    return null;
}
