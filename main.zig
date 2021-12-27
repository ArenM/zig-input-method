const std = @import("std");
const os = std.os;
const print = std.debug.print;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;

const WlGlobals = struct {
  compositor: ?*wl.Compositor,
  shm: ?*wl.Shm,
  xdg: ?*xdg.WmBase,
};

const Context = struct {
  width: usize,
  height: usize,
  shm_fd: i32,
  shm_pool: *wl.ShmPool,
  // TODO: does this need to be nulllable?
  displayBuffer: DisplayBuffer,
  running: bool,
  configured: bool,
  surface: *wl.Surface,
  toplevel: *const xdg.Toplevel,
};

const DisplayBuffer = struct {
  width: usize,
  height: usize,
  stride: usize,
  data: []align(4096) u8,
  buffer: *wl.Buffer,
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
  // print("top level event: {}\n", .{event});
  switch (event) {
    .close => ctx.running = false,
    .configure => |config| { // resize event
      print("resize from {}\n", .{ctx.height});
      // replace zero size with defaults
      if (config.height > 0) ctx.height = @intCast(usize, config.height);
      if (config.height > 0) ctx.width = @intCast(usize, config.width);
      render(ctx);
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
fn bufListener(buf: *wl.Buffer, event: wl.Buffer.Event, _: *DisplayBuffer) void {
  _ = buf;
  switch (event) {
    .release => |_| {
      print("Buffer released\n", .{});
      // buf.destroy();
    }
  }
}

// Draw a test grid to the provided buffer
fn drawGrid(buf: *DisplayBuffer) void {
  const size = @minimum(buf.width, buf.height) / 10;

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

// Render a frame, includes (re)allocating buffers
fn render(ctx: *Context) void {
  if (!ctx.configured) return;

  // TODO: when we commit the buffer, we transfer ownership to the compositor
  var buffer = &ctx.displayBuffer;

  if (ctx.width == 0) ctx.width = 125; 
  if (ctx.height == 0) ctx.height = 125; 
  const buf_size = ctx.width * ctx.height * 4;
  if (buf_size == 0) return;

  print("width: {}, height: {}\n", .{ctx.width, ctx.height});
  if (ctx.width != buffer.width or ctx.height != buffer.height) {
    print("Buffer needs a resize\n", .{});
    // If the window needs to get bigger
    if (buffer.data.len < buf_size) {
      os.ftruncate(ctx.shm_fd, buf_size) catch return;
      os.munmap(buffer.data);
      buffer.data = os.mmap(
        null, buf_size,
        os.PROT.READ | os.PROT.WRITE,
        os.MAP.SHARED, ctx.shm_fd, 0) catch return;
      ctx.shm_pool.resize(@intCast(i32, buf_size));
    }
    buffer.width = ctx.width;
    buffer.stride = ctx.width * 4;
    buffer.height = ctx.height;
  } else {
    print("No resize needed\n", .{});
  }

  const wl_buffer = ctx.shm_pool.createBuffer(
    0, @intCast(i32, buffer.width),
    @intCast(i32, buffer.height),
    @intCast(i32, buffer.stride),
    wl.Shm.Format.argb8888) catch return;
  // wl_buffer.setListener(*DisplayBuffer, bufListener, &ctx.displayBuffer);

  drawGrid(buffer);
  // ctx.surface.attach(ctx.displayBuffer.buffer, 0, 0);
  ctx.surface.attach(wl_buffer, 0, 0);
  ctx.surface.damage(0, 0, 2^32, 2^32);
  ctx.surface.commit();
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

  // default sizes
  const width = 125;
  const height = 125;
  const stride = width * 4;
  const buf_size = stride * height;

  // variable:	lifetime:		description:
  // fd:	applicatin lifetime	backign file descriptor
  // data:	applicatin lifetime	pointer to mmaped fd
  // pool:	applicatin lifetime	backing memory
  // buffer:	a frame (reusable)	portion of pool to display
  // note: The pool may be replaced with a new one in order to shrink it
  const fd = try os.memfd_create("zig-ime", 0);
  try os.ftruncate(fd, buf_size);
  // TODO: const data = @bitCast([]u32, data);
  const data = try os.mmap(
    null, buf_size,
    os.PROT.READ | os.PROT.WRITE,
    os.MAP.SHARED, fd, 0);

  // TODO: rename
  const pool = try shm.createPool(fd , @intCast(i32, stride * height));
  defer pool.destroy();

  const buffer = try pool.createBuffer(
    0, @intCast(i32, width),
    @intCast(i32, height),
    @intCast(i32, stride),
    wl.Shm.Format.argb8888);
  defer buffer.destroy();

  var gridCtx = DisplayBuffer {
    .height = height,
    .width = width,
    .stride = stride,
    .buffer = buffer,
    .data = data,
  };


  // TODO: rename
  var appCtx = Context {
    .height = 0,
    .width = 0,
    .displayBuffer = gridCtx,
    .shm_fd = fd,
    .shm_pool = pool,
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
