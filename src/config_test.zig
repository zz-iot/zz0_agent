const std = @import("std");
const C = @import("config.zig");
const t = std.testing;
const manifest =
    \\schema_version = 1
    \\resources = "../resources/app.toml"
    \\[[bindings]]
    \\participant = "main"
    \\type_name = "Reading"
    \\provider = "sensors"
    \\[catalog.P]
    \\kind = "participant"
    \\participant = "main"
    \\resource = "main"
    \\[catalog.T]
    \\kind = "topic"
    \\participant = "main"
    \\resource = "reading"
    \\parent = "P"
    \\[catalog.Pub]
    \\kind = "publisher"
    \\participant = "main"
    \\resource = "pub"
    \\parent = "P"
    \\[catalog.W]
    \\kind = "datawriter"
    \\participant = "main"
    \\resource = "reading"
    \\parent = "Pub"
    \\topic = "T"
;
const resources =
    \\schema_version = 1
    \\name = "test"
    \\[profiles.base.writer_qos]
    \\data_representation = "XCDR2"
    \\max_samples = 256
    \\max_instances = 256
    \\max_samples_per_instance = 256
    \\[profiles.derived]
    \\base = "base"
    \\[profiles.derived.writer_qos]
    \\history_depth = 4
    \\[participants.main]
    \\domain_id = 42
    \\types = { Reading = {} }
    \\topics = { reading = { topic_name = "SensorReadings", type_ref = "Reading" } }
    \\publishers = { pub = {} }
    \\[participants.main.writers.reading]
    \\container_ref = "pub"
    \\topic_ref = "reading"
    \\profile_ref = "derived"
    \\qos.history_depth = 2
;
const options: C.Options = .{ .cwd = "/invocation", .libraries = &.{"sensors=providers/nonexistent.so"} };
test "offline configuration derives DDS facts and owns data independently" {
    var diag: C.Diagnostic = .{};
    var parsed = try C.parse(t.allocator, "/config/agent/app.toml", manifest, &diag);
    var resolved = try parsed.resolve(t.allocator, resources, options, &diag);
    defer resolved.deinit();
    parsed.deinit();
    try t.expectEqualStrings("/config/resources/app.toml", resolved.resource_path);
    try t.expectEqualStrings("/config/agent/app.toml", resolved.manifest_path);
    try t.expectEqualStrings("/invocation/providers/nonexistent.so", resolved.inputs[0].source.library);
    try t.expectEqual(@as(?i16, 42), resolved.catalog.definitions[0].domain);
    try t.expectEqualStrings("SensorReadings", resolved.catalog.definitions[1].topic_name.?);
    try t.expectEqual(.plain_cdr2_le, resolved.catalog.definitions[3].encoding);
    const qos = resolved.resources.plan.application.participants[0].writers[0].qos;
    try t.expectEqual(@as(i32, 2), qos.history_depth);
    try t.expectEqual(@as(i32, 256), qos.max_samples);
    try t.expectEqual(.BEST_EFFORT_RELIABILITY_QOS, qos.reliability);
    try t.expectEqualStrings("Reading", resolved.bindings[0].source.provider.name);
}

