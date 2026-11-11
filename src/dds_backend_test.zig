const std = @import("std");
const dds = @import("zzdds");
const root = @import("fixture_root.zig");
const B = @import("zz0_agent_core").backend;
const Demo = @import("fixtures/dds_demo.zig");
const Real = @import("zz0_agent_core").dds_backend;
const X = root.xrce;
const testing = std.testing;
const DDS = dds.DDS;
const peer1 = std.Io.net.IpAddress{ .ip4 = .loopback(23001) };
const peer2 = std.Io.net.IpAddress{ .ip4 = .loopback(23002) };
fn login(s: *root.udp.ClientSessions, peer: std.Io.net.IpAddress, key: u8, sid: u8) !void {
    var req: [64]u8 = undefined;
    var out: [64]u8 = undefined;
    const n = try (X.CreateClient{ .client_key = .{ 1, 2, 3, key }, .session_id = sid }).encodeMessage(&req);
    _ = try s.handleDatagram(peer, req[0..n], &out);
}
fn exchange(s: *root.udp.ClientSessions, peer: std.Io.net.IpAddress, req: []const u8) !X.StatusValue {
    var out: [512]u8 = undefined;
    const n = try s.handleDatagram(peer, req, &out);
    return (try X.decodeStatusMessage(out[0..n])).result.status;
}
fn path(s: *root.udp.ClientSessions, peer: std.Io.net.IpAddress, sid: u8, domain: i16) !void {
    var req: [256]u8 = undefined;
    var n = try (X.CreateByReference{ .session_id = sid, .sequence_nr = 1, .request_id = .{ 0, 1 }, .object_prefix = .{ 0, 0x10 }, .object_kind = .participant, .reference = "MyLibrary::CounterParticipant", .participant_domain_id = domain }).encodeMessage(&req);
    try testing.expectEqual(X.StatusValue.ok, try exchange(s, peer, req[0..n]));
    n = try (X.CreateByReference{ .session_id = sid, .sequence_nr = 2, .request_id = .{ 0, 2 }, .object_prefix = .{ 0, 0x10 }, .object_kind = .topic, .reference = "MyLibrary::CounterStatusTopic", .related_object_id = .{ 0, 0x11 } }).encodeMessage(&req);
    try testing.expectEqual(X.StatusValue.ok, try exchange(s, peer, req[0..n]));
    n = try (X.CreateBinary{ .session_id = sid, .sequence_nr = 3, .request_id = .{ 0, 3 }, .object_prefix = .{ 0, 0x10 }, .parent = .{ 0, 0x11 }, .definition = .{ .publisher = "pub" } }).encodeMessage(&req);
    try testing.expectEqual(X.StatusValue.ok, try exchange(s, peer, req[0..n]));
    n = try (X.CreateBinary{ .session_id = sid, .sequence_nr = 4, .request_id = .{ 0, 4 }, .object_prefix = .{ 0, 0x10 }, .parent = .{ 0, 0x13 }, .definition = .{ .datawriter = "CounterStatusTopic" } }).encodeMessage(&req);
    try testing.expectEqual(X.StatusValue.ok, try exchange(s, peer, req[0..n]));
}
fn write(s: *root.udp.ClientSessions, peer: std.Io.net.IpAddress, sid: u8, counter: u32, board: []const u8) !X.StatusValue {
    const rt = @import("zidl_rt");
    const T = @import("counter_types").CounterStatus;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(testing.allocator);
    var w = rt.CdrWriter(.xcdr2).init(&bytes, testing.allocator);
    try T.serialize(&w, .{ .counter = counter, .board = try rt.BoundedArray(u8, 16).fromSlice(board), .payload = try rt.BoundedArray(u8, 8).fromSlice(&.{ 1, 2, 3 }) });
    var req: [256]u8 = undefined;
    const n = try (X.WriteData{ .session_id = sid, .sequence_nr = 5, .request_id = .{ 0, 5 }, .object_id = .{ 0, 0x15 }, .serialized_data = bytes.items }).encodeMessage(&req);
    return exchange(s, peer, req[0..n]);
}
fn take(reader: DDS.DataReader) !dds.OwnedRawSample {
    const start = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
    while (std.Io.Clock.awake.now(std.testing.io).nanoseconds - start < 5 * std.time.ns_per_s) {
        if (dds.takeRaw(reader)) |sample| {
            if (sample.info.valid_data) return sample;
            sample.deinit();
        }
        try (std.Io.Clock.Duration{ .clock = .awake, .raw = std.Io.Duration.fromMilliseconds(10) }).sleep(std.testing.io);
    }
    return error.SampleTimeout;
}

