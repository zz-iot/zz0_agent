const std = @import("std");
const core = @import("zz0_agent_core");
const C = core.config;
const Startup = core.startup.Startup;
const paths = @import("fixture_paths");
const t = std.testing;
fn configuration() !C.Resolved {
    const manifest_path = try std.fs.path.resolve(t.allocator, &.{ paths.cwd, paths.manifest });
    defer t.allocator.free(manifest_path);
    const manifest = try std.Io.Dir.cwd().readFileAlloc(t.io, manifest_path, t.allocator, .limited(256 * 1024));
    defer t.allocator.free(manifest);
    var diag: C.Diagnostic = .{};
    var parsed = try C.parse(t.allocator, manifest_path, manifest, &diag);
    defer parsed.deinit();
    const resource_path = try parsed.resourcePath(t.allocator);
    defer t.allocator.free(resource_path);
    const resources = try std.Io.Dir.cwd().readFileAlloc(t.io, resource_path, t.allocator, .limited(256 * 1024));
    defer t.allocator.free(resources);
    const library = try std.fmt.allocPrint(t.allocator, "counter={s}", .{paths.library});
    defer t.allocator.free(library);
    return parsed.resolve(t.allocator, resources, .{ .cwd = paths.cwd, .libraries = &.{library} }, &diag);
}
test "loaded startup inspection creates no factory or client runtime" {
    var cfg = try configuration();
    defer cfg.deinit();
    var stage: core.startup.Stage = .libraries;
    const startup = try Startup.open(std.heap.c_allocator, &cfg, &stage);
    defer startup.close(t.io) catch @panic("cleanup");
    try t.expect(startup.factory == null and startup.runtime == null and startup.server == null);
    try t.expectEqual(@as(usize, 1), startup.environment.manager.liveGenerations());
    try t.expect(startup.prepared.info(0).wire_validation);
}
test "startup rolls back failed artifact and exact-identity constraints" {
    var cfg = try configuration();
    defer cfg.deinit();
    var inputs = try t.allocator.dupe(@import("zzdds").resources.providers.ProviderInput, cfg.inputs);
    defer t.allocator.free(inputs);
    cfg.inputs = inputs;
    inputs[0].expected_sha256 = @splat(0);
    var stage: core.startup.Stage = .libraries;
    try t.expectError(error.ArtifactHashMismatch, Startup.open(std.heap.c_allocator, &cfg, &stage));
    try t.expectEqual(.libraries, stage);
    inputs[0].expected_sha256 = null;
    const P = @import("zzdds").resources.providers;
    var bindings = try t.allocator.dupe(P.Binding, cfg.bindings);
    defer t.allocator.free(bindings);
    cfg.bindings = bindings;
    var wrong: P.Identifier = @splat(0);
    wrong[0] = 0xf1;
    bindings[0].expected_identifier = wrong;
    try t.expectError(error.TypeIdentityMismatch, Startup.open(std.heap.c_allocator, &cfg, &stage));
    try t.expectEqual(.bindings, stage);
    bindings[0].expected_identifier = null;
    const startup = try Startup.open(std.heap.c_allocator, &cfg, &stage);
    try startup.close(t.io);
}
test "failed UDP bind retains initialized owners for checked cleanup" {
    var cfg = try configuration();
    defer cfg.deinit();
    var stage: core.startup.Stage = .libraries;
    const startup = try Startup.open(std.heap.c_allocator, &cfg, &stage);
    defer startup.close(t.io) catch @panic("cleanup");
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    const occupied = try address.bind(t.io, .{ .mode = .dgram, .protocol = .udp });
    defer occupied.close(t.io);
    try t.expectError(error.AddressInUse, startup.serve(t.io, occupied.address, .{}));
    try t.expect(startup.server == null);
    try t.expect(startup.factory != null and startup.runtime != null);
    try t.expectEqual(@as(usize, 1), startup.environment.manager.liveGenerations());
}
test "failed inactive-client cleanup retains loaded providers through retry and shutdown" {
    const previous = t.log_level;
    t.log_level = .err;
    defer t.log_level = previous;
    var cfg = try configuration();
    defer cfg.deinit();
    var stage: core.startup.Stage = .libraries;
    const startup = try Startup.open(std.heap.c_allocator, &cfg, &stage);
    errdefer startup.close(t.io) catch @panic("cleanup");
    try startup.serve(t.io, .{ .ip4 = .loopback(0) }, .{});
    const Factory = struct {
        original: core.backend.ClientFactory,
        fail: bool = true,
        fn open(ctx: *anyopaque, key: [4]u8, session: u8) !*core.backend.Client {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.original.open(self.original.context, key, session);
        }
        fn close(ctx: *anyopaque, client: *core.backend.Client) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.fail) return error.CleanupFailed;
            return self.original.close(self.original.context, client);
        }
    };
    var factory = Factory{ .original = startup.runtime.?.clientFactory() };
    startup.server.?.sessions.backend_factory = .{ .context = &factory, .open = Factory.open, .close = Factory.close };
    var request: [64]u8 = undefined;
    var response: [64]u8 = undefined;
    const n = try (core.xrce.CreateClient{ .client_key = .{ 1, 2, 3, 4 }, .session_id = 0x81 }).encodeMessage(&request);
    _ = try startup.server.?.sessions.handleDatagram(.{ .ip4 = .loopback(23123) }, request[0..n], &response);
    const sessions = &startup.server.?.sessions;
    const owner = sessions.clients[0].?.agent.backend_client.?;
    try t.expectEqual(core.xrce.StatusValue.ok, owner.create(.{ .object_id = .{ 0, 0x11 }, .definition = "MyLibrary::CounterParticipant", .domain = 0 }).status);
    sessions.idle_timeout = .fromSeconds(10);
    sessions.maintain(10 * std.time.ns_per_s);
    try t.expect(sessions.clients[0].?.expired and sessions.clients[0].?.closing);
    try t.expectEqual(owner, sessions.clients[0].?.agent.backend_client.?);
    try t.expectError(error.CleanupFailed, startup.close(t.io));
    try t.expect(startup.server != null and startup.factory != null and startup.runtime != null);
    try t.expectEqual(@as(usize, 1), startup.runtime.?.live_clients);
    try t.expectEqual(@as(usize, 1), startup.environment.manager.liveGenerations());
    factory.fail = false;
    sessions.maintain(11 * std.time.ns_per_s);
    try t.expect(sessions.clients[0] == null);
    try t.expectEqual(@as(usize, 0), startup.runtime.?.live_clients);
    try t.expectEqual(@as(usize, 1), startup.environment.manager.liveGenerations());
    try startup.close(t.io);
}

