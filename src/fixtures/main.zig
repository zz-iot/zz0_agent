const std = @import("std");
pub const std_options: std.Options = .{ .log_level = .warn };
const zz0_agent = @import("zz0_agent");

pub fn main(init: std.process.Init) !void {
    const config = try parseArgs(init.minimal.args, std.heap.page_allocator);

    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const bind_address = std.Io.net.IpAddress{ .ip4 = .unspecified(config.port) };
    const template: zz0_agent.Agent = .{ .handshake_encoding = config.handshake_encoding, .write_log_mode = config.write_log_mode, .stats_every = config.stats_every, .hex_bytes = config.hex_bytes };
    var server = try zz0_agent.udp.UdpServer.bind(io, bind_address, template);
    defer server.close(io) catch @panic("server cleanup");

    std.debug.print("zz0_agent: {s}\n", .{"validation-only compatibility mode; samples are not forwarded"});
    std.debug.print("zz0_agent: listening for DDS-XRCE UDP on port {d}\n", .{server.localAddress().getPort()});
    if (config.max_datagrams) |count| {
        for (0..count) |_| try server.serveOnce(io, .none);
    } else try server.serveForever(io);
}

const Config = struct {
    max_datagrams: ?usize = null,
    handshake_encoding: zz0_agent.xrce.HandshakeEncoding = .omg_1_0,
    port: u16 = 8888,
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
        } else if (std.mem.startsWith(u8, arg, "--max-datagrams=")) {
            config.max_datagrams = try std.fmt.parseUnsigned(usize, arg[16..], 10);
            if (config.max_datagrams.? == 0) return error.InvalidDatagramLimit;
        } else if (std.mem.eql(u8, arg, "--validate-only")) {
            // Retain the old runner spelling; this executable only validates.
        } else if (std.mem.startsWith(u8, arg, "--handshake=")) {
            config.handshake_encoding = std.meta.stringToEnum(zz0_agent.xrce.HandshakeEncoding, arg["--handshake=".len..]) orelse return error.InvalidHandshakeEncoding;
        } else if (std.mem.startsWith(u8, arg, "--port=")) {
            config.port = try std.fmt.parseUnsigned(u16, arg["--port=".len..], 10);
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
        \\usage: zz0_agent_compat [--handshake=omg_1_0|eprosima_v3] [--port=N] [--validate-only] [--max-datagrams=N] [--write-log=none|summary|hex] [--stats-every=N] [--hex-bytes=N]
        \\  Legacy reference/empty-XML and CounterStatus validation fixture.
        \\  No DDS forwarding; --validate-only is accepted for existing test runners.
        \\
    , .{});
}
