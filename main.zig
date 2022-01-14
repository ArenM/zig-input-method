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
  compositor: ?*wl.Compositor = null,
  shm: ?*wl.Shm = null,
  xdg: ?*xdg.WmBase = null,
  seat: ?*wl.Seat = null,
  layerShell: ?*zwlr.LayerShellV1 = null,
};

const Context = struct {
  running: bool = true,
  configured: bool = false,
  mouseRegistered: bool = false,
  width: usize = default_width,
  height: usize = default_height,
  pointerX: isize = 0,
  // TODO: store a globals object instead
  shm: *wl.Shm,
  surface: *wl.Surface,
  buffers: [2]DisplayBuffer,
};

const DisplayBuffer = struct {
  busy: bool = false,
  shm_fd: i32,
  width: usize = default_width,
  height: usize = default_height,
  shm_pool: *wl.ShmPool,
  wl_buffer: *wl.Buffer,
  data: []align(4096) u8,
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
      } else if (std.cstr.cmp(g.interface, wl.Seat.getInterface().name) == 0) {
        print("Got Seat\n", .{});
        ctx.seat = registry.bind(g.name, wl.Seat, 7) catch return;
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

// Let the compositor know we're not deadlocked
fn baseListener(wm: *xdg.WmBase, event: xdg.WmBase.Event, _: *Context) void {
  print("base event: {}\n", .{event});
  switch (event) {
    .ping => |ping| {
      wm.pong(ping.serial);
    }
  }
}

// Handle input events
fn pointerListener(_: *wl.Pointer, event: wl.Pointer.Event, ctx: *Context) void {
  switch (event) {
    .button => |button| {
      if (button.state == wl.Pointer.ButtonState.released) {
        print("Mosue released at: {}\n", .{ctx.pointerX});
      }
    },
    .motion => |move| { ctx.pointerX = move.surface_x.toInt(); },
    else => {},
  }
}

// Configure input events
fn seatListener(seat: *wl.Seat, event: wl.Seat.Event, ctx: *Context) void {
  print("Seat event\n", .{});
  switch (event) {
    .capabilities => |cap| {
      if (!ctx.mouseRegistered and cap.capabilities.pointer) {
        const pointer = seat.getPointer() catch return;
        pointer.setListener(*Context, pointerListener, ctx);
      }
    },
    .name => {},
  }
}

// Ack configure events
fn wlrSurfaceListener(surface: *zwlr.LayerSurfaceV1,
                      event: zwlr.LayerSurfaceV1.Event,
                      ctx: *Context) void {
  print("wlrSurfaceListener\n", .{});
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
// Word State
//

// Data layout for storing selectable words
//
// Changes queue:
//  When new words are received they should be pushed to the queue
//  then the draw operation should be run
//
// Stdin types:
//  words are seperated by some char, use IFS?
//  word sets are separated by newline
//  each time a newline is read it should run clear
//
// Currently displayed words:
//  after a word is rendered
//  it should be moved to the list of displayed words
//  along with it's maximum x value
//
// Handling click (select word)
//  iterate over the list of displayed words
//  post-increment the count, break if the items x value is greater than the clicks
//  print the match (if found)
//  run clear (if found)
const WordState = struct {
  const Self = @This();

  off: isize = 0,
  newWords: Queue_T = .{},
  words: std.MultiArrayList(ActiveWord) = .{},
  alloc: std.mem.Allocator,

  const ActiveWord = struct {
    word: []u8,
    index: isize,
  };

  const Queue_T = std.TailQueue([]u8);
  const QueueNode = Queue_T.Node;

  fn init(alloc: std.mem.Allocator) WordState {
    // TODO: it may be more efficient to use an arena allocator
    // var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    // var alloc = arena.allocator();

    return WordState { .alloc = alloc };
  }

  /// Queue a word to be added
  fn addWord(self: *Self, word: []const u8) !void {
    var owned_word: []u8 = try self.alloc.dupe(u8, word);
    // var owned_word: []u8 = try self.alloc.alloc(u8, word.len);
    // std.mem.copy(u8, owned_word, word);

    const node = try self.alloc.create(Self.QueueNode);
    node.data = owned_word;
    self.newWords.append(node);
  }

  /// Move words from the queue and render
  // - iterate over all items in the queue
  // - render them
  // - move them to the current words list
  fn draw(self: *Self, ctx: *RenderCtx) !void {
    var offset: isize = 0;

    while (self.newWords.popFirst()) |node| {
      // Prepare text drawing surface
      const layout = try ctx.pangoLayout();
      defer rend.g_object_unref(layout);

      // Prepare text
      rend.pango_layout_set_text(layout, @ptrCast([*c]const u8, node.data[0..]),
          @intCast(c_int, node.data[0..].len));

      // Get text size
      var width: c_int = undefined;
      rend.pango_layout_get_pixel_size(layout, @ptrCast([*c]c_int, &width), null);

      // Draw border
      rend.cairo_set_source_rgb(ctx.cairo, 0.5, 0, 0.5);
      rend.cairo_rectangle(ctx.cairo, @intToFloat(f64, width + offset) + 4, 0, 5, 40);
      rend.cairo_fill(ctx.cairo);

      // Draw text
      rend.cairo_move_to(ctx.cairo, @intToFloat(f64, offset), 0);
      rend.cairo_set_source_rgb(ctx.cairo, 0, 0, 0);
      rend.pango_cairo_show_layout(ctx.cairo, layout);

      // Update internal state
      offset += width + 20;
      try self.words.append(self.alloc, .{.word=node.data, .index=offset});
    }
  }

  // Would it make more sense to just throw the entire WordState struct away?
  // - remove all items from the queue
  // - remove all currently displayed words
  // - fill the display with the background color
  fn clear(self: *Self) void {
    _ = self;
    // TODO
    // self.queue = std.ArrayList.init(self.arena.allocator());
  }
};

//
// Rendering
//

const RenderCtx = struct {
  const Self = @This();

  surface: *rend._cairo_surface,
  cairo: *rend._cairo,

  fn init(buf: *DisplayBuffer) !Self {
    const surface = rend.cairo_image_surface_create_for_data(
        @ptrCast([*c]u8, buf.data[0..]),
        rend.CAIRO_FORMAT_ARGB32,
        @intCast(c_int, buf.width),
        @intCast(c_int, buf.height),
        @intCast(c_int, buf.width * 4))
        orelse return error.CairoSurfaceError;

    const cairo = rend.cairo_create(surface) orelse return error.CairoCreateFailed;
    rend.cairo_scale(cairo, 1, 1);

    return Self {
      .surface = surface,
      .cairo = cairo,
    };
  }

  /// Get a pango layout for darwing text
  fn pangoLayout(self: *Self) !*rend.PangoLayout {
    const layout = rend.pango_cairo_create_layout(self.cairo)
        orelse return error.PangoCreateFailed;

    // TODO: make this configurable, it works for a poc like this
    const desc = rend.pango_font_description_from_string("Sans");
    rend.pango_font_description_set_absolute_size(desc,
        24 * 96 * @intToFloat(f64, rend.PANGO_SCALE) / (72.0));
    rend.pango_layout_set_font_description(layout, desc);
    rend.pango_font_description_free(desc);

    return layout;
  }

  /// Draw the background
  fn drawBackground(self: *Self) void {
    rend.cairo_set_source_rgb(self.cairo, 1, 1, 1);
    rend.cairo_paint(self.cairo);
  }

  fn deinit(self: *Self) void {
    rend.cairo_destroy(self.cairo);
  }
};

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

  var renderCtx = RenderCtx.init(buffer) catch return;
  defer renderCtx.deinit();

  renderCtx.drawBackground();

  // Draw some example words
  var alloc: std.heap.GeneralPurposeAllocator(.{}) = .{};
  var ws = WordState.init(alloc.allocator());
  ws.addWord("A new word") catch return;
  ws.addWord("Another word") catch return;
  ws.draw(&renderCtx) catch return;

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
    .shm_fd = fd,
    .shm_pool = pool,
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

  var wl_globals = WlGlobals {};

  registry.setListener(*WlGlobals, registryListner, &wl_globals);
  _ = try wl_display.roundtrip();

  const compositor = wl_globals.compositor orelse return error.NoWlCompositor;
  const shm        = wl_globals.shm orelse return error.NoWlShm;
  const xdgWmBase  = wl_globals.xdg orelse return error.NoXdgBase;
  const seat       = wl_globals.seat orelse return error.NoSeat;
  const layerShell = wl_globals.layerShell orelse return error.NoLayerShell;

  const surface = try compositor.createSurface();
  defer surface.destroy();

  var appCtx = Context {
    .shm = shm,
    .surface = surface,
    .buffers = .{try makeEmptyBuf(shm), try makeEmptyBuf(shm)},
  };

  xdgWmBase.setListener(*Context, baseListener, &appCtx);
  seat.setListener(*Context, seatListener, &appCtx);

  // todo: we may want to find the correct output ourselves
  const wlrSurface = try layerShell.getLayerSurface(surface, null,
      zwlr.LayerShellV1.Layer.top, "");
  wlrSurface.setListener(*Context, wlrSurfaceListener, &appCtx);
  wlrSurface.setAnchor(.{.bottom = true, .left = true, .right = true});
  wlrSurface.setSize(0, 40);
  // TODO: can we control the order of this with the keybaord
  wlrSurface.setExclusiveZone(40);

  surface.commit();
  _ = try wl_display.roundtrip();

  print("Running main loop\n", .{});
  while (appCtx.running) {
    _ = try wl_display.dispatch();
  }

  print("Exiting\n", .{});
}