test "real backend delivers checked samples for independent clients and preserves repeated sessions" {
    var prepared = try Demo.prepare(testing.allocator, 190);
    defer prepared.deinit();
    var factory = try dds.createFactory();
    defer factory.deinit();
    var receiver_factory = try dds.createFactory();
    defer receiver_factory.deinit();
    var receiver = try prepared.incremental(testing.allocator, receiver_factory.toDDSFactory(), 8);
    defer receiver.deinit() catch @panic("receiver cleanup");
    const dp = try receiver.createParticipant("main");
    const topic = try receiver.createTopic(dp, "counter");
    const sub = try receiver.createSubscriber(dp, "audit");
    const reader = try receiver.createReader(sub, topic, "counter");
    var definitions: [4]B.Definition = undefined;
    @memcpy(&definitions, Demo.catalog.definitions);
    definitions[0].domain = 190;
    var runtime = try Real.Runtime.init(testing.allocator, &prepared, .{ .definitions = &definitions }, factory.toDDSFactory());
    defer runtime.deinit() catch @panic("runtime cleanup");
    var sessions: root.udp.ClientSessions = .{ .backend_factory = runtime.clientFactory() };
    defer sessions.close() catch @panic("client cleanup");
    try login(&sessions, peer1, 1, 0x81);
    try login(&sessions, peer2, 2, 0x81);
    try testing.expect(sessions.clients[0].?.agent.backend_client != sessions.clients[1].?.agent.backend_client);
    try path(&sessions, peer1, 0x81, 190);
    try path(&sessions, peer2, 0x81, 190);
    try testing.expectEqual(@as(usize, 2), runtime.live_clients);
    try testing.expectError(error.LiveClients, runtime.deinit());
    // Wait for discovery before checking DDS delivery; WRITE acceptance alone is
    // not a receipt guarantee. Bounded retries also tolerate best-effort loss.
    var got_first = false;
    var got_second = false;
    for (0..5) |_| {
        try testing.expectEqual(X.StatusValue.ok, try write(&sessions, peer1, 0x81, 1, "first"));
        try testing.expectEqual(X.StatusValue.ok, try write(&sessions, peer2, 0x81, 2, "second"));
        const sample = take(try receiver.reader(reader)) catch continue;
        defer sample.deinit();
        var r = try @import("zidl_rt").CdrReader.init(sample.data);
        var value: @import("counter_types").CounterStatus = undefined;
        try @import("counter_types").CounterStatus.deserializeInto(&value, &r, testing.allocator);
        if (std.mem.eql(u8, value.board.slice(), "first")) got_first = true;
        if (std.mem.eql(u8, value.board.slice(), "second")) got_second = true;
        if (got_first and got_second) break;
    }
    try testing.expect(got_first and got_second);
    const owner = sessions.clients[0].?.agent.backend_client.?;
    const writes = owner.stats.accepted;
    try login(&sessions, peer1, 1, 0x81);
    try testing.expect(owner == sessions.clients[0].?.agent.backend_client.?);
    try testing.expectEqual(@as(usize, 4), owner.count());
    try testing.expectEqual(writes, owner.stats.accepted);
    const moved = std.Io.net.IpAddress{ .ip4 = .loopback(23003) };
    try login(&sessions, moved, 1, 0x81);
    try testing.expect(owner == sessions.clients[0].?.agent.backend_client.?);
    try testing.expectError(error.UnknownClientSession, write(&sessions, peer1, 0x81, 3, "stale-peer"));
    var req: [128]u8 = undefined;
    const bad = try (X.WriteData{ .session_id = 0x81, .sequence_nr = 6, .request_id = .{ 0, 6 }, .object_id = .{ 0, 0x15 }, .serialized_data = &.{1} }).encodeMessage(&req);
    try testing.expectEqual(X.StatusValue.err_invalid_data, try exchange(&sessions, moved, req[0..bad]));
    try login(&sessions, moved, 1, 0x82);
    try testing.expectEqual(@as(usize, 0), sessions.clients[0].?.agent.backend_client.?.count());
    try testing.expectEqual(@as(usize, 4), sessions.clients[1].?.agent.backend_client.?.count());
    const reset = try (X.Reset{ .session_id = 0x81, .sequence_nr = 7 }).encodeMessage(&req);
    var out: [128]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), try sessions.handleDatagram(peer2, req[0..reset], &out));
    try testing.expectEqual(@as(usize, 0), sessions.clients[1].?.agent.backend_client.?.count());
    const deletion = try (X.DeleteRequest{ .session_id = 0x81, .sequence_nr = 8, .request_id = .{ 0, 8 }, .object_id = .{ 0xff, 0xfe } }).encodeMessage(&req);
    try testing.expectEqual(X.StatusValue.ok, try exchange(&sessions, peer2, req[0..deletion]));
    try testing.expect(sessions.clients[1] == null);
    try testing.expectEqual(@as(usize, 1), runtime.live_clients);
}

