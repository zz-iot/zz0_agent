const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sanitize_thread = b.option(bool, "sanitize-thread", "Instrument the agent and DDS backend with ThreadSanitizer") orelse false;
    const dds_dep = b.dependency("zzdds", .{
        .target = target,
        .optimize = optimize,
        .@"resource-construction" = true,
        .@"resource-authoring" = true,
        .@"typesupport-library" = true,
        .@"sanitize-thread" = sanitize_thread,
    });
    const zidl_exe = b.option(
        []const u8,
        "zidl",
        "Path to a prebuilt zidl executable",
    );
    const counter_idl = b.option(
        []const u8,
        "counter-idl",
        "Path to the demo CounterStatus IDL",
    ) orelse "../zz0-pico-demo/idl/counter_types.idl";

    const zz0_client_dep = b.dependency("zz0_client", .{
        .target = target,
        .optimize = optimize,
    });
    const zidl_rt_mod = dds_dep.module("zidl_rt");

    const gen_counter_types = if (zidl_exe) |path| b.addSystemCommand(&.{path}) else b.addRunArtifact(dds_dep.artifact("zidl"));
    gen_counter_types.addArgs(&.{ "-b", "zig" });
    gen_counter_types.addArgs(&.{
        "--profile",               "xrce",
        "--no-typeobject-support", "-o",
    });
    const gen_counter_types_dir = gen_counter_types.addOutputDirectoryArg("zz0_agent-counter-generated");
    gen_counter_types.addFileArg(.{ .cwd_relative = counter_idl });

    const counter_types_mod = b.createModule(.{
        .root_source_file = gen_counter_types_dir.path(b, "counter_types.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zidl_rt", .module = zidl_rt_mod },
        },
    });

    const mod = b.addModule("zz0_agent", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .imports = &.{
            .{ .name = "zz0_client", .module = zz0_client_dep.module("zz0_client") },
            .{ .name = "zzdds", .module = dds_dep.module("zzdds") },
        },
    });
    const gen_manifest = b.addRunArtifact(dds_dep.artifact("zidl"));
    gen_manifest.addArgs(&.{ "-b", "zig", "--single-file", "--zig-generate-authoring", "--no-typesupport", "--no-typeobject-support", "-o" });
    const manifest_dir = gen_manifest.addOutputDirectoryArg("agent-config");
    gen_manifest.addFileArg(b.path("idl/agent_config.idl"));
    mod.addImport("agent_config_generated", b.createModule(.{
        .root_source_file = manifest_dir.path(b, "agent_config.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .imports = &.{.{ .name = "zidl_rt", .module = zidl_rt_mod }},
    }));
    mod.addImport("zidl_rt", zidl_rt_mod);
    // Explicit sample/compatibility fixtures; absent from the normal executable.
    const fixture_mod = b.createModule(.{
        .root_source_file = b.path("src/fixture_root.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .imports = &.{
            .{ .name = "zz0_agent_core", .module = mod },
            .{ .name = "zz0_client", .module = zz0_client_dep.module("zz0_client") },
            .{ .name = "zidl_rt", .module = zidl_rt_mod },
            .{ .name = "counter_types", .module = counter_types_mod },
            .{ .name = "zzdds", .module = dds_dep.module("zzdds") },
        },
    });

    const exe = b.addExecutable(.{
        .name = "zz0_agent",
        .use_llvm = if (sanitize_thread) true else null,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zz0_agent", .module = mod },
                .{ .name = "zzdds", .module = dds_dep.module("zzdds") },
            },
        }),
    });
    exe.root_module.sanitize_thread = sanitize_thread;
    b.installArtifact(exe);
    const version = b.addOptions();
    version.addOption([]const u8, "version", @import("build.zig.zon").version);
    exe.root_module.addOptions("agent_build", version);
    const fixtures = b.step("fixtures", "Build the compatibility executable and CounterStatus provider library");
    const compat = b.addExecutable(.{
        .name = "zz0_agent_compat",
        .use_llvm = if (sanitize_thread) true else null,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fixtures/main.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
            .imports = &.{.{ .name = "zz0_agent", .module = fixture_mod }},
        }),
    });
    fixtures.dependOn(&b.addInstallArtifact(compat, .{}).step);

    const gen_encoding = if (zidl_exe) |path| b.addSystemCommand(&.{path}) else b.addRunArtifact(dds_dep.artifact("zidl"));
    gen_encoding.addArgs(&.{ "-b", "zig", "--no-typeobject-support", "-o" });
    const encoding_dir = gen_encoding.addOutputDirectoryArg("modern-encoding");
    gen_encoding.addFileArg(b.path("test/modern_encoding.idl"));
    fixture_mod.addImport("encoding_fixture", b.createModule(.{
        .root_source_file = encoding_dir.path(b, "modern_encoding.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zidl_rt", .module = zidl_rt_mod }},
    }));

    const gen_provider = b.addRunArtifact(dds_dep.artifact("zidl"));
    gen_provider.addArgs(&.{ "-b", "zig", "--experimental-typesupport-library", "-o" });
    const provider_dir = gen_provider.addOutputDirectoryArg("counter-provider");
    gen_provider.addFileArg(.{ .cwd_relative = counter_idl });
    const provider_types = b.createModule(.{ .root_source_file = provider_dir.path(b, "counter_types.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "zidl_rt", .module = zidl_rt_mod }} });
    fixture_mod.addImport("counter_provider", b.createModule(.{
        .root_source_file = provider_dir.path(b, "counter_types_typesupport.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "types", .module = provider_types }, .{ .name = "zidl_rt", .module = zidl_rt_mod }, .{ .name = "zidl_typesupport", .module = dds_dep.module("zidl_typesupport") } },
    }));

    // As in zzdds's provider tests, instrument the host, not dlopen fixtures:
    // Zig embeds a second TSan runtime into instrumented DSOs (initial-exec TLS).
    const abi = dds_dep.module("zidl_typesupport");
    const library_rt = if (sanitize_thread) b.createModule(.{ .root_source_file = zidl_rt_mod.root_source_file, .target = target, .optimize = optimize, .sanitize_thread = false }) else zidl_rt_mod;
    const library_abi = if (sanitize_thread) b.createModule(.{
        .root_source_file = abi.root_source_file,
        .target = target,
        .optimize = optimize,
        .sanitize_thread = false,
        .imports = &.{ .{ .name = "zidl_rt", .module = library_rt }, .{ .name = "zidl_typesupport_c", .module = abi.import_table.get("zidl_typesupport_c").? } },
    }) else abi;
    const counter_library = addProviderLibrary(b, provider_dir, "counter_types", library_rt, library_abi, target, optimize);
    fixtures.dependOn(&b.addInstallArtifact(counter_library, .{}).step);

    const fixture_paths = b.addOptions();
    fixture_paths.addOptionPath("manifest", b.path("examples/counter/agent.toml"));
    fixture_paths.addOptionPath("library", counter_library.getEmittedBin());
    const root_path = b.root.joinString(b.allocator, ".") catch @panic("out of memory");
    const absolute_root = std.Io.Dir.cwd().realPathFileAlloc(b.graph.io, root_path, b.allocator) catch @panic("cannot resolve fixture root");
    fixture_paths.addOption([]const u8, "cwd", absolute_root);
    fixture_mod.addOptions("fixture_paths", fixture_paths);

    const startup_checks = b.addSystemCommand(&.{ "python3", "interop/startup.py", "--agent" });
    startup_checks.addFileArg(exe.getEmittedBin());
    startup_checks.addArg("--config");
    startup_checks.addFileArg(b.path("examples/counter/agent.toml"));
    startup_checks.addArg("--library");
    startup_checks.addFileArg(counter_library.getEmittedBin());
    b.step("test-startup", "Check configured CLI, library inspection and startup failures").dependOn(&startup_checks.step);

    const multi_consumer = b.addExecutable(.{
        .name = "multi-library-consumer",
        .use_llvm = if (sanitize_thread) true else null,
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/multi_library/consumer.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
            .link_libc = true,
            .imports = &.{ .{ .name = "zz0_agent", .module = mod }, .{ .name = "zzdds", .module = dds_dep.module("zzdds") }, .{ .name = "zidl_rt", .module = zidl_rt_mod } },
        }),
    });
    const multi = b.addSystemCommand(&.{ "python3", "interop/multi_library.py", "--agent" });
    multi.addFileArg(exe.getEmittedBin());
    multi.addArg("--consumer");
    multi.addFileArg(multi_consumer.getEmittedBin());
    multi.addArg("--config");
    multi.addFileArg(b.path("test/multi_library/agent.toml"));
    for ([_][]const u8{ "project_a", "project_b", "conflict" }) |name| {
        const gen = b.addRunArtifact(dds_dep.artifact("zidl"));
        gen.addArgs(&.{ "-b", "zig", "--experimental-typesupport-library", "-o" });
        const dir = gen.addOutputDirectoryArg(name);
        gen.addFileArg(b.path(b.fmt("test/multi_library/{s}.idl", .{name})));
        const library = addProviderLibrary(b, dir, name, library_rt, library_abi, target, optimize);
        multi.addArg(if (std.mem.eql(u8, name, "project_a")) "--project-a" else if (std.mem.eql(u8, name, "project_b")) "--project-b" else "--conflict");
        multi.addFileArg(library.getEmittedBin());
    }
    multi.addArg("--logs");
    multi.addArg(b.option([]const u8, "multi-library-logs", "Directory for multi-library qualification logs") orelse ".zig-cache/multi-library-logs");
    b.step("test-multi-library", "Qualify independently generated providers, DDS receipt and client recovery").dependOn(&multi.step);

    const tests = b.addTest(.{
        .use_llvm = if (sanitize_thread) true else null,
        .root_module = mod,
    });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run zz0_agent tests");
    test_step.dependOn(&run_tests.step);
    const fixture_tests = b.addTest(.{
        .root_module = fixture_mod,
        .use_llvm = if (sanitize_thread) true else null,
    });
    b.step("test-fixtures", "Run CounterStatus, real DDS and compatibility regressions").dependOn(&b.addRunArtifact(fixture_tests).step);
}

fn addProviderLibrary(b: *std.Build, dir: std.Build.LazyPath, stem: []const u8, rt: *std.Build.Module, abi: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const types = b.createModule(.{ .root_source_file = dir.path(b, b.fmt("{s}.zig", .{stem})), .target = target, .optimize = optimize, .sanitize_thread = false, .imports = &.{.{ .name = "zidl_rt", .module = rt }} });
    const provider = b.createModule(.{
        .root_source_file = dir.path(b, b.fmt("{s}_typesupport.zig", .{stem})),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = false,
        .imports = &.{ .{ .name = "types", .module = types }, .{ .name = "zidl_rt", .module = rt }, .{ .name = "zidl_typesupport", .module = abi } },
    });
    return b.addLibrary(.{ .name = stem, .linkage = .dynamic, .use_llvm = true, .root_module = provider });
}