fn expectManifestError(expected: anyerror, bytes: []const u8, field: []const u8) !void {
    var diag: C.Diagnostic = .{};
    try t.expectError(expected, C.parse(t.allocator, "/config/agent.toml", bytes, &diag));
    try t.expectEqual(.manifest, diag.document);
    try t.expectEqualStrings(field, diag.detail.fieldPath());
    try t.expect(diag.detail.location.line > 0);
}
fn expectResolveError(expected: anyerror, manifest_bytes: []const u8, resource_bytes: []const u8, opts: C.Options, document: @FieldType(C.Diagnostic, "document"), field: []const u8) !void {
    var diag: C.Diagnostic = .{};
    var parsed = try C.parse(t.allocator, "/config/agent.toml", manifest_bytes, &diag);
    defer parsed.deinit();
    try t.expectError(expected, parsed.resolve(t.allocator, resource_bytes, opts, &diag));
    try t.expectEqual(document, diag.document);
    try t.expectEqualStrings(field, diag.detail.fieldPath());
}
test "manifest syntax, versions, required records and strict fields have diagnostics" {
    try expectManifestError(error.UnsupportedSchema, "schema_version = 2\nresources = 'a'\n[catalog]\n", "schema_version");
    try expectManifestError(error.InvalidResourcePath, "schema_version = 1\n[catalog]\n", "resources");
    try expectManifestError(error.ExpectedNamedCatalog, "schema_version = 1\nresources = 'a'\n", "catalog");
    // Decoder errors retain the spelling and location of the input key.
    var diag: C.Diagnostic = .{};
    try t.expectError(error.UnknownField, C.parse(t.allocator, "/config/a.toml", "schema_version = 1\nresources = 'a'\nmisspelled = true\n[catalog]\n", &diag));
    try t.expectEqualStrings("misspelled", diag.detail.fieldPath());
    try t.expectEqual(@as(usize, 3), diag.detail.location.line);
    try t.expectError(error.InvalidSyntax, C.parse(t.allocator, "/config/a.toml", "schema_version = [", &diag));
    try t.expectEqual(.manifest, diag.document);
    try t.expect(diag.detail.code != null);
}
test "conditional settings preserve known validation and literal catalog names" {
    const source = "_future_setting = true\n" ++ manifest;
    var diag: C.Diagnostic = .{};
    var parsed = try C.parse(t.allocator, "/config/agent.toml", source, &diag);
    defer parsed.deinit();
    var resolved = try parsed.resolve(t.allocator, "_future_resource = true\n" ++ resources, options, &diag);
    defer resolved.deinit();
    try t.expectEqual(@as(usize, 1), resolved.manifest_skipped.len);
    try t.expectEqualStrings("_future_setting", resolved.manifest_skipped[0].input_path[0]);
    try t.expectEqual(@as(usize, 1), resolved.resources.skipped.len);
    const conditional = try std.mem.replaceOwned(u8, t.allocator, manifest, "schema_version = 1", "_schema_version = 1");
    defer t.allocator.free(conditional);
    var known = try C.parse(t.allocator, "/config/a.toml", conditional, &diag);
    known.deinit();
    const invalid = try std.mem.replaceOwned(u8, t.allocator, manifest, "schema_version = 1", "_schema_version = 'wrong'");
    defer t.allocator.free(invalid);
    try t.expectError(error.TypeMismatch, C.parse(t.allocator, "/config/a.toml", invalid, &diag));
    const literal = try std.mem.replaceOwned(u8, t.allocator, manifest, "catalog.W", "catalog._W");
    defer t.allocator.free(literal);
    var named = try C.parse(t.allocator, "/config/a.toml", literal, &diag);
    defer named.deinit();
    var literal_result = try named.resolve(t.allocator, resources, options, &diag);
    defer literal_result.deinit();
    try t.expectEqualStrings("_W", literal_result.catalog.definitions[3].name);
}
test "catalog references must match resource scope and the resolved DDS graph" {
    const cases = [_]struct { before: []const u8, after: []const u8, err: anyerror, field: []const u8 }{
        .{ .before = "kind = \"datawriter\"", .after = "", .err = error.MissingKind, .field = "catalog.W.kind" },
        .{ .before = "participant = \"main\"\nresource = \"reading\"\nparent = \"Pub\"", .after = "participant = \"other\"\nresource = \"reading\"\nparent = \"Pub\"", .err = error.UnknownParticipant, .field = "catalog.W.participant" },
        .{ .before = "resource = \"pub\"", .after = "resource = \"missing\"", .err = error.UnknownResource, .field = "catalog.Pub.resource" },
        .{ .before = "parent = \"Pub\"", .after = "parent = \"missing\"", .err = error.UnknownDefinition, .field = "catalog.W.parent" },
        .{ .before = "parent = \"Pub\"", .after = "parent = \"T\"", .err = error.WrongParent, .field = "catalog.W.parent" },
        .{ .before = "topic = \"T\"", .after = "topic = \"Pub\"", .err = error.WrongTopic, .field = "catalog.W.topic" },
        .{ .before = "topic = \"T\"", .after = "", .err = error.MissingTopic, .field = "catalog.W.topic" },
    };
    for (cases) |case| {
        const changed = try std.mem.replaceOwned(u8, t.allocator, manifest, case.before, case.after);
        defer t.allocator.free(changed);
        try expectResolveError(case.err, changed, resources, options, .manifest, case.field);
    }
    const xcdr1 = try std.mem.replaceOwned(u8, t.allocator, resources, "data_representation = \"XCDR2\"", "");
    defer t.allocator.free(xcdr1);
    try expectResolveError(error.UnsupportedRepresentation, manifest, xcdr1, options, .manifest, "catalog.W.resource");
    const bad_resource = try std.mem.replaceOwned(u8, t.allocator, resources, "qos.history_depth = 2", "qos.history_depth = 0");
    defer t.allocator.free(bad_resource);
    try expectResolveError(error.InvalidQos, manifest, bad_resource, options, .resources, "participants.main.writers.reading.qos.history_depth");
}
test "binary CREATE ambiguities are rejected before serving" {
    try expectResolveError(error.AmbiguousPublisher, manifest ++ "\n[catalog.OtherPub]\nkind = 'publisher'\nparticipant = 'main'\nresource = 'pub'\nparent = 'P'\n", resources, options, .manifest, "catalog.Pub");
    try expectResolveError(error.AmbiguousWriter, manifest ++ "\n[catalog.OtherWriter]\nkind = 'datawriter'\nparticipant = 'main'\nresource = 'reading'\nparent = 'Pub'\ntopic = 'T'\n", resources, options, .manifest, "catalog.W");
    // Separate resource writers still collide when binary CREATE sees the same topic.
    const extra_resources = resources ++ "\n[participants.main.writers.alias]\ncontainer_ref = 'pub'\ntopic_ref = 'reading'\nprofile_ref = 'base'\n";
    const extra_catalog = manifest ++ "\n[catalog.AliasWriter]\nkind = 'datawriter'\nparticipant = 'main'\nresource = 'alias'\nparent = 'Pub'\ntopic = 'T'\n";
    try expectResolveError(error.AmbiguousWriter, extra_catalog, extra_resources, options, .manifest, "catalog.W");
    const distinct_resources = try std.mem.replaceOwned(u8, t.allocator, resources, "publishers = { pub = {} }", "publishers = { pub = {}, other = {} }");
    defer t.allocator.free(distinct_resources);
    const distinct_catalog = manifest ++ "\n[catalog.OtherPub]\nkind = 'publisher'\nparticipant = 'main'\nresource = 'other'\nparent = 'P'\n";
    var diag: C.Diagnostic = .{};
    var parsed = try C.parse(t.allocator, "/config/a.toml", distinct_catalog, &diag);
    defer parsed.deinit();
    var resolved = try parsed.resolve(t.allocator, distinct_resources, options, &diag);
    defer resolved.deinit();
    try t.expectEqualStrings("other", resolved.catalog.definitions[4].resource);
}
test "provider aliases, complete bindings and hash constraints are checked offline" {
    try expectResolveError(error.UnknownProvider, manifest, resources, .{ .cwd = "/tmp" }, .manifest, "bindings.0.provider");
    try expectResolveError(error.DuplicateProvider, manifest, resources, .{ .cwd = "/tmp", .libraries = &.{ "sensors=a", "sensors=b" } }, .arguments, "--library[1]");
    try expectResolveError(error.UnknownProviderConstraint, manifest, resources, .{ .cwd = "/tmp", .libraries = options.libraries, .hashes = &.{"other=00"} }, .arguments, "--sha256[0]");
    try expectResolveError(error.DuplicateConstraint, manifest, resources, .{ .cwd = "/tmp", .libraries = options.libraries, .hashes = &.{ "sensors=" ++ "0000000000000000000000000000000000000000000000000000000000000000", "sensors=" ++ "0000000000000000000000000000000000000000000000000000000000000000" } }, .arguments, "--sha256[1]");
    try expectResolveError(error.InvalidHexLength, manifest, resources, .{ .cwd = "/tmp", .libraries = options.libraries, .hashes = &.{"sensors=00"} }, .arguments, "--sha256[0]");
    const duplicate = try std.mem.replaceOwned(u8, t.allocator, manifest, "[catalog.P]", "[[bindings]]\nparticipant = 'main'\ntype_name = 'Reading'\nprovider = 'sensors'\n[catalog.P]");
    defer t.allocator.free(duplicate);
    try expectResolveError(error.DuplicateBinding, duplicate, resources, options, .manifest, "bindings.1");
    const missing = try std.mem.replaceOwned(u8, t.allocator, resources, "types = { Reading = {} }", "types = { Reading = {}, Unused = {} }");
    defer t.allocator.free(missing);
    try expectResolveError(error.MissingBinding, manifest, missing, options, .manifest, "bindings");
    const identity = try std.mem.replaceOwned(u8, t.allocator, manifest, "provider = \"sensors\"", "provider = 'sensors'\nexpected_identifier = 'f1" ++ "abababababababababababababab" ++ "'");
    defer t.allocator.free(identity);
    var diag: C.Diagnostic = .{};
    var parsed = try C.parse(t.allocator, "/config/app.toml", identity, &diag);
    defer parsed.deinit();
    var resolved = try parsed.resolve(t.allocator, resources, .{ .cwd = "/tmp", .libraries = &.{ "sensors=missing", "unused=also-missing" }, .hashes = &.{"sensors=" ++ "abababababababababababababababababababababababababababababababab"} }, &diag);
    defer resolved.deinit();
    try t.expectEqual(@as(u8, 0xf1), resolved.bindings[0].expected_identifier.?[0]);
    try t.expectEqual(@as(u8, 0xab), resolved.inputs[0].expected_sha256.?[31]);
    const bad_identity = try std.mem.replaceOwned(u8, t.allocator, identity, "f1abab", "00abab");
    defer t.allocator.free(bad_identity);
    try expectResolveError(error.InvalidIdentifier, bad_identity, resources, options, .manifest, "bindings.0.expected_identifier");
}
test "multiple projects select explicit exports while unexposed resources stay private" {
    const multi_manifest = manifest ++ "\n[[bindings]]\nparticipant = 'other'\ntype_name = 'Reading'\nprovider = 'project_b'\n[catalog.Other]\nkind = 'participant'\nparticipant = 'other'\nresource = 'other'\n";
    const multi_resources = resources ++ "\n[participants.other]\ndomain_id = 7\ntypes = { Reading = {} }\ntopics = { private = { topic_name = 'Audit', type_ref = 'Reading' } }\n";
    var diag: C.Diagnostic = .{};
    var parsed = try C.parse(t.allocator, "/config/agent.toml", multi_manifest, &diag);
    defer parsed.deinit();
    var resolved = try parsed.resolve(t.allocator, multi_resources, .{ .cwd = "/tmp", .libraries = &.{ "sensors=a.so", "project_b=b.so" } }, &diag);
    defer resolved.deinit();
    try t.expectEqual(@as(usize, 2), resolved.bindings.len);
    try t.expectEqualStrings("project_b", resolved.bindings[1].source.provider.provider);
    try t.expectEqual(@as(usize, 5), resolved.catalog.definitions.len);
    try t.expectEqual(@as(usize, 1), resolved.resources.plan.application.participants[1].topics.len);
}
fn allocationRoundTrip(a: std.mem.Allocator) !void {
    var diag: C.Diagnostic = .{};
    var parsed = try C.parse(a, "/config/agent.toml", "_future = true\n" ++ manifest, &diag);
    defer parsed.deinit();
    var resolved = try parsed.resolve(a, resources, options, &diag);
    defer resolved.deinit();
}
test "configuration owns and releases all allocations on failure" {
    try t.checkAllAllocationFailures(t.allocator, allocationRoundTrip, .{});
}