test "managed sessions bound clients and retain failed cleanup for retry" {
    var prepared = try Demo.prepare(testing.allocator, 0);
    defer prepared.deinit();
    var factory = try dds.createFactory();
    defer factory.deinit();
    var runtime = try Real.Runtime.init(testing.allocator, &prepared, Demo.catalog, factory.toDDSFactory());
    defer runtime.deinit() catch @panic("runtime cleanup");
    const Wrapper = struct {
        inner: B.ClientFactory,
        fail_close: bool = false,
        fn open(ctx: *anyopaque, key: [4]u8, sid: u8) !*B.Client {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.inner.open(self.inner.context, key, sid);
        }
        fn close(ctx: *anyopaque, client: *B.Client) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.fail_close) {
                self.fail_close = false;
                return error.InjectedCleanup;
            }
            return self.inner.close(self.inner.context, client);
        }
    };
    var wrapped = Wrapper{ .inner = runtime.clientFactory() };
    var sessions: root.udp.ClientSessions = .{ .backend_factory = .{ .context = &wrapped, .open = Wrapper.open, .close = Wrapper.close } };
    defer sessions.close() catch @panic("session cleanup");
    try login(&sessions, peer1, 1, 0x81);
    const owner = sessions.clients[0].?.agent.backend_client.?;
    var req: [128]u8 = undefined;
    var short: [1]u8 = undefined;
    const change = try (X.CreateClient{ .client_key = .{ 1, 2, 3, 1 }, .session_id = 0x82 }).encodeMessage(&req);
    try testing.expectError(error.BufferTooSmall, sessions.handleDatagram(peer1, req[0..change], &short));
    try testing.expect(sessions.clients[0].?.agent.backend_client.? == owner);
    wrapped.fail_close = true;
    try testing.expectError(error.InjectedCleanup, login(&sessions, peer1, 1, 0x82));
    try testing.expectEqual(@as(usize, 1), runtime.live_clients);
    try testing.expectError(error.ClientCleanupRequired, login(&sessions, peer1, 1, 0x81));
    try testing.expectEqual(X.StatusValue.err_dds_error, try write(&sessions, peer1, 0x81, 1, "blocked"));
    try login(&sessions, peer1, 1, 0x82);
    try testing.expectEqual(@as(u8, 0x82), sessions.clients[0].?.session_id);
    for (2..9) |key| try login(&sessions, .{ .ip4 = .loopback(@intCast(23000 + key)) }, @intCast(key), 0x81);
    try testing.expectEqual(@as(usize, 8), runtime.live_clients);
    try testing.expectError(error.ClientCapacityExceeded, login(&sessions, .{ .ip4 = .loopback(24000) }, 9, 0x81));
    const deletion = try (X.DeleteRequest{ .session_id = 0x82, .sequence_nr = 8, .request_id = .{ 0, 8 }, .object_id = .{ 0xff, 0xfe } }).encodeMessage(&req);
    wrapped.fail_close = true;
    try testing.expectEqual(X.StatusValue.err_dds_error, try exchange(&sessions, peer1, req[0..deletion]));
    try testing.expect(sessions.clients[0] != null);
    try testing.expectEqual(X.StatusValue.ok, try exchange(&sessions, peer1, req[0..deletion]));
    try testing.expect(sessions.clients[0] == null);
    wrapped.fail_close = true;
    try testing.expectError(error.InjectedCleanup, sessions.close());
    try testing.expectEqual(@as(usize, 7), runtime.live_clients);
    try sessions.close();
    try testing.expectEqual(@as(usize, 0), runtime.live_clients);
}