test "configured provider survives live writes through checked host shutdown" {
    const client = @import("zz0_client");
    const rt = @import("zidl_rt");
    const Sample = @import("counter_types").CounterStatus;
    var cfg = try configuration();
    defer cfg.deinit();
    var stage: core.startup.Stage = .libraries;
    const startup = try Startup.open(std.heap.c_allocator, &cfg, &stage);
    defer startup.close(t.io) catch @panic("cleanup");
    try startup.serve(t.io, .{ .ip4 = .loopback(0) }, .{});
    const peer: std.Io.net.IpAddress = .{ .ip4 = .loopback(23124) };
    var session = client.session.ClientSession.init(.{ .client_key = .{ 5, 6, 7, 8 }, .session_id = 0x81 });
    var request: [512]u8 = undefined;
    var response: [512]u8 = undefined;
    const login = try session.encodeCreateClient(&request);
    const reply = try startup.server.?.sessions.handleDatagram(peer, login, &response);
    _ = try session.handleDatagram(response[0..reply]);
    for (client.demo.publish_path_entities) |entity| {
        const bytes = try client.demo.encodeCreate(&session, &request, entity);
        const n = try startup.server.?.sessions.handleDatagram(peer, bytes, &response);
        try t.expectEqual(core.xrce.StatusValue.ok, (try core.xrce.decodeStatusMessage(response[0..n])).result.status);
    }
    var sample: std.ArrayList(u8) = .empty;
    defer sample.deinit(t.allocator);
    var writer = rt.CdrWriter(.xcdr2).init(&sample, t.allocator);
    try Sample.serialize(&writer, .{ .counter = 7, .board = try rt.BoundedArray(u8, 16).fromSlice("loader"), .payload = try rt.BoundedArray(u8, 8).fromSlice(&.{1}) });
    const n = try (core.xrce.WriteData{ .session_id = 0x81, .sequence_nr = 10, .request_id = .{ 10, 0 }, .object_id = client.demo.datawriter.object_id, .serialized_data = sample.items }).encodeMessage(&request);
    const reply_len = try startup.server.?.sessions.handleDatagram(peer, request[0..n], &response);
    try t.expectEqual(core.xrce.StatusValue.ok, (try core.xrce.decodeStatusMessage(response[0..reply_len])).result.status);
    try t.expectEqual(@as(usize, 1), startup.runtime.?.live_clients);
    try t.expectEqual(@as(usize, 4), startup.server.?.sessions.clients[0].?.agent.backend_client.?.count());
    // No RESET/DELETE: the checked close must destroy this live graph before
    // the factory, prepared selections and loaded provider environment.
}
