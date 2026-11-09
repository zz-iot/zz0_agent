const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sanitize_thread = b.option(bool, "sanitize-thread", "Instrument the agent and DDS backend with ThreadSanitizer") orelse false;
    const dds_dep = b.dependency("zzdds", .{
        .target = target,
        .optimize = optimize,
        .@"resource-construction" = true,
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
        .imports = &.{
            .{ .name = "zz0_client", .module = zz0_client_dep.module("zz0_client") },
            .{ .name = "zidl_rt", .module = zidl_rt_mod },
            .{ .name = "counter_types", .module = counter_types_mod },
            .{ .name = "zzdds", .module = dds_dep.module("zzdds") },
        },
    });

    mod.sanitize_thread = sanitize_thread;

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

    const gen_encoding = if (zidl_exe) |path| b.addSystemCommand(&.{path}) else b.addRunArtifact(dds_dep.artifact("zidl"));
    gen_encoding.addArgs(&.{ "-b", "zig", "--no-typeobject-support", "-o" });
    const encoding_dir = gen_encoding.addOutputDirectoryArg("modern-encoding");
    gen_encoding.addFileArg(b.path("test/modern_encoding.idl"));
    mod.addImport("encoding_fixture", b.createModule(.{
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
    mod.addImport("counter_provider", b.createModule(.{
        .root_source_file = provider_dir.path(b, "counter_types_typesupport.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "types", .module = provider_types }, .{ .name = "zidl_rt", .module = zidl_rt_mod }, .{ .name = "zidl_typesupport", .module = dds_dep.module("zidl_typesupport") } },
    }));

    const tests = b.addTest(.{
        .use_llvm = if (sanitize_thread) true else null,
        .root_module = mod,
    });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run zz0_agent tests");
    test_step.dependOn(&run_tests.step);
}
