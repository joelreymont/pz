const std = @import("std");
const pkg = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build options: version, git hash, changelog
    const options = b.addOptions();
    options.addOption([]const u8, "version", pkg.version);

    var code: u8 = 0;
    const git_hash_raw = b.runAllowFail(
        &.{ "git", "rev-parse", "--short", "HEAD" },
        &code,
        .Ignore,
    ) catch "unknown";
    const git_hash = std.mem.trimRight(u8, git_hash_raw, "\n\r ");
    options.addOption([]const u8, "git_hash", git_hash);

    const git_log_raw = b.runAllowFail(
        &.{ "git", "log", "--oneline", "--no-decorate", "-n", "50" },
        &code,
        .Ignore,
    ) catch "No commit history available";
    const git_log = std.mem.trimRight(u8, git_log_raw, "\n\r ");
    options.addOption([]const u8, "changelog", git_log);

    const exe = b.addExecutable(.{
        .name = "pz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addOptions("build_options", options);
    b.installArtifact(exe);

    const build_step = b.step("build", "Build the executable");
    build_step.dependOn(&exe.step);
    b.default_step.dependOn(build_step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.stdio = .inherit;
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run pz");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    if (b.lazyDependency("ohsnap", .{
        .target = target,
        .optimize = optimize,
    })) |ohsnap_dep| {
        exe_tests.root_module.addImport("ohsnap", ohsnap_dep.module("ohsnap"));
    }
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const suite_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/all_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    suite_tests.root_module.addOptions("build_options", options);
    if (b.lazyDependency("ohsnap", .{
        .target = target,
        .optimize = optimize,
    })) |ohsnap_dep| {
        suite_tests.root_module.addImport("ohsnap", ohsnap_dep.module("ohsnap"));
    }
    const run_suite_tests = b.addRunArtifact(suite_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_suite_tests.step);

    const check_step = b.step("check", "Compile executable and tests");
    check_step.dependOn(&exe.step);
    check_step.dependOn(&exe_tests.step);
    check_step.dependOn(&suite_tests.step);
}
