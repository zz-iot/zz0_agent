//! Opt-in CounterStatus publishing fixture. The real adapter itself is type-agnostic.
const std = @import("std");
const dds = @import("zzdds");
const B = @import("backend.zig");
const R = dds.resources;
const provider = @import("counter_provider");
pub const catalog: B.Catalog = .{ .definitions = &.{
    .{ .name = "MyLibrary::CounterParticipant", .kind = .participant, .participant = "main", .resource = "main", .domain = 0 },
    .{ .name = "MyLibrary::CounterStatusTopic", .kind = .topic, .participant = "main", .resource = "counter", .parent = "MyLibrary::CounterParticipant", .topic_name = "CounterStatusTopic" },
    .{ .name = "MyLibrary::CounterPublisher", .kind = .publisher, .participant = "main", .resource = "pub", .parent = "MyLibrary::CounterParticipant" },
    .{ .name = "MyLibrary::CounterStatusWriter", .kind = .datawriter, .participant = "main", .resource = "counter", .parent = "MyLibrary::CounterPublisher", .topic = "MyLibrary::CounterStatusTopic", .telemetry = .counter_status },
} };
pub fn prepare(alloc: std.mem.Allocator, domain: i32) !R.providers.Prepared {
    var plan = try R.Plan.resolve(alloc, .{ .name = "CounterStatus", .participants = &.{.{
        .name = "main",
        .domain_id = domain,
        .types = &.{.{ .name = "CounterStatus" }},
        .topics = &.{.{ .name = "counter", .topic_name = "CounterStatusTopic", .type_ref = "CounterStatus" }},
        .publishers = &.{.{ .name = "pub" }},
        .subscribers = &.{.{ .name = "audit" }},
        .writers = &.{.{ .name = "counter", .container_ref = "pub", .topic_ref = "counter", .qos = .{ .data_representation = .XCDR2, .max_samples = 256, .max_instances = 256, .max_samples_per_instance = 256 } }},
        .readers = &.{.{ .name = "counter", .container_ref = "audit", .topic_ref = "counter", .qos = .{ .data_representation = .XCDR2, .max_samples = 256, .max_instances = 256, .max_samples_per_instance = 256 } }},
    }} }, .{});
    defer plan.deinit();
    var manager = try dds.typesupport.Manager.init(alloc, 4);
    defer manager.deinit();
    try manager.addStatic("counter", &provider.library);
    return R.providers.Prepared.init(alloc, &plan, &manager, &.{.{ .participant = "main", .type_name = "CounterStatus", .source = .{ .provider = .{ .provider = "counter", .name = "CounterStatus" } }, .require_wire_validation = true }}, .{});
}
