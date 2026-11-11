//! Process options; returned strings borrow args, collections use the caller's arena.
const std = @import("std");
const core = @import("root.zig");
pub const Mode = enum { serve, check, inspect, help, version };
pub const Options = struct {
    mode: Mode = .serve,
    config: ?[]const u8 = null,
    libraries: []const []const u8 = &.{},
    hashes: []const []const u8 = &.{},
    port: u16 = 8888,
    handshake_encoding: core.xrce.HandshakeEncoding = .omg_1_0,
    write_log_mode: core.WriteLogMode = .none,
    max_datagrams: ?usize = null,
    stats_every: ?u64 = null,
    hex_bytes: usize = 32,
};
pub fn parse(a: std.mem.Allocator, args: []const []const u8) !Options {
    var result: Options = .{};
    var libraries: std.ArrayList([]const u8) = .empty;
    var hashes: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help")) {
            try mode(&result, .help);
        } else if (std.mem.eql(u8, arg, "--version")) {
            try mode(&result, .version);
        } else if (std.mem.eql(u8, arg, "--check-config")) {
            try mode(&result, .check);
        } else if (std.mem.eql(u8, arg, "--inspect")) {
            try mode(&result, .inspect);
        } else if (try value(args, &i, "--config")) |v| {
            if (result.config != null) return error.DuplicateConfig;
            result.config = v;
        } else if (try value(args, &i, "--library")) |v| {
            if (libraries.items.len == 32) return error.ProviderLimit;
            try libraries.append(a, v);
        } else if (try value(args, &i, "--sha256")) |v| {
            if (hashes.items.len == 32) return error.ConstraintLimit;
            try hashes.append(a, v);
        } else if (try value(args, &i, "--port")) |v| {
            result.port = try std.fmt.parseUnsigned(u16, v, 10);
        } else if (try value(args, &i, "--handshake")) |v| {
            result.handshake_encoding = std.meta.stringToEnum(core.xrce.HandshakeEncoding, v) orelse return error.InvalidHandshakeEncoding;
        } else if (try value(args, &i, "--write-log")) |v| {
            result.write_log_mode = std.meta.stringToEnum(core.WriteLogMode, v) orelse return error.InvalidWriteLogMode;
        } else if (try value(args, &i, "--max-datagrams")) |v| {
            result.max_datagrams = try std.fmt.parseUnsigned(usize, v, 10);
            if (result.max_datagrams.? == 0) return error.InvalidDatagramLimit;
        } else if (try value(args, &i, "--stats-every")) |v| {
            result.stats_every = try std.fmt.parseUnsigned(u64, v, 10);
        } else if (try value(args, &i, "--hex-bytes")) |v| {
            result.hex_bytes = try std.fmt.parseUnsigned(usize, v, 10);
        } else return error.UnknownArgument;
    }
    if (result.mode != .help and result.mode != .version and result.config == null) return error.ConfigRequired;
    result.libraries = try libraries.toOwnedSlice(a);
    result.hashes = try hashes.toOwnedSlice(a);
    return result;
}
fn mode(result: *Options, next: Mode) !void {
    if (result.mode != .serve) return error.ConflictingModes;
    result.mode = next;
}
fn value(args: []const []const u8, index: *usize, name: []const u8) !?[]const u8 {
    const arg = args[index.*];
    if (std.mem.eql(u8, arg, name)) {
        index.* += 1;
        if (index.* == args.len or args[index.*].len == 0 or std.mem.startsWith(u8, args[index.*], "--")) return error.ExpectedOptionValue;
        return args[index.*];
    }
    if (arg.len > name.len and std.mem.startsWith(u8, arg, name) and arg[name.len] == '=') {
        if (arg.len == name.len + 1) return error.ExpectedOptionValue;
        return arg[name.len + 1 ..];
    }
    return null;
}
pub const usage =
    \\usage: zz0_agent --config FILE [--library ALIAS=PATH ...] [--sha256 ALIAS=HEX ...]
    \\                 [--check-config | --inspect] [--port=N] [--max-datagrams=N]
    \\                 [--handshake=omg_1_0|eprosima_v3] [--write-log=none|summary|hex]
    \\                 [--stats-every=N] [--hex-bytes=N]
    \\  --check-config validates both TOML files without accessing library files.
    \\  --inspect loads native provider code; creates no DDS entities or sockets.
    \\  Serving validates providers, creates the DDS factory, then binds UDP.
    \\  Resource paths resolve relative to FILE; library paths resolve from the cwd.
    \\  --help and --version need no configuration.
    \\
;
