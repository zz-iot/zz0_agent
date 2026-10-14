const std = @import("std");
const zz0_agent = @import("zz0_agent");

pub fn main(init: std.process.Init) !void {
    const config = try parseArgs(init.minimal.args, std.heap.page_allocator);

    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const bind_address = std.Io.net.IpAddress{ .ip4 = .unspecified(8888) };
    var server = try zz0_agent.udp.UdpServer.bind(io, bind_address, .{
        .write_log_mode = config.write_log_mode,
        .stats_every = config.stats_every,
        .hex_bytes = config.hex_bytes,
    });
    defer server.close(io);

    std.debug.print("zz0_agent: listening for DDS-XRCE UDP on port {d}\n", .{server.localAddress().getPort()});
    try server.serveForever(io);
}

const Config = struct {
    write_log_mode: zz0_agent.WriteLogMode = .none,
    stats_every: ?u64 = null,
    hex_bytes: usize = 32,
};

fn parseArgs(args: std.process.Args, allocator: std.mem.Allocator) !Config {
    var it = try std.process.Args.iterateAllocator(args, allocator);
    defer it.deinit();
    var config: Config = .{};
    _ = it.next();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            std.process.exit(0);
        } else if (std.mem.startsWith(u8, arg, "--write-log=")) {
            const value = arg["--write-log=".len..];
            config.write_log_mode = if (std.mem.eql(u8, value, "none"))
                .none
            else if (std.mem.eql(u8, value, "summary"))
                .summary
            else if (std.mem.eql(u8, value, "hex"))
                .hex
            else
                return error.InvalidWriteLogMode;
        } else if (std.mem.startsWith(u8, arg, "--stats-every=")) {
            config.stats_every = try std.fmt.parseUnsigned(u64, arg["--stats-every=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--hex-bytes=")) {
            config.hex_bytes = try std.fmt.parseUnsigned(usize, arg["--hex-bytes=".len..], 10);
        } else {
            return error.UnknownArgument;
        }
    }

    return config;
}

fn printUsage() void {
    std.debug.print(
        \\usage: zz0_agent [--write-log=none|summary|hex] [--stats-every=N] [--hex-bytes=N]
        \\
    , .{});
}
