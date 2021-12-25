const std = @import("std");
const os = std.os;
const print = std.debug.print;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;

const Context = struct {
  compositor: ?*wl.Compositor,
  shm: ?*wl.Shm,
  xdg: ?*xdg.WmBase,
};

const GridSurface = struct {
  width: usize,
  height: usize,
  data: []u8,
};

fn registryListner(registry: *wl.Registry,
                   event: wl.Registry.Event,
                   ctx: *Context) void {
 switch (event) {
    .global => |g| {
      // print("interface: {s},\tversion: {},\tname: {}\n", .{g.interface, g.version, g.name});
      if (std.cstr.cmp(g.interface, wl.Compositor.getInterface().name) == 0) {
        print("Got Compositor\n", .{});
        ctx.compositor = registry.bind(g.name, wl.Compositor, 4) catch return;
      } else if (std.cstr.cmp(g.interface, wl.Shm.getInterface().name) == 0) {
        print("Got Shm\n", .{});
        ctx.shm = registry.bind(g.name, wl.Shm, 1) catch return;
      } else if (std.cstr.cmp(g.interface, xdg.WmBase.getInterface().name) == 0) {
        print("Got XdgWmBase\n", .{});
        ctx.xdg = registry.bind(g.name, xdg.WmBase, 1) catch return;
      }
    },
    .global_remove => |_| {print("Global remove event\n", .{});},
  }
}

fn surfaceListener(xdg_surface: *xdg.Surface,
                   event: xdg.Surface.Event,
                   surface: *wl.Surface) void {
  print("surfaceListener: {}\n", .{event});
  switch (event) {
    .configure => |configure| {
      xdg_surface.ackConfigure(configure.serial);
      surface.commit();
    }
  }
}

fn topLevelListener(_: *xdg.Toplevel, event: xdg.Toplevel.Event, running: *bool) void {
  print("top level event: {}\n", .{event});
  switch (event) {
    .close => running.* = false,
    .configure => {} // TODO
  }
}

fn baseListener(base: *xdg.WmBase, event: xdg.WmBase.Event, running: *bool) void {
  print("base event: {}\n", .{event});
  _ = running;
  _ = base;
  switch (event) {
    .ping => |ping| {
      base.pong(ping.serial);
    }
  }
}

fn drawGrid(ctx: GridSurface) void {
  const size = @maximum(ctx.width, ctx.height) / 5;
  // TODO: assert data.length = size
  print("size: {}, length: {}\n", .{size, size});
  var y: usize = 0;
  while (y < ctx.height) {
    var x: usize = 0;
    while (x < ctx.height) {
      ctx.data[(y * ctx.width + x) * 4] = if (y % (2*size) > size) 0xFF else 0x00; // blue
      ctx.data[(y * ctx.width + x) * 4 + 1] = if (x % (2*size) > size) 0xFF else 0x00; // green
      ctx.data[(y * ctx.width + x) * 4 + 2] = 0x00; // red
      ctx.data[(y * ctx.width + x) * 4 + 3] = 0xFF; // alpha
      x+=1;
    }
    y+=1;
  }
}

pub fn main() anyerror!void {
  print("Starting\n", .{});

  const wl_display = try wl.Display.connect(null);
  defer wl_display.disconnect();
  const registry = try wl_display.getRegistry();
  print("Connected\n", .{});

  var ctx = Context {
    .compositor = null,
    .shm        = null,
    .xdg        = null,
  };

  registry.setListener(*Context, registryListner, &ctx);
  _ = try wl_display.roundtrip();

  const compositor = ctx.compositor orelse return error.NoWlCompositor;
  const shm        = ctx.shm orelse return error.NoWlShm;
  const xdg_wm_base    = ctx.xdg orelse return error.NoXdgBase;

  // Create a shared memory pool, I'm just going to accept the magic for now
  const width = 128;
  const height = 128;
  const stride = width * 4;
  const buf_size = stride * height;

  const fd = try os.memfd_create("zig-ime", 0);
  try os.ftruncate(fd, buf_size);
  const data = try os.mmap(
    null, buf_size,
    os.PROT.READ | os.PROT.WRITE,
    os.MAP.SHARED, fd, 0);

  const gridSurface = GridSurface {
    .height = height,
    .width = width,
    .data = data,
  };
  drawGrid(gridSurface);

  const pool = try shm.createPool(fd , buf_size);
  defer pool.destroy();

  const buffer = blk: {
    break :blk try pool.createBuffer(0, width, height, stride,
                                     wl.Shm.Format.argb8888);
  };
  defer buffer.destroy();

  const surface = try compositor.createSurface();
  defer surface.destroy();
  const xdg_surface = try xdg_wm_base.getXdgSurface(surface);
  defer xdg_surface.destroy();
  const xdg_toplevel = try xdg_surface.getToplevel();
  defer xdg_toplevel.destroy();
  surface.commit();

  var running = true;
  xdg_wm_base.setListener(*bool, baseListener, &running);
  xdg_surface.setListener(*wl.Surface, surfaceListener, surface);
  xdg_toplevel.setListener(*bool, topLevelListener, &running);
  _ = try wl_display.roundtrip();

  print("Attaching buffer\n", .{});
  surface.attach(buffer, 0, 0);
  // TODO: use uint32 max
  surface.damage(0, 0, 2^32, 2^32);
  surface.commit();

  print("Running main loop\n", .{});
  while (running) {
    print("Main loop iteraton\n", .{});
    _ = try wl_display.dispatch();
  }
  print("Exiting\n", .{});
}
