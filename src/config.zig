//! Offline startup configuration. No file access, native loading or DDS calls.
//! Parsed and Resolved own their data independently; neither requires a stable address.
const std = @import("std");
const rt = @import("zidl_rt");
const schema = @import("agent_config_generated");
const dds = @import("zzdds");
const R = dds.resources;
const P = R.providers;
const B = @import("backend.zig");
const A = rt.authoring;

pub const Diagnostic = struct {
    document: enum { manifest, resources, arguments } = .manifest,
    detail: A.Diagnostic = .{},
};
pub const Options = struct {
    /// Absolute invocation directory; library arguments resolve here.
    cwd: []const u8,
    /// Repeatable alias=path and alias=64-hex-digit arguments, without flag names.
    libraries: []const []const u8 = &.{},
    hashes: []const []const u8 = &.{},
    resource_limits: R.Limits = .{},
};
pub const Resolved = struct {
    arena: std.heap.ArenaAllocator,
    resources: R.authoring.Resolved,
    resource_path: []const u8,
    manifest_path: []const u8,
    catalog: B.Catalog,
    bindings: []const P.Binding,
    inputs: []const P.ProviderInput,
    manifest_skipped: []const A.Skipped,
    pub fn deinit(self: *@This()) void {
        self.resources.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
};
pub const Parsed = struct {
    decoded: A.Decoded(schema.AgentManifest),
    source_path: []const u8,
    pub fn deinit(self: *@This()) void {
        self.decoded.deinit();
        self.* = undefined;
    }
    /// Lexical path resolution deliberately permits nonexistent resource/library paths.
    pub fn resourcePath(self: *const @This(), a: std.mem.Allocator) ![]const u8 {
        return std.fs.path.resolve(a, &.{ std.fs.path.dirname(self.source_path) orelse self.source_path, self.decoded.value.resources });
    }
    pub fn resolve(self: *const @This(), alloc: std.mem.Allocator, resource_bytes: []const u8, options: Options, diag: *Diagnostic) !Resolved {
        diag.* = .{};
        var arena = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();
        const a = arena.allocator();
        const path = try self.resourcePath(a);
        if (resource_bytes.len > 256 * 1024) {
            diag.* = .{ .document = .resources, .detail = .{ .code = error.ResourceDocumentTooLarge } };
            return error.ResourceDocumentTooLarge;
        }
        var resource_diag: R.authoring.Diagnostic = .{};
        var parsed = R.authoring.parse(alloc, path, resource_bytes, &resource_diag) catch |err| {
            diag.* = .{ .document = .resources, .detail = resource_diag.detail };
            return err;
        };
        defer parsed.deinit();
        var resources = parsed.resolve(alloc, options.resource_limits, &resource_diag) catch |err| {
            diag.* = .{ .document = .resources, .detail = resource_diag.detail };
            return err;
        };
        errdefer resources.deinit();
        var ctx = Resolver{ .a = a, .parsed = self, .diag = diag };
        const inputs = ctx.inputs(options) catch |err| {
            diag.document = .arguments;
            if (diag.detail.code == null) diag.detail.code = err;
            return err;
        };
        diag.* = .{};
        const authored_bindings = elements(self.decoded.value.bindings);
        const bindings = try a.alloc(P.Binding, authored_bindings.len);
        for (authored_bindings, bindings, 0..) |b, *out, i| {
            const key = try std.fmt.allocPrint(a, "{d}", .{i});
            if (!validName(b.participant) or !validName(b.type_name) or !validName(b.provider)) return ctx.fail(error.InvalidBinding, &.{ "bindings", key });
            var found = false;
            for (inputs) |input| if (same(input.alias, b.provider)) {
                found = true;
            };
            if (!found) return ctx.fail(error.UnknownProvider, &.{ "bindings", key, "provider" });
            out.* = .{
                .participant = try a.dupe(u8, b.participant),
                .type_name = try a.dupe(u8, b.type_name),
                .source = .{ .provider = .{ .provider = try a.dupe(u8, b.provider), .name = try a.dupe(u8, b.type_name) } },
            };
            if (b.expected_identifier) |text| {
                out.expected_identifier = hex(15, text) catch return ctx.fail(error.InvalidIdentifier, &.{ "bindings", key, "expected_identifier" });
                if (out.expected_identifier.?[0] != 0xf1) return ctx.fail(error.InvalidIdentifier, &.{ "bindings", key, "expected_identifier" });
            }
            for (bindings[0..i]) |prior| if (same(prior.participant, b.participant) and same(prior.type_name, b.type_name)) return ctx.fail(error.DuplicateBinding, &.{ "bindings", key });
            const p = find(resources.plan.application.participants, b.participant) orelse return ctx.fail(error.UnknownBinding, &.{ "bindings", key, "participant" });
            _ = find(resources.plan.application.participants[p].types, b.type_name) orelse return ctx.fail(error.UnknownBinding, &.{ "bindings", key, "type_name" });
        }
        P.validate(&resources.plan, bindings, .{}) catch |err| return ctx.fail(err, &.{"bindings"});
        const authored = elements(self.decoded.value.catalog);
        const definitions = try a.alloc(B.Definition, authored.len);
        for (authored, definitions) |d, *out| {
            const prefix = &[_][]const u8{ "catalog", d.name };
            if (!validName(d.name) or !validName(d.participant) or !validName(d.resource)) return ctx.fail(error.InvalidDefinition, prefix);
            if (!self.decoded.isPresent(&.{ "catalog", d.name, "kind" })) return ctx.fail(error.MissingKind, &.{ "catalog", d.name, "kind" });
            const p = resources.plan.application.participants[find(resources.plan.application.participants, d.participant) orelse return ctx.fail(error.UnknownParticipant, &.{ "catalog", d.name, "participant" })];
            out.* = .{
                .name = try a.dupe(u8, d.name),
                .kind = switch (d.kind) {
                    .participant => .participant,
                    .topic => .topic,
                    .publisher => .publisher,
                    .datawriter => .datawriter,
                    else => return ctx.fail(error.UnsupportedObjectKind, prefix),
                },
                .participant = try a.dupe(u8, d.participant),
                .resource = try a.dupe(u8, d.resource),
                .parent = if (d.parent) |v| try a.dupe(u8, v) else null,
                .topic = if (d.topic) |v| try a.dupe(u8, v) else null,
            };
            switch (d.kind) {
                .participant => {
                    if (!same(p.name, d.resource)) return ctx.fail(error.UnknownResource, &.{ "catalog", d.name, "resource" });
                    out.domain = @intCast(p.domain_id);
                },
                .topic => {
                    const t = p.topics[find(p.topics, d.resource) orelse return ctx.fail(error.UnknownResource, &.{ "catalog", d.name, "resource" })];
                    out.topic_name = try a.dupe(u8, t.topic_name);
                },
                .publisher => {
                    _ = find(p.publishers, d.resource) orelse return ctx.fail(error.UnknownResource, &.{ "catalog", d.name, "resource" });
                },
                .datawriter => {
                    const e = p.writers[find(p.writers, d.resource) orelse return ctx.fail(error.UnknownResource, &.{ "catalog", d.name, "resource" })];
                    if (e.qos.data_representation != .XCDR2) return ctx.fail(error.UnsupportedRepresentation, &.{ "catalog", d.name, "resource" });
                    // Current loadable providers support bounded final types only.
                    // Preparation must verify the provider contract before serving.
                    out.encoding = .plain_cdr2_le;
                    const topic = p.topics[find(p.topics, e.topic_ref).?];
                    for (bindings) |*binding| if (same(binding.participant, p.name) and same(binding.type_name, topic.type_ref)) {
                        binding.require_wire_validation = true;
                        binding.required_representations |= 2;
                    };
                },
                else => return ctx.fail(error.UnsupportedObjectKind, prefix),
            }
        }
        const catalog: B.Catalog = .{ .definitions = definitions };
        // Validate each definition against all references, preserving its source path.
        for (definitions) |d| {
            const p = resources.plan.application.participants[find(resources.plan.application.participants, d.participant).?];
            if (d.kind == .participant) {
                if (d.parent != null or d.topic != null) return ctx.fail(error.InvalidDefinition, &.{ "catalog", d.name });
                continue;
            }
            const parent = definitions[find(definitions, d.parent orelse return ctx.fail(error.MissingParent, &.{ "catalog", d.name, "parent" })) orelse return ctx.fail(error.UnknownDefinition, &.{ "catalog", d.name, "parent" })];
            const parent_kind: @import("zz0_client").xrce.ObjectKind = if (d.kind == .datawriter) .publisher else .participant;
            if (parent.kind != parent_kind or !same(parent.participant, d.participant)) return ctx.fail(error.WrongParent, &.{ "catalog", d.name, "parent" });
            if (d.kind == .datawriter) {
                const t = definitions[find(definitions, d.topic orelse return ctx.fail(error.MissingTopic, &.{ "catalog", d.name, "topic" })) orelse return ctx.fail(error.UnknownDefinition, &.{ "catalog", d.name, "topic" })];
                if (t.kind != .topic or !same(t.participant, d.participant) or !optionalSame(t.parent, parent.parent)) return ctx.fail(error.WrongTopic, &.{ "catalog", d.name, "topic" });
                const e = p.writers[find(p.writers, d.resource).?];
                if (!same(e.container_ref, parent.resource)) return ctx.fail(error.WrongParent, &.{ "catalog", d.name, "parent" });
                if (!same(e.topic_ref, t.resource)) return ctx.fail(error.WrongTopic, &.{ "catalog", d.name, "topic" });
            } else if (d.topic != null) return ctx.fail(error.InvalidDefinition, &.{ "catalog", d.name, "topic" });
            // Named binary publishers select by resource name. Unnamed requests
            // still require a unique match at request time. Writers select by
            // public publisher + DDS topic name.
            for (definitions) |other| {
                if (same(other.name, d.name) or other.kind != d.kind or !optionalSame(other.parent, d.parent)) continue;
                if (d.kind == .publisher and same(other.resource, d.resource)) return ctx.fail(error.AmbiguousPublisher, &.{ "catalog", d.name });
                if (d.kind == .datawriter) {
                    const left = definitions[find(definitions, d.topic.?).?];
                    const right = definitions[find(definitions, other.topic orelse continue) orelse continue];
                    if (left.topic_name != null and right.topic_name != null and same(left.topic_name.?, right.topic_name.?)) return ctx.fail(error.AmbiguousWriter, &.{ "catalog", d.name });
                }
            }
        }
        catalog.validate() catch |err| return ctx.fail(err, &.{"catalog"});
        const skipped = try a.alloc(A.Skipped, self.decoded.skipped.len);
        for (self.decoded.skipped, skipped) |item, *out| {
            out.* = item;
            out.path = try copyPath(a, item.path);
            out.input_path = try copyPath(a, item.input_path);
        }
        return .{ .arena = arena, .resources = resources, .resource_path = path, .manifest_path = try a.dupe(u8, self.source_path), .catalog = catalog, .bindings = bindings, .inputs = inputs, .manifest_skipped = skipped };
    }
};

pub fn parse(a: std.mem.Allocator, source_path: []const u8, bytes: []const u8, diag: *Diagnostic) !Parsed {
    diag.* = .{};
    if (!std.fs.path.isAbsolute(source_path)) {
        diag.detail.code = error.ExpectedAbsolutePath;
        return error.ExpectedAbsolutePath;
    }
    if (bytes.len > 256 * 1024) {
        diag.detail.code = error.ManifestTooLarge;
        return error.ManifestTooLarge;
    }
    var syntax: dds.toml.Diagnostic = .{};
    var document = dds.toml.parseOwned(a, bytes, &syntax, .{}) catch |err| {
        diag.detail = .{ .code = err, .location = .{ .offset = syntax.location.offset, .line = syntax.location.line, .column = syntax.location.column } };
        return err;
    };
    defer document.deinit();
    var decoded = try schema.AgentManifest.decodeToml(a, document.table, .{ .named_field = "name", .conditional_members = true }, &diag.detail);
    errdefer decoded.deinit();
    const path = try decoded.arena.allocator().dupe(u8, source_path);
    const result: Parsed = .{ .decoded = decoded, .source_path = path };
    var ctx = Resolver{ .a = a, .parsed = &result, .diag = diag };
    if (decoded.value.schema_version != 1) return ctx.fail(error.UnsupportedSchema, &.{"schema_version"});
    if (decoded.value.resources.len == 0 or std.mem.indexOfScalar(u8, decoded.value.resources, 0) != null) return ctx.fail(error.InvalidResourcePath, &.{"resources"});
    if (!decoded.collectionIsNamed(&.{"catalog"})) return ctx.fail(error.ExpectedNamedCatalog, &.{"catalog"});
    if (elements(decoded.value.catalog).len > 128) return ctx.fail(error.CatalogLimit, &.{"catalog"});
    if (elements(decoded.value.bindings).len > 1024) return ctx.fail(error.BindingLimit, &.{"bindings"});
    return result;
}
const Resolver = struct {
    a: std.mem.Allocator,
    parsed: *const Parsed,
    diag: *Diagnostic,
    fn fail(self: *@This(), err: anyerror, path: []const []const u8) anyerror {
        self.diag.* = .{ .detail = .{ .code = err } };
        var n = path.len;
        while (true) {
            if (self.parsed.decoded.source(path[0..n])) |loc| {
                self.diag.detail.location = loc;
                break;
            }
            if (n == 0) break;
            n -= 1;
        }
        for (path, 0..) |part, i| {
            if (i != 0) self.append(".");
            self.append(part);
        }
        return err;
    }
    fn append(self: *@This(), text: []const u8) void {
        const d = &self.diag.detail;
        const n = @min(text.len, d.path.len - d.path_len);
        @memcpy(d.path[d.path_len..][0..n], text[0..n]);
        d.path_len += n;
        if (n != text.len) d.path_truncated = true;
    }
    fn argument(self: *@This(), flag: []const u8, index: usize) void {
        self.diag.* = .{ .document = .arguments };
        const text = std.fmt.bufPrint(&self.diag.detail.path, "{s}[{d}]", .{ flag, index }) catch unreachable;
        self.diag.detail.path_len = text.len;
    }
    fn inputs(self: *@This(), options: Options) ![]P.ProviderInput {
        if (!std.fs.path.isAbsolute(options.cwd)) return error.ExpectedAbsolutePath;
        if (options.libraries.len > 32) return error.ProviderLimit;
        if (options.hashes.len > 32) return error.ConstraintLimit;
        const result = try self.a.alloc(P.ProviderInput, options.libraries.len);
        for (options.libraries, result, 0..) |text, *out, i| {
            self.argument("--library", i);
            const parts = try pair(text);
            if (!validName(parts.name)) return error.InvalidProvider;
            for (result[0..i]) |prior| if (same(parts.name, prior.alias)) return error.DuplicateProvider;
            if (std.mem.indexOfScalar(u8, parts.value, 0) != null) return error.InvalidLibraryPath;
            out.* = .{ .alias = try self.a.dupe(u8, parts.name), .source = .{ .library = try std.fs.path.resolve(self.a, &.{ options.cwd, parts.value }) } };
        }
        for (options.hashes, 0..) |text, i| {
            self.argument("--sha256", i);
            const parts = try pair(text);
            for (options.hashes[0..i]) |prior| if (same((try pair(prior)).name, parts.name)) return error.DuplicateConstraint;
            const index = findAlias(result, parts.name) orelse return error.UnknownProviderConstraint;
            result[index].expected_sha256 = try hex(32, parts.value);
        }
        return result;
    }
};
fn elements(seq: anytype) []const rt.SeqElem(@TypeOf(seq)) {
    return if (seq._buffer) |buf| buf[0..seq._length] else &.{};
}
fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn optionalSame(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return same(a.?, b.?);
}
fn validName(name: []const u8) bool {
    return name.len > 0 and name.len <= 128 and std.mem.indexOfScalar(u8, name, 0) == null;
}
fn find(items: anytype, name: []const u8) ?usize {
    for (items, 0..) |item, i| if (same(item.name, name)) return i;
    return null;
}
fn findAlias(items: []const P.ProviderInput, name: []const u8) ?usize {
    for (items, 0..) |item, i| if (same(item.alias, name)) return i;
    return null;
}
fn pair(text: []const u8) !struct { name: []const u8, value: []const u8 } {
    const n = std.mem.indexOfScalar(u8, text, '=') orelse return error.ExpectedAliasPair;
    if (n == 0 or n + 1 == text.len) return error.EmptyAliasPair;
    return .{ .name = text[0..n], .value = text[n + 1 ..] };
}
fn hex(comptime n: usize, text: []const u8) ![n]u8 {
    if (text.len != n * 2) return error.InvalidHexLength;
    var bytes: [n]u8 = undefined;
    _ = try std.fmt.hexToBytes(&bytes, text);
    return bytes;
}
fn copyPath(a: std.mem.Allocator, path: []const []const u8) ![]const []const u8 {
    const result = try a.alloc([]const u8, path.len);
    for (path, result) |part, *out| out.* = try a.dupe(u8, part);
    return result;
}