test "writer mappings cannot redirect the resolved resource graph" {
    const second_pub = try std.mem.replaceOwned(u8, t.allocator, resources, "publishers = { pub = {} }", "publishers = { pub = {}, other = {} }");
    defer t.allocator.free(second_pub);
    const changed_parent = try std.mem.replaceOwned(u8, t.allocator, second_pub, "container_ref = \"pub\"", "container_ref = 'other'");
    defer t.allocator.free(changed_parent);
    try expectResolveError(error.WrongParent, manifest, changed_parent, options, .manifest, "catalog.W.parent");
    const second_topic = try std.mem.replaceOwned(u8, t.allocator, resources, "topics = { reading = { topic_name = \"SensorReadings\", type_ref = \"Reading\" } }", "topics = { reading = { topic_name = 'SensorReadings', type_ref = 'Reading' }, other = { topic_name = 'Other', type_ref = 'Reading' } }");
    defer t.allocator.free(second_topic);
    const changed_topic = try std.mem.replaceOwned(u8, t.allocator, second_topic, "topic_ref = \"reading\"", "topic_ref = 'other'");
    defer t.allocator.free(changed_topic);
    try expectResolveError(error.WrongTopic, manifest, changed_topic, options, .manifest, "catalog.W.topic");
    const cross_scope = try std.mem.replaceOwned(u8, t.allocator, manifest, "parent = \"Pub\"", "parent = 'ForeignPub'");
    defer t.allocator.free(cross_scope);
    const scoped_manifest = try std.mem.concat(t.allocator, u8, &.{ cross_scope, "\n[catalog.ForeignP]\nkind = 'participant'\nparticipant = 'other'\nresource = 'other'\n[catalog.ForeignPub]\nkind = 'publisher'\nparticipant = 'other'\nresource = 'pub'\nparent = 'ForeignP'\n" });
    defer t.allocator.free(scoped_manifest);
    try expectResolveError(error.WrongParent, scoped_manifest, resources ++ "\n[participants.other]\ndomain_id = 0\npublishers = { pub = {} }\n", options, .manifest, "catalog.W.parent");
}
test "configuration input and collection limits fail before loading" {
    var diag: C.Diagnostic = .{};
    try t.expectError(error.ExpectedAbsolutePath, C.parse(t.allocator, "relative.toml", manifest, &diag));
    const large = try t.allocator.alloc(u8, 256 * 1024 + 1);
    defer t.allocator.free(large);
    @memset(large, ' ');
    try t.expectError(error.ManifestTooLarge, C.parse(t.allocator, "/config/a.toml", large, &diag));
    try expectResolveError(error.ResourceDocumentTooLarge, manifest, large, options, .resources, "");
    var catalog: std.ArrayList(u8) = .empty;
    defer catalog.deinit(t.allocator);
    try catalog.appendSlice(t.allocator, "schema_version = 1\nresources = 'app.toml'\n");
    for (0..129) |i| {
        const entry = try std.fmt.allocPrint(t.allocator, "[catalog.P{d}]\nkind = 'participant'\nparticipant = 'main'\nresource = 'main'\n", .{i});
        defer t.allocator.free(entry);
        try catalog.appendSlice(t.allocator, entry);
    }
    try expectManifestError(error.CatalogLimit, catalog.items, "catalog");
    const many: [33][]const u8 = @splat("sensors=missing");
    try expectResolveError(error.ProviderLimit, manifest, resources, .{ .cwd = "/tmp", .libraries = &many }, .arguments, "");
    try expectResolveError(error.ExpectedAliasPair, manifest, resources, .{ .cwd = "/tmp", .libraries = &.{"missing-separator"} }, .arguments, "--library[0]");
    try expectResolveError(error.EmptyAliasPair, manifest, resources, .{ .cwd = "/tmp", .libraries = &.{"sensors="} }, .arguments, "--library[0]");
    try expectResolveError(error.ExpectedAbsolutePath, manifest, resources, .{ .cwd = "relative" }, .arguments, "");
}
