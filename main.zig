const std = @import("std");
const os = std.os;
const print = std.debug.print;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;

const default_width = 150;
const default_height = 150;
const default_stride = default_width * 4;

const WlGlobals = struct {
  compositor: ?*wl.Compositor,
  shm: ?*wl.Shm,
  xdg: ?*xdg.WmBase,
};

const Context = struct {
  width: usize,
  height: usize,
  // TODO: store a globals object instead
  shm: *wl.Shm,
  buffers: [2]DisplayBuffer,
  running: bool,
  configured: bool,
  surface: *wl.Surface,
  toplevel: *const xdg.Toplevel,
};

const DisplayBuffer = struct {
  width: usize,
  height: usize,
  busy: bool,
  shm_fd: i32,
  shm_pool: *wl.ShmPool,
  data: []align(4096) u8,
  wl_buffer: *wl.Buffer,
};

// Used to get wayland globals
fn registryListner(registry: *wl.Registry,
                   event: wl.Registry.Event,
                   ctx: *WlGlobals) void {
  switch (event) {
    .global => |g| {
      // print("interface: {s},\tversion: {},\tname: {}\n", .{g.interface, g.version, g.name});
      // TODO: use a lookup table for this
      if (std.cstr.cmp(g.interface, wl.Compositor.getInterface().name) == 0) {
        print("Got {s}\n", .{wl.Compositor.getInterface().name});
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

// Ack the configure event
fn surfaceListener(xdg_surface: *xdg.Surface,
                   event: xdg.Surface.Event,
                   ctx: *Context) void {
  print("surfaceListener: {}\n", .{event});
  switch (event) {
    .configure => |configure| {
      print("Ack configure\n", .{});
      ctx.configured = true;
      xdg_surface.ackConfigure(configure.serial);
      render(ctx);
    }
  }
}

// Resize, and Close events
fn topLevelListener(_: *xdg.Toplevel,
                    event: xdg.Toplevel.Event,
                    ctx: *Context) void {
  switch (event) {
    .close => ctx.running = false,
    .configure => |config| { // resize event
      print("resize from {}\n", .{ctx.height});

      // If these are zero defaults will be set when we get the next buffer
      ctx.height = @intCast(usize, config.height);
      ctx.width = @intCast(usize, config.width);
    }
  }
}

// Let the compositor know we're not deadlocked
fn baseListener(wm: *xdg.WmBase, event: xdg.WmBase.Event, _: *Context) void {
  print("base event: {}\n", .{event});
  switch (event) {
    .ping => |ping| {
      wm.pong(ping.serial);
    }
  }
}

// Buffer release
fn bufListener(_: *wl.Buffer, event: wl.Buffer.Event, buffer: *DisplayBuffer) void {
  switch (event) {
    .release => |_| {
      print("Buffer released\n", .{});
      buffer.busy = false;
    }
  }
}

// Draw a test grid to the provided buffer
fn drawGrid(buf: *DisplayBuffer) void {
  const size = @minimum(buf.width, buf.height) / 10;
  print("Drawing to buffer at: {*}\n", .{buf.data});

  var y: usize = 0;
  while (y < buf.height) {
    var x: usize = 0;
    const yc = (y % (2*size) > size);
    while (x < buf.width) {
      const xc = (x % (2*size) > size);
      buf.data[(y * buf.width + x) * 4] = if (yc or xc) 0xFF else 0x00; // blue
      buf.data[(y * buf.width + x) * 4 + 1] = if (yc) 0xFF else 0x00; // green
      buf.data[(y * buf.width + x) * 4 + 2] = if (yc or xc) 0xFF else 0x00; // red
      buf.data[(y * buf.width + x) * 4 + 3] = 0xFF; // alpha
      x+=1;
    }
    y+=1;
  }
}

// How this works:
// - Search for a buffer that isn't in use
//  - Resize it if necessary
//
// variable:	lifetime:		description:
// fd:		applicatin lifetime	backign file descriptor
// data:	applicatin lifetime	pointer to mmaped fd
// pool:	applicatin lifetime	backing memory
// buffer:	a frame (reusable)	portion of pool to display
// note: The pool must be replaced with a new one in order to shrink it
fn getBuffer(ctx: *Context) !*DisplayBuffer {
  if (ctx.width == 0) ctx.width = default_width;
  if (ctx.height == 0) ctx.height = default_height;

  const width = ctx.width;
  const height = ctx.height;
  const stride = ctx.width * 4;
  const buf_size = width * height * 4;

  // TODO: use ctx.next
  // - set it when a buffer is released
  // - unset it here
  const buffer: *DisplayBuffer = blk: {
    if (!ctx.buffers[0].busy) break :blk &ctx.buffers[0]
    else if (!ctx.buffers[1].busy) break :blk &ctx.buffers[1]
    else return error.NoBufAvailable;
  };

  if (ctx.width != buffer.width or ctx.height != buffer.height) {
    print("Buffer needs a resize\n", .{});
    buffer.wl_buffer.destroy();

    // If the window needs to get bigger
    if (buffer.data.len < buf_size) {
      try os.ftruncate(buffer.shm_fd, buf_size);
      os.munmap(buffer.data);
      buffer.data = try os.mmap(
        null, buf_size,
        os.PROT.READ | os.PROT.WRITE,
        os.MAP.SHARED, buffer.shm_fd, 0);
      buffer.shm_pool.resize(@intCast(i32, buf_size));
    }

    buffer.width = width;
    buffer.height = height;

    buffer.wl_buffer = try buffer.shm_pool.createBuffer(
      0, @intCast(i32, buffer.width),
      @intCast(i32, buffer.height),
      @intCast(i32, stride),
      wl.Shm.Format.argb8888);
    buffer.wl_buffer.setListener(*DisplayBuffer, bufListener, buffer);
  }

  return buffer;
}

// Render a frame, includes (re)allocating buffers
fn render(ctx: *Context) void {
  print("Rendering\n", .{});
  if (!ctx.configured) return;

  var buffer = getBuffer(ctx) catch return;

  drawGrid(buffer);
  buffer.busy = true;
  ctx.surface.attach(buffer.wl_buffer, 0, 0);
  ctx.surface.damage(0, 0, 2^32, 2^32);
  ctx.surface.commit();
}

fn makeEmptyBuf(shm: *wl.Shm) !DisplayBuffer {
  const buf_size = default_stride * default_height;
  const fd = try os.memfd_create("wayland-backing", 0);

  try os.ftruncate(fd, buf_size);
  // TODO: try const data = @bitCast([]u32, data);
  const data = try os.mmap(
    null, buf_size,
    os.PROT.READ | os.PROT.WRITE,
    os.MAP.SHARED, fd, 0);
  const pool = try shm.createPool(fd , @intCast(i32, default_stride * default_height));

  // create or resize only
  const wl_buffer = try pool.createBuffer(
    0, @intCast(i32, default_width),
    @intCast(i32, default_height),
    @intCast(i32, default_stride),
    wl.Shm.Format.argb8888);

  var buffer = DisplayBuffer {
    .height = default_height,
    .width = default_width,
    .shm_fd = fd,
    .shm_pool = pool,
    .busy = false,
    .wl_buffer = wl_buffer,
    .data = data,
  };
  wl_buffer.setListener(*DisplayBuffer, bufListener, &buffer);

  return buffer;
}

pub fn main() anyerror!void {
  print("Starting\n", .{});

  const wl_display = try wl.Display.connect(null);
  defer wl_display.disconnect();
  const registry = try wl_display.getRegistry();
  print("Connected\n", .{});

  var wl_globals = WlGlobals {
    .compositor = null,
    .shm        = null,
    .xdg        = null,
  };

  registry.setListener(*WlGlobals, registryListner, &wl_globals);
  _ = try wl_display.roundtrip();

  const compositor  = wl_globals.compositor orelse return error.NoWlCompositor;
  const shm         = wl_globals.shm orelse return error.NoWlShm;
  const xdg_wm_base = wl_globals.xdg orelse return error.NoXdgBase;

  const surface = try compositor.createSurface();
  defer surface.destroy();
  const xdg_surface = try xdg_wm_base.getXdgSurface(surface);
  defer xdg_surface.destroy();
  const toplevel = try xdg_surface.getToplevel();
  defer toplevel.destroy();
  surface.commit();

  var appCtx = Context {
    .height = 0,
    .width = 0,
    .buffers = .{try makeEmptyBuf(shm), try makeEmptyBuf(shm)},
    .shm = shm,
    .surface = surface,
    .toplevel = toplevel,
    .configured = false,
    .running = true,
  };

  xdg_wm_base.setListener(*Context, baseListener, &appCtx);
  xdg_surface.setListener(*Context, surfaceListener, &appCtx);
  toplevel.setListener(*Context, topLevelListener, &appCtx);
  _ = try wl_display.roundtrip();

  print("Running main loop\n", .{});
  while (appCtx.running) {
    print("Main loop iteraton\n", .{});
    _ = try wl_display.dispatch();
  }

  print("Exiting\n", .{});
}
