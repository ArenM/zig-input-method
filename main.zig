const std = @import("std");
const os = std.os;
const print = std.debug.print;

const rend = @cImport({
  @cInclude("pango/pangocairo.h");
});

const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const zwlr = wayland.client.zwlr;

const default_width = 150;
const default_height = 150;
const default_stride = default_width * 4;

//
// Data Types
//
const WlGlobals = struct {
  compositor: ?*wl.Compositor,
  shm: ?*wl.Shm,
  xdg: ?*xdg.WmBase,
  layerShell: ?*zwlr.LayerShellV1,
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

//
// Wayland Functions
//

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
      } else if (std.cstr.cmp(g.interface, zwlr.LayerShellV1.getInterface().name) == 0) {
        print("Got LayerShell\n", .{});
        ctx.layerShell = registry.bind(g.name, zwlr.LayerShellV1, 3) catch return;
      } else if (std.cstr.cmp(g.interface, xdg.WmBase.getInterface().name) == 0) {
        print("Got XdgWmBase\n", .{});
        ctx.xdg = registry.bind(g.name, xdg.WmBase, 1) catch return;
      }
    },
    .global_remove => |_| {print("Global remove event\n", .{});},
  }
}

// Ack configure events
fn wlrSurfaceListener(surface: *zwlr.LayerSurfaceV1,
                      event: zwlr.LayerSurfaceV1.Event,
                      ctx: *Context) void {
  print("wlrSurfaceListener: {}\n", .{event});
  switch (event) {
    .configure => |conf| {
      surface.ackConfigure(conf.serial);
      ctx.configured = true;
      ctx.width = @intCast(usize, conf.width);
      ctx.height = @intCast(usize, conf.height);
      render(ctx);

    },
    .closed => {},
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

//
// Rendering
//

// Draw somethign with pango
fn draw(buf: *DisplayBuffer) void {
  const surface = rend.cairo_image_surface_create_for_data(
      @ptrCast([*c]u8, buf.data[0..]),
      rend.CAIRO_FORMAT_ARGB32,
      @intCast(c_int, buf.width),
      @intCast(c_int, buf.height),
      @intCast(c_int, buf.width * 4));

  const cr = rend.cairo_create(surface);
  defer rend.cairo_destroy(cr);
  rend.cairo_scale(cr, 0.1, 0.1);

  // Draw the background
  rend.cairo_set_source_rgb(cr, 0, 1, 0);
  rend.cairo_paint(cr);

  // Prepare text drawing surface
  const layout = rend.pango_cairo_create_layout(cr);
  defer rend.g_object_unref(layout);

  // TODO: make this configurable, it works for a poc like this
  const desc = rend.pango_font_description_from_string("Sans");
  rend.pango_font_description_set_absolute_size(desc,
      24 * 96 * @intToFloat(f64, rend.PANGO_SCALE) / (72.0 * 0.1));
  rend.pango_layout_set_font_description(layout, desc);
  rend.pango_font_description_free(desc);


  // Draw test
  const text = "Some Text";
  rend.cairo_set_source_rgb(cr, 0, 0, 0);
  rend.pango_layout_set_text(layout, text, text.len);
  rend.pango_cairo_show_layout(cr, layout);
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
  buffer.busy = true;

  draw(buffer);

  ctx.surface.attach(buffer.wl_buffer, 0, 0);
  ctx.surface.damage(0, 0, 2^32, 2^32);
  ctx.surface.commit();
}

fn makeEmptyBuf(shm: *wl.Shm) !DisplayBuffer {
  const buf_size = default_stride * default_height;
  const fd = try os.memfd_create("wayland-backing", 0);

  try os.ftruncate(fd, buf_size);
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
    .layerShell = null,
  };

  registry.setListener(*WlGlobals, registryListner, &wl_globals);
  _ = try wl_display.roundtrip();

  const compositor  = wl_globals.compositor orelse return error.NoWlCompositor;
  const shm         = wl_globals.shm orelse return error.NoWlShm;
  const xdgWmBase = wl_globals.xdg orelse return error.NoXdgBase;
  const layerShell  = wl_globals.layerShell orelse return error.NoLayerShell;

  const surface = try compositor.createSurface();
  defer surface.destroy();

  // todo: we may want to find the correct output ourselves
  const wlrSurface = try layerShell.getLayerSurface(surface, null, zwlr.LayerShellV1.Layer.top, "");

  var appCtx = Context {
    .height = 0,
    .width = 0,
    .buffers = .{try makeEmptyBuf(shm), try makeEmptyBuf(shm)},
    .shm = shm,
    .surface = surface,
    .configured = false,
    .running = true,
  };

  xdgWmBase.setListener(*Context, baseListener, &appCtx);
  wlrSurface.setListener(*Context, wlrSurfaceListener, &appCtx);
  wlrSurface.setAnchor(.{.bottom = true, .left = true, .right = true});
  wlrSurface.setSize(0, 40);
  // TODO: can we control the order of this with the keybaord
  wlrSurface.setExclusiveZone(40);

  surface.commit();
  _ = try wl_display.roundtrip();

  print("Running main loop\n", .{});
  while (appCtx.running) {
    print("Main loop iteraton\n", .{});
    _ = try wl_display.dispatch();
  }

  print("Exiting\n", .{});
}
