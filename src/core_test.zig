const std = @import("std");
const core = @import("root.zig");
const Agent = core.Agent;
const xrce = core.xrce;
fn expectAgentDatagram(agent: *Agent, input: []const u8, output: []u8) !usize {
    return agent.handleDatagram(input, output);
}
test "agent replies to CREATE_CLIENT with STATUS_AGENT" {
    var agent = Agent{};
    var request: [xrce.CreateClient.message_len]u8 = undefined;
    _ = try (xrce.CreateClient{
        .client_key = .{ 0xaa, 0xbb, 0xcc, 0xdd },
        .session_id = 0x81,
        .sequence_nr = 7,
    }).encodeMessage(&request);

    var response: [xrce.StatusAgent.message_len]u8 = undefined;
    const n = try expectAgentDatagram(&agent, &request, &response);
    try std.testing.expectEqual(@as(usize, xrce.StatusAgent.message_len), n);

    const status = try xrce.decodeStatusAgentMessage(response[0..n]);
    try std.testing.expectEqual(@as(u8, 0x81), status.header.session_id);
    try std.testing.expectEqual(@as(u16, 7), status.header.sequence_nr);
}
test "agent dispatches CREATE_CLIENT after another known submessage" {
    var agent = Agent{};
    var create: [xrce.CreateClient.message_len]u8 = undefined;
    _ = try (xrce.CreateClient{
        .client_key = .{ 0xaa, 0xbb, 0xcc, 0xdd },
        .session_id = 0x81,
        .sequence_nr = 11,
    }).encodeMessage(&create);

    var request: [xrce.MessageHeader.encoded_len + xrce.SubmessageHeader.encoded_len + (xrce.SubmessageHeader.encoded_len + xrce.CreateClient.payload_len)]u8 = undefined;
    @memcpy(request[0..xrce.MessageHeader.encoded_len], create[0..xrce.MessageHeader.encoded_len]);
    try (xrce.SubmessageHeader{
        .id = .timestamp,
        .flags = xrce.flag_little_endian,
        .length = 0,
    }).encode(request[4..8]);
    @memcpy(request[8..], create[4..]);

    var response: [xrce.StatusAgent.message_len]u8 = undefined;
    const n = try expectAgentDatagram(&agent, &request, &response);
    const status = try xrce.decodeStatusAgentMessage(response[0..n]);
    try std.testing.expectEqual(@as(u8, 0x81), status.header.session_id);
    try std.testing.expectEqual(@as(u16, 11), status.header.sequence_nr);
}
test "agent rejects datagram without a supported submessage" {
    var agent = Agent{};
    var request: [xrce.CreateClient.message_len]u8 = undefined;
    _ = try (xrce.CreateClient{
        .client_key = .{ 0xaa, 0xbb, 0xcc, 0xdd },
        .session_id = 0x81,
    }).encodeMessage(&request);
    request[4] = @backingInt(xrce.SubmessageId.status);
    request[6] = 0;
    request[7] = 0;

    var response: [xrce.StatusAgent.message_len]u8 = undefined;
    try std.testing.expectError(error.NoSupportedSubmessage, expectAgentDatagram(&agent, request[0..8], &response));
}
test "agent rejects truncated submessage payload" {
    var agent = Agent{};
    var request: [xrce.MessageHeader.encoded_len + xrce.SubmessageHeader.encoded_len + 1]u8 = undefined;
    try (xrce.MessageHeader{
        .session_id = xrce.session_id_none_without_client_key,
        .stream_id = xrce.stream_id_none,
        .sequence_nr = 1,
    }).encode(request[0..4]);
    try (xrce.SubmessageHeader{
        .id = .create_client,
        .flags = xrce.flag_little_endian,
        .length = xrce.CreateClient.payload_len,
    }).encode(request[4..8]);
    request[8] = 0;

    var response: [xrce.StatusAgent.message_len]u8 = undefined;
    try std.testing.expectError(error.TruncatedSubmessage, expectAgentDatagram(&agent, &request, &response));
}

test "unconfigured core has no implicit references or writers" {
    var agent = Agent{};
    var request: [128]u8 = undefined;
    var response: [xrce.Status.message_len]u8 = undefined;
    const create_len = try (xrce.CreateByReference{
        .session_id = 0x81,
        .sequence_nr = 1,
        .request_id = .{ 1, 0 },
        .object_prefix = .{ 0x10, 0 },
        .object_kind = .participant,
        .reference = "MyLibrary::MyParticipant",
    }).encodeMessage(&request);
    const create_reply = try agent.handleDatagram(request[0..create_len], &response);
    try std.testing.expectEqual(xrce.StatusValue.err_unknown_reference, (try xrce.decodeStatusMessage(response[0..create_reply])).result.status);
    const write_len = try (xrce.WriteData{
        .session_id = 0x81,
        .sequence_nr = 1,
        .request_id = .{ 2, 0 },
        .object_id = .{ 0x10, 0x05 },
        .serialized_data = &.{ 1, 2, 3, 4 },
    }).encodeMessage(&request);
    const write_reply = try agent.handleDatagram(request[0..write_len], &response);
    try std.testing.expectEqual(xrce.StatusValue.err_unknown_reference, (try xrce.decodeStatusMessage(response[0..write_reply])).result.status);
    try std.testing.expectEqual(@as(u64, 0), agent.write_stats.total_writes);
}
