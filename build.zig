const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zidl_dep = b.dependency("zidl", .{
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
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
    const zidl_rt_mod = b.createModule(.{
        .root_source_file = zidl_dep.path("packages/zidl-rt/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const gen_counter_types = if (zidl_exe) |path| b.addSystemCommand(&.{path}) else b.addRunArtifact(zidl_dep.artifact("zidl"));
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
        },
    });

    const exe = b.addExecutable(.{
        .name = "zz0_agent",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zz0_agent", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    const tests = b.addTest(.{
        .root_module = mod,
    });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run zz0_agent tests");
    test_step.dependOn(&run_tests.step);
}
