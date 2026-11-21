const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode (default ReleaseFast)") orelse .ReleaseFast;

    const exe = b.addExecutable(.{
        .name = "vinyl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run vinyl");
    run_step.dependOn(&run_cmd.step);

    const home = std.posix.getenv("HOME") orelse "/tmp";
    const local_dest = b.fmt("{s}/.local/bin/vinyl", .{home});
    const inst_cmd = b.addSystemCommand(&.{ "install", "-Dm755" });
    inst_cmd.addArtifactArg(exe);
    inst_cmd.addArg(local_dest);
    const install_local = b.step("install-local", "Install vinyl binary to ~/.local/bin/vinyl");
    install_local.dependOn(b.getInstallStep());
    install_local.dependOn(&inst_cmd.step);
}
