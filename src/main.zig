const std = @import("std");
const core = @import("zz0_agent");
const dds = @import("zzdds");
pub const std_options: std.Options = .{ .log_level = .warn };

pub fn main(init: std.process.Init) u8 {
    run(init) catch |err| {
        std.debug.print("zz0_agent: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}
fn run(init: std.process.Init) !void {
    const a = init.arena.allocator();
    var iterator = try std.process.Args.iterateAllocator(init.minimal.args, a);
    defer iterator.deinit();
    _ = iterator.next();
    var args: std.ArrayList([]const u8) = .empty;
    while (iterator.next()) |arg| try args.append(a, arg);
    const options = core.cli.parse(a, args.items) catch |err| {
        std.debug.print("{s}", .{core.cli.usage});
        return err;
    };
    if (options.mode == .help) {
        std.debug.print("{s}", .{core.cli.usage});
        return;
    }
    if (options.mode == .version) {
        std.debug.print("zz0_agent {s}\n", .{@import("agent_build").version});
        return;
    }
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(init.io, ".", a);
    const filename = try std.fs.path.resolve(a, &.{ cwd, options.config.? });
    const source = try readDocument(a, init.io, filename);
    var diagnostic: core.config.Diagnostic = .{};
    var parsed = core.config.parse(init.gpa, filename, source, &diagnostic) catch |err| {
        reportDiagnostic(filename, &diagnostic);
        return err;
    };
    defer parsed.deinit();
    const resource_path = try parsed.resourcePath(a);
    const resource_source = try readDocument(a, init.io, resource_path);
    var configuration = parsed.resolve(init.gpa, resource_source, .{ .cwd = cwd, .libraries = options.libraries, .hashes = options.hashes }, &diagnostic) catch |err| {
        reportDiagnostic(if (diagnostic.document == .resources) resource_path else if (diagnostic.document == .arguments) "arguments" else filename, &diagnostic);
        return err;
    };
    defer configuration.deinit();
    reportPlan(&configuration, options.mode != .serve);
    if (options.mode == .check) {
        std.debug.print("offline configuration valid; library files were not accessed; ABI, export identity and wire capabilities remain unchecked\n", .{});
        return;
    }
    var stage: core.startup.Stage = .libraries;
    // These allocations can be released by native DDS/provider retirement on
    // other threads. Never back them with the configuration arena or init.gpa.
    const startup = core.startup.Startup.open(std.heap.c_allocator, &configuration, &stage) catch |err| {
        std.debug.print("zz0_agent: {s} preparation failed; inputs/selections:\n", .{@tagName(stage)});
        for (configuration.inputs) |input| std.debug.print("  provider {s} artifact={s}\n", .{ input.alias, input.source.library });
        for (configuration.bindings) |binding| std.debug.print("  type {s}/{s} provider={s}\n", .{ binding.participant, binding.type_name, binding.source.provider.provider });
        return err;
    };
    // A failed close retains provider owners; panic terminates without running
    // later defers that could release configuration backing live native work.
    defer startup.close(init.io) catch @panic("DDS client cleanup failed; provider owners retained");
    if (options.mode == .inspect) {
        for (0..startup.prepared.bindings.len) |i| {
            const info = startup.prepared.info(i);
            std.debug.print("type {s}/{s} provider={s} generation={d} representations={d} wire_validation={} keyed={} minimal={s}\n", .{ info.participant, info.type_name, info.provider.?, info.generation.?, info.representations, info.wire_validation, info.keyed.?, std.fmt.bytesToHex(info.minimal_identifier.?, .lower) });
            std.debug.print("  artifact={s} sha256={s}\n", .{ info.artifact.?, std.fmt.bytesToHex(info.sha256.?, .lower) });
        }
        std.debug.print("inspection passed; no DDS factory, entities or UDP listener created\n", .{});
        return;
    }
    try startup.serve(init.io, .{ .ip4 = .unspecified(options.port) }, .{
        .handshake_encoding = options.handshake_encoding,
        .write_log_mode = options.write_log_mode,
        .stats_every = options.stats_every,
        .hex_bytes = options.hex_bytes,
    });
    const server = &startup.server.?;
    std.debug.print("zz0_agent: DDS forwarding enabled (configured providers)\n", .{});
    std.debug.print("zz0_agent: listening for DDS-XRCE UDP on port {d}\n", .{server.localAddress().getPort()});
    if (options.max_datagrams) |count| {
        for (0..count) |_| try server.serveOnce(init.io, .none);
    } else try server.serveForever(init.io);
}
fn readDocument(a: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(256 * 1024)) catch |err| {
        std.debug.print("{s}: cannot read configuration\n", .{path});
        return err;
    };
}
fn reportDiagnostic(path: []const u8, diagnostic: *const core.config.Diagnostic) void {
    std.debug.print("{s}:{d}:{d}: {s}\n", .{ path, diagnostic.detail.location.line, diagnostic.detail.location.column, diagnostic.detail.fieldPath() });
}
fn reportPlan(configuration: *const core.config.Resolved, verbose: bool) void {
    std.debug.print("plan {s}: {d} participant(s), {d} binding(s), {d} exposed definition(s)\n", .{ configuration.resources.plan.application.name, configuration.resources.plan.application.participants.len, configuration.bindings.len, configuration.catalog.definitions.len });
    for (configuration.manifest_skipped) |item| reportSkipped(configuration.manifest_path, item);
    for (configuration.resources.skipped) |item| reportSkipped(configuration.resource_path, item);
    if (!verbose) return;
    for (configuration.catalog.definitions) |d| {
        std.debug.print("definition {s} kind={s} participant={s} resource={s}", .{ d.name, @tagName(d.kind), d.participant, d.resource });
        if (d.domain) |domain| std.debug.print(" domain={d}", .{domain});
        if (d.parent) |parent| std.debug.print(" parent={s}", .{parent});
        if (d.topic) |topic| std.debug.print(" topic={s} encoding={s}", .{ topic, @tagName(d.encoding) });
        if (d.topic_name) |name| std.debug.print(" topic_name={s}", .{name});
        std.debug.print("\n", .{});
    }
    for (configuration.resources.plan.application.participants) |p| {
        for (p.writers) |e| reportEndpoint("writer", p.name, e);
        for (p.readers) |e| reportEndpoint("reader", p.name, e);
    }
    for (configuration.resources.origins) |origin| std.debug.print("origin {s} {s}/{s} {s}: profile={s} {s}:{d}:{d}\n", .{ if (origin.reader) "reader" else "writer", origin.participant, origin.endpoint, origin.field, origin.profile orelse "<endpoint/default>", origin.source_file, if (origin.location) |loc| loc.line else 1, if (origin.location) |loc| loc.column else 1 });
}
fn reportEndpoint(kind: []const u8, participant: []const u8, endpoint: dds.resources.Endpoint) void {
    const q = endpoint.qos;
    std.debug.print("{s} {s}/{s}: representation={s} reliability={s} depth={d} max_samples={d} max_instances={d} max_samples_per_instance={d}\n", .{ kind, participant, endpoint.name, @tagName(q.data_representation), @tagName(q.reliability), q.history_depth, q.max_samples, q.max_instances, q.max_samples_per_instance });
}

fn reportSkipped(source: []const u8, item: anytype) void {
    std.debug.print("{s}:{d}:{d}: skipped optional setting ", .{ source, item.location.line, item.location.column });
    for (item.input_path, 0..) |part, i| std.debug.print("{s}{s}", .{ if (i == 0) "" else ".", part });
    std.debug.print("\n", .{});
}
