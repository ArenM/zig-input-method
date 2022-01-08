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

  //
  // input-method connector
  //
  const inputMethod = b.addExecutable("input-method", "input-method.zig");
  inputMethod.setTarget(target);
  inputMethod.setBuildMode(mode);

  inputMethod.step.dependOn(&scanner.step);
  inputMethod.addPackage(wayland);
  inputMethod.linkLibC();
  inputMethod.linkSystemLibrary("wayland-client");

  scanner.addCSource(inputMethod);
  inputMethod.install();

  // run with: zig build run
  const im_run = inputMethod.run();
  im_run.step.dependOn(b.getInstallStep());
  const im_run_step = b.step("run-im", "Run the input method bridge");
  im_run_step.dependOn(&im_run.step);

  //
  // Item selector executable
  //
  const selector = b.addExecutable("selector", "main.zig");
  selector.setTarget(target);
  selector.setBuildMode(mode);

  selector.step.dependOn(&scanner.step);
  selector.addPackage(wayland);
  selector.linkLibC();
  selector.linkSystemLibrary("wayland-client");

  scanner.addCSource(selector);
  selector.install();

  // run with: zig build run
  const run_selector = selector.run();
  run_selector.step.dependOn(b.getInstallStep());
  const run_step = b.step("run-selector", "Run the gui word selector");
  run_step.dependOn(&run_selector.step);
}
