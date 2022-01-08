const std = @import("std");
const Builder = std.build.Builder;
const ScanProtocolsStep = @import("deps/zig-wayland/build.zig").ScanProtocolsStep;

pub fn build(b: *Builder) void {
  const target = b.standardTargetOptions(.{});
  const mode = b.standardReleaseOptions();

  const scanner = ScanProtocolsStep.create(b);
  scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
  scanner.addSystemProtocol("unstable/text-input/text-input-unstable-v3.xml");
  scanner.addProtocolPath("input-method-unstable-v2.xml");

  const wayland = std.build.Pkg{
    .name = "wayland",
    .path = .{ .generated = &scanner.result },
  };

  // TODO: build both the gui and the input-method connector
  const exe = b.addExecutable("zig-input-method", "input-method.zig");
  exe.setTarget(target);
  exe.setBuildMode(mode);

  exe.step.dependOn(&scanner.step);
  exe.addPackage(wayland);
  exe.linkLibC();
  exe.linkSystemLibrary("wayland-client");

  scanner.addCSource(exe);

  exe.install();

  // run with: zig build run
  const run_cmd = exe.run();
  run_cmd.step.dependOn(b.getInstallStep());

  const run_step = b.step("run", "Run the app");
  run_step.dependOn(&run_cmd.step);
}
