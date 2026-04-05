const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("ReservedBumpAllocator", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const is_browser_wasm = target.result.cpu.arch == .wasm32 and target.result.os.tag == .freestanding;
    const exe_name = if (is_browser_wasm) "reserved_bump_allocator_test" else "ReservedBumpAllocator";
    const exe_root = if (is_browser_wasm) "src/wasm.zig" else "src/main.zig";
    const exe = b.addExecutable(.{
        .name = exe_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(exe_root),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ReservedBumpAllocator", .module = mod },
            },
        }),
    });
    if (is_browser_wasm) {
        exe.entry = .disabled;
        exe.rdynamic = true;
        exe.export_memory = true;
        exe.initial_memory = 2 * 1024 * 1024;
        exe.max_memory = 2 * 1024 * 1024;
    }

    b.installArtifact(exe);

    if (!is_browser_wasm) {
        const run_step = b.step("run", "Run the app");
        const run_cmd = b.addRunArtifact(exe);
        run_step.dependOn(&run_cmd.step);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = wasm_target,
    });
    const wasm_exe = b.addExecutable(.{
        .name = "reserved_bump_allocator_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm.zig"),
            .target = wasm_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ReservedBumpAllocator", .module = wasm_mod },
            },
        }),
    });
    wasm_exe.entry = .disabled;
    wasm_exe.rdynamic = true;
    wasm_exe.export_memory = true;
    wasm_exe.initial_memory = 2 * 1024 * 1024;
    wasm_exe.max_memory = 2 * 1024 * 1024;

    const install_wasm = b.addInstallArtifact(wasm_exe, .{});
    const wasm_step = b.step("wasm", "Build the browser wasm smoke test");
    wasm_step.dependOn(&install_wasm.step);
}
