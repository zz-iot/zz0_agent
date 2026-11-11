//! Stable host ownership for loaded providers and client-owned DDS graphs.
const std = @import("std");
const dds = @import("zzdds");
const core = @import("root.zig");
const P = dds.resources.providers;
pub const Stage = enum { libraries, bindings, catalog };
pub const Startup = struct {
    alloc: std.mem.Allocator,
    configuration: *const core.config.Resolved,
    environment: P.Environment,
    prepared: P.Prepared,
    factory: ?dds.factory.DomainParticipantFactory = null,
    runtime: ?core.dds_backend.Runtime = null,
    server: ?core.udp.UdpServer = null,

    /// Configuration and the thread-safe allocator must outlive this owner and
    /// deferred DDS work. The executable uses libc storage for provider owners.
    pub fn open(a: std.mem.Allocator, configuration: *const core.config.Resolved, stage: *Stage) !*Startup {
        const self = try a.create(Startup);
        errdefer a.destroy(self);
        stage.* = .libraries;
        var environment = try P.Environment.init(a, configuration.inputs, .{});
        errdefer environment.deinit();
        stage.* = .bindings;
        var prepared = try P.Prepared.init(a, &configuration.resources.plan, &environment.manager, configuration.bindings, .{});
        errdefer prepared.deinit();
        stage.* = .catalog;
        try core.dds_backend.validateCatalog(&prepared, configuration.catalog);
        // No pointers to environment/prepared escape before this final move.
        self.* = .{ .alloc = a, .configuration = configuration, .environment = environment, .prepared = prepared };
        return self;
    }
    /// Startup errors retain initialized owners for close(). UDP is bound last.
    pub fn serve(self: *Startup, io: std.Io, address: std.Io.net.IpAddress, template: core.Agent) !void {
        if (self.factory != null) return error.AlreadyServing;
        self.factory = try dds.createFactory();
        self.runtime = try core.dds_backend.Runtime.init(self.alloc, &self.prepared, self.configuration.catalog, self.factory.?.toDDSFactory());
        self.server = try core.udp.UdpServer.bindBackend(io, address, template, self.runtime.?.clientFactory());
    }
    /// Failed client cleanup retains this complete owner and its socket for retry.
    /// Call outside DDS callbacks. No library or prepared storage is released until
    /// client graphs and the factory have shut down; native generation pins retain
    /// provider code independently through any deferred retirement.
    pub fn close(self: *Startup, io: std.Io) !void {
        if (self.server) |*server| {
            try server.close(io);
            self.server = null;
        }
        if (self.runtime) |*runtime| {
            try runtime.deinit();
            self.runtime = null;
        }
        if (self.factory) |*factory| {
            factory.deinit();
            self.factory = null;
        }
        self.prepared.deinit();
        self.environment.deinit();
        const a = self.alloc;
        a.destroy(self);
    }
};
