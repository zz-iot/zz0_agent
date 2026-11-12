//! Independent-process DDS receipt check; no generated sample types are linked.
const std = @import("std");
const core = @import("zz0_agent");
const dds = @import("zzdds");
const rt = @import("zidl_rt");
pub const std_options: std.Options = .{ .log_level = .warn };

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    var iterator = try std.process.Args.iterateAllocator(init.minimal.args, a);
    defer iterator.deinit();
    _ = iterator.next();
    const phase = try std.fmt.parseUnsigned(u32, iterator.next() orelse return error.ExpectedPhase, 10);
    if (phase > 3) return error.InvalidPhase;
    var args: std.ArrayList([]const u8) = .empty;
    while (iterator.next()) |arg| try args.append(a, arg);
    const options = try core.cli.parse(a, args.items);
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(init.io, ".", a);
    const filename = try std.fs.path.resolve(a, &.{ cwd, options.config.? });
    const source = try std.Io.Dir.cwd().readFileAlloc(init.io, filename, a, .limited(256 * 1024));
    var diagnostic: core.config.Diagnostic = .{};
    var parsed = try core.config.parse(init.gpa, filename, source, &diagnostic);
    defer parsed.deinit();
    const path = try parsed.resourcePath(a);
    const resources = try std.Io.Dir.cwd().readFileAlloc(init.io, path, a, .limited(256 * 1024));
    var configuration = try parsed.resolve(init.gpa, resources, .{ .cwd = cwd, .libraries = options.libraries }, &diagnostic);
    defer configuration.deinit();
    var stage: core.startup.Stage = .libraries;
    const preparation = try core.startup.Startup.open(std.heap.c_allocator, &configuration, &stage);
    defer preparation.close(init.io) catch @panic("provider cleanup");
    var factory = try dds.createFactory();
    defer factory.deinit();
    var graph = try preparation.prepared.incremental(std.heap.c_allocator, factory.toDDSFactory(), 16);
    defer graph.deinit() catch @panic("reader cleanup");
    const participant = try graph.createParticipant("main");
    const subscriber = try graph.createSubscriber(participant, "audit");
    const names = [_][]const u8{ "temperature", "pressure", "common" };
    var readers: [3]dds.DDS.DataReader = undefined;
    for (names, &readers) |name, *reader| {
        const topic = try graph.createTopic(participant, name);
        reader.* = try graph.reader(try graph.createReader(subscriber, topic, name));
    }
    std.debug.print("multi-library consumer ready phase={d}\n", .{phase});
    var seen: [3][2]bool = @splat(@splat(false));
    var count: usize = 0;
    const start = std.Io.Clock.awake.now(init.io).nanoseconds;
    while (std.Io.Clock.awake.now(init.io).nanoseconds - start < 20 * std.time.ns_per_s) {
        for (readers, 0..) |reader, kind| {
            while (dds.takeRaw(reader)) |sample| {
                defer sample.deinit();
                if (!sample.info.valid_data) continue;
                var wire = try rt.CdrReader.init(sample.data);
                const id = try wire.readU32();
                var client_index: ?usize = null;
                for (0..2) |client| if (id == phase * 1000 + (client + 1) * 100 + kind + 1) {
                    client_index = client;
                };
                const client = client_index orelse continue;
                switch (kind) {
                    0 => if (try wire.readF64() != 12.5 + @as(f64, @floatFromInt(phase + client * 10))) return error.IncorrectTemperature,
                    1 => {
                        if (try wire.readI32() != 1000 + @as(i32, @intCast(phase + client * 100))) return error.IncorrectPressure;
                        if (!std.mem.eql(u8, try wire.readStringZeroCopy(), "project-b")) return error.IncorrectLabel;
                    },
                    2 => if (try wire.readI32() != -10 - @as(i32, @intCast(phase + client))) return error.IncorrectReading,
                    else => unreachable,
                }
                if (wire.pos != wire.data.len) return error.TrailingSampleBytes;
                if (!seen[kind][client]) {
                    seen[kind][client] = true;
                    count += 1;
                    std.debug.print("received {s} client={d} phase={d}\n", .{ names[kind], client + 1, phase });
                }
            }
        }
        if (count == 6) {
            std.debug.print("received all six project/client samples phase={d}\n", .{phase});
            return;
        }
        try (std.Io.Clock.Duration{ .clock = .awake, .raw = std.Io.Duration.fromMilliseconds(10) }).sleep(init.io);
    }
    return error.SampleTimeout;
}
