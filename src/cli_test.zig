const std = @import("std");
const cli = @import("cli.zig");
const t = std.testing;
test "CLI requires explicit configuration and separates startup modes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectError(error.ConfigRequired, cli.parse(a, &.{}));
    try t.expectEqual(.help, (try cli.parse(a, &.{"--help"})).mode);
    try t.expectEqual(.version, (try cli.parse(a, &.{"--version"})).mode);
    const opts = try cli.parse(a, &.{ "--config", "app.toml", "--library", "a=a.so", "--library=b=b.so", "--sha256", "a=hash", "--inspect", "--port=0", "--max-datagrams", "5", "--handshake=eprosima_v3", "--write-log=hex", "--stats-every=10", "--hex-bytes=16" });
    try t.expectEqual(.inspect, opts.mode);
    try t.expectEqualStrings("app.toml", opts.config.?);
    try t.expectEqual(@as(usize, 2), opts.libraries.len);
    try t.expectEqualStrings("b=b.so", opts.libraries[1]);
    try t.expectEqualStrings("a=hash", opts.hashes[0]);
    try t.expectEqual(@as(u16, 0), opts.port);
    try t.expectEqual(@as(?usize, 5), opts.max_datagrams);
    try t.expectEqual(.eprosima_v3, opts.handshake_encoding);
    try t.expectEqual(.hex, opts.write_log_mode);
    try t.expectEqual(@as(?u64, 10), opts.stats_every);
    try t.expectEqual(@as(usize, 16), opts.hex_bytes);
    try t.expectEqual(.check, (try cli.parse(a, &.{ "--config=app.toml", "--check-config" })).mode);
}
test "CLI rejects missing values, conflicts and fixture fallback" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectError(error.ConflictingModes, cli.parse(a, &.{ "--check-config", "--inspect" }));
    try t.expectError(error.DuplicateConfig, cli.parse(a, &.{ "--config=a", "--config=b" }));
    try t.expectError(error.ExpectedOptionValue, cli.parse(a, &.{"--config"}));
    try t.expectError(error.ExpectedOptionValue, cli.parse(a, &.{ "--config", "--inspect" }));
    try t.expectError(error.ExpectedOptionValue, cli.parse(a, &.{"--config="}));
    try t.expectError(error.UnknownArgument, cli.parse(a, &.{"--validate-only"}));
    try t.expectError(error.InvalidDatagramLimit, cli.parse(a, &.{ "--config=a", "--max-datagrams=0" }));
    try t.expectError(error.InvalidWriteLogMode, cli.parse(a, &.{ "--config=a", "--write-log=invalid" }));
    try t.expectError(error.InvalidHandshakeEncoding, cli.parse(a, &.{ "--config=a", "--handshake=invalid" }));
}

test "CLI idle timeout default, override, disabling and invalid values" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqual(@as(i64, 600), (try cli.parse(a, &.{"--config=a"})).client_idle_timeout.?.toSeconds());
    try t.expect((try cli.parse(a, &.{ "--config=a", "--client-idle-timeout-seconds=0" })).client_idle_timeout == null);
    try t.expectEqual(@as(i64, 12), (try cli.parse(a, &.{ "--config=a", "--client-idle-timeout-seconds", "12" })).client_idle_timeout.?.toSeconds());
    try t.expectError(error.DuplicateIdleTimeout, cli.parse(a, &.{ "--config=a", "--client-idle-timeout-seconds=0", "--client-idle-timeout-seconds=1" }));
    for ([_][]const u8{ "-1", "bad", "9223372036854775808" }) |value| {
        if (cli.parse(a, &.{ "--config=a", "--client-idle-timeout-seconds", value })) |_| return error.ExpectedInvalidTimeout else |_| {}
    }
}