test "real runtime validates catalog and owner allocation failures before entities" {
    var prepared = try Demo.prepare(testing.allocator, 0);
    defer prepared.deinit();
    var factory = try dds.createFactory();
    defer factory.deinit();
    var definitions: [4]B.Definition = undefined;
    @memcpy(&definitions, Demo.catalog.definitions);
    definitions[0].domain = 1;
    try testing.expectError(error.CatalogMismatch, Real.Runtime.init(testing.allocator, &prepared, .{ .definitions = &definitions }, factory.toDDSFactory()));
    definitions[0].domain = 0;
    definitions[3].encoding = .delimited_cdr2_le;
    try testing.expectError(error.UnsupportedRepresentation, Real.validateCatalog(&prepared, .{ .definitions = &definitions }));
    const Run = struct {
        fn run(alloc: std.mem.Allocator, p: *const dds.resources.providers.Prepared, f: DDS.DomainParticipantFactory) !void {
            var runtime = try Real.Runtime.init(alloc, p, Demo.catalog, f);
            defer runtime.deinit() catch @panic("runtime cleanup");
            const cf = runtime.clientFactory();
            const client = try cf.open(cf.context, .{ 1, 2, 3, 4 }, 0x81);
            try testing.expectEqual(@as(usize, 0), client.count());
            try cf.close(cf.context, client);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Run.run, .{ &prepared, factory.toDDSFactory() });
}

test "managed UDP RESET clears the graph without sending an empty reply datagram" {
    var prepared = try Demo.prepare(testing.allocator, 0);
    defer prepared.deinit();
    var factory = try dds.createFactory();
    defer factory.deinit();
    var runtime = try Real.Runtime.init(testing.allocator, &prepared, Demo.catalog, factory.toDDSFactory());
    defer runtime.deinit() catch @panic("runtime cleanup");
    const io = std.testing.io;
    const address = std.Io.net.IpAddress{ .ip4 = .loopback(0) };
    var server = try root.udp.UdpServer.bindBackend(io, address, .{}, runtime.clientFactory());
    defer server.close(io) catch @panic("server cleanup");
    const socket = try address.bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer socket.close(io);
    const Task = struct {
        server: *root.udp.UdpServer,
        result: anyerror!void = {},
        fn run(self: *@This()) void {
            self.result = self.work();
        }
        fn work(self: *@This()) !void {
            for (0..2) |_| try self.server.serveOnce(std.testing.io, root.udp.timeoutMillis(1000));
        }
    };
    var task: Task = .{ .server = &server };
    const thread = try std.Thread.spawn(.{}, Task.run, .{&task});
    var joined = false;
    defer if (!joined) thread.join();
    var req: [64]u8 = undefined;
    var out: [64]u8 = undefined;
    const peer = server.localAddress();
    const n = try (X.CreateClient{ .client_key = .{ 1, 2, 3, 4 }, .session_id = 0x81 }).encodeMessage(&req);
    try socket.send(io, &peer, req[0..n]);
    _ = try socket.receiveTimeout(io, &out, root.udp.timeoutMillis(1000));
    const reset = try (X.Reset{ .session_id = 0x81, .sequence_nr = 1 }).encodeMessage(&req);
    try socket.send(io, &peer, req[0..reset]);
    thread.join();
    joined = true;
    try task.result;
    try testing.expectError(error.Timeout, socket.receiveTimeout(io, &out, root.udp.timeoutMillis(100)));
    try testing.expectEqual(@as(usize, 1), runtime.live_clients);
}

test "Pico standard CREATE sequence constructs a real DDS writer" {
    const client = @import("zz0_client");
    var prepared = try Demo.prepare(testing.allocator, 190);
    defer prepared.deinit();
    var factory = try dds.createFactory();
    defer factory.deinit();
    var definitions: [4]B.Definition = undefined;
    @memcpy(&definitions, Demo.catalog.definitions);
    definitions[0].domain = 190;
    var runtime = try Real.Runtime.init(testing.allocator, &prepared, .{ .definitions = &definitions }, factory.toDDSFactory());
    defer runtime.deinit() catch @panic("runtime cleanup");
    var sessions = root.udp.ClientSessions{ .backend_factory = runtime.clientFactory() };
    defer sessions.close() catch @panic("sessions cleanup");
    try login(&sessions, peer1, 1, 0x81);
    var session = client.session.ClientSession.init(.{ .client_key = .{ 1, 2, 3, 1 }, .session_id = 0x81 });
    var req: [256]u8 = undefined;
    for (client.demo.publish_path_entities) |original| {
        var entity = original;
        if (entity.object_kind == .participant) entity.participant_domain_id = 190;
        const bytes = try client.demo.encodeCreate(&session, &req, entity);
        try testing.expectEqual(X.StatusValue.ok, try exchange(&sessions, peer1, bytes));
        // Firmware retries use REUSE, never destructive REPLACE.
        try testing.expectEqual(X.StatusValue.ok_matched, try exchange(&sessions, peer1, bytes));
    }
    const sample = [_]u8{ 42, 0, 0, 0, 5, 0, 0, 0, 'p', 'i', 'c', 'o', 0, 0, 0, 0, 3, 0, 0, 0, 1, 2, 3 };
    const bytes = try session.encodeWriteData(&req, .{ .object_id = client.demo.datawriter.object_id, .serialized_data = &sample });
    try testing.expectEqual(X.StatusValue.ok, try exchange(&sessions, peer1, bytes));
}
