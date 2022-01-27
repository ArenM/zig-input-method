const std = @import("std");
const zig_version = @import("builtin").zig_version;
const os = std.os;
const print = std.debug.print;

const rend = @cImport({
  @cInclude("pango/pangocairo.h");
});

const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const zwlr = wayland.client.zwlr;

const default_width = 180;
const default_height = 40;
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
  wlrSurface: *zwlr.LayerSurfaceV1,
  wordState: WordState,
  buffers: [2]DisplayBuffer,

  fn requestFrame(self: *Context) !void {
    var cb = try self.surface.frame();
    cb.setListener(*Context, frameListener, self);
    self.surface.commit();
  }
};

const DisplayBuffer = struct {
  busy: bool = false,
  shm_fd: i32,
  width: usize = default_width,
  height: usize = default_height,
  shm_pool: *wl.ShmPool,
  wl_buffer: *wl.Buffer,
  surface: *rend._cairo_surface,
  cairo: *rend._cairo,
  data: []align(4096) u8,
};

const ReadCtx = struct {
  buf: [512]u8,
  fd: i32,
  head: usize = 0,
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

        // print the word to stdout
        const out = std.io.getStdOut();
        out.writer()
          .print("{s}\n", .{ctx.wordState.wordAtPos(ctx.pointerX)})
          catch return;
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

fn frameListener(cb: *wl.Callback,
                 _: wl.Callback.Event,
                 ctx: *Context) void {
  print("Got frame callback\n", .{});
  cb.destroy();
  render(ctx);
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
  alloc: Self.AllocType,

  const AllocType = if (zig_version.major == 0 and zig_version.minor <= 8)
    *std.mem.Allocator
  else
    std.mem.Allocator;

  const ActiveWord = struct {
    word: []u8,
    index: isize,
  };

  const Queue_T = std.TailQueue([]u8);
  const QueueNode = Queue_T.Node;

  fn init(alloc: Self.AllocType) WordState {
    // TODO: it may be more efficient to use an arena allocator
    // var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    // var alloc = arena.allocator();

    return WordState { .alloc = alloc };
  }

  /// Queue a word to be added
  fn addWord(self: *Self, word: []const u8) !void {
    // Don't include empty lines
    if (word.len == 0) return;

    // lines prefixed with the escape character are treated as commmands
    if (word[0] == 0x1B) {
      if (std.mem.eql(u8, word[1..], "clear")) self.clear();
      return;
    }

    var owned_word: []u8 = try self.alloc.dupe(u8, word);
    const node = try self.alloc.create(Self.QueueNode);

    node.data = owned_word;
    self.newWords.append(node);
  }

  fn wordAtPos(self: *Self, pos: isize) ?[]u8 {
    var i: usize = 0;
    for (self.words.items(.index)) |index| {
      if (index > pos) return self.words.get(i).word;
      i += 1;
    }

    return null;
  }

  fn drawWord(word: []const u8, offset: isize, layout: *rend.PangoLayout, ctx: *RenderCtx) isize {
      // Prepare text
      rend.pango_layout_set_text(layout, @ptrCast([*c]const u8, word),
          @intCast(c_int, word.len));

      // Get text size
      var width: c_int = undefined;
      rend.pango_layout_get_pixel_size(layout, @ptrCast([*c]c_int, &width), null);

      // Draw border
      rend.cairo_set_source_rgb(ctx.cairo, 0.5, 0, 0.5);
      rend.cairo_rectangle(ctx.cairo, @intToFloat(f64, width + offset) + 4, 0, 3, 40);
      rend.cairo_fill(ctx.cairo);

      // Draw text
      rend.cairo_move_to(ctx.cairo, @intToFloat(f64, offset), 0);
      rend.cairo_set_source_rgb(ctx.cairo, 0, 0, 0);
      rend.pango_cairo_show_layout(ctx.cairo, layout);

      return width;
  }

  /// Move words from the queue and render
  // - iterate over all items in the queue
  // - render them
  // - move them to the current words list
  fn draw(self: *Self, ctx: *RenderCtx) !void {
    var offset: isize = 0;
    const layout = try ctx.pangoLayout();

    for (self.words.items(.word)) |word| {
      if (offset >= ctx.buf.width) break;
      offset = offset + drawWord(word[0..], offset, layout, ctx) + 20;
      rend.cairo_set_source_rgb(ctx.cairo, 0, 0, 0);
    }

    while (self.newWords.popFirst()) |node| {
      offset += drawWord(node.data, offset, layout, ctx) + 20;
      try self.words.append(self.alloc, .{.word=node.data, .index=offset});
      self.alloc.destroy(node);
      if (offset >= ctx.buf.width) break;
    }
  }

  // Would it make more sense to just throw the entire WordState struct away?
  // - remove all items from the queue
  // - remove all currently displayed words
  // - fill the display with the background color
  fn clear(self: *Self) void {
    // Free words
    for (self.words.items(.word)) |word| {
      self.alloc.free(word);
    }

    // Free queue nodes
    while (self.newWords.pop()) |node| {
      self.alloc.free(node.data);
      self.alloc.destroy(node);
    }

    // Free words list
    self.words.deinit(self.alloc);

    self.newWords = .{};
    self.words = .{};
  }
};

// Call a function for each line read from a file descriptor
fn processRead(ctx: *ReadCtx, appCtx: *Context) !void {
  // Calculate the availabe space we can read into
  // TODO: consider dropping data instead
  if (ctx.head >= ctx.buf.len) return error.BufOverflow;

  // Read data into the buffer
  const read = try os.read(ctx.fd, ctx.buf[ctx.head..]);
  ctx.head += read;

  // Handle each line
  while (std.mem.indexOf(u8, ctx.buf[0..ctx.head], "\n")) |line_end| {
    try appCtx.wordState.addWord(ctx.buf[0..line_end]);
    try appCtx.requestFrame();
    ctx.head -= line_end + 1; // include the newline
    std.mem.copy(u8, &ctx.buf, ctx.buf[line_end + 1..]);
  }

  // Break when we reach EOF
  if (read == 0) return error.EOF;
}

//
// Rendering
//

// How this works:
// - Search for a buffer that isn't in use
// - Resize it if necessary
//
// variable:	lifetime:		description:
// fd:		applicatin lifetime	backign file descriptor
// data:	many frames		pointer to mmaped fd
// pool:	many frames		backing memory
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
      if (zig_version.major == 0 and zig_version.minor <= 8)
          buffer.data = try os.mmap(
            null, buf_size,
            std.c.PROT_READ | std.c.PROT_WRITE,
            std.c.MAP_SHARED, buffer.shm_fd, 0)
      else
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

    // TODO: extract this to a helper function
    rend.cairo_destroy(buffer.cairo);
    rend.cairo_surface_destroy(buffer.surface);
    const ptr = @ptrCast([*c]u8, buffer.data);
    const format = if (zig_version.major == 0 and zig_version.minor <= 8)
      @intToEnum(rend.enum__cairo_format, rend.CAIRO_FORMAT_ARGB32)
    else
      rend.CAIRO_FORMAT_ARGB32;
    const surface = rend.cairo_image_surface_create_for_data(
        ptr, format,
        @intCast(c_int, width),
        @intCast(c_int, height),
        @intCast(c_int, stride))
        orelse return error.CairoSurfaceError;

    const cairo = rend.cairo_create(surface) orelse return error.CairoCreateFailed;
    rend.cairo_scale(cairo, 1, 1);

    // TODO: can we control the order of this with the keybaord
    // TODO: this isn't called if we happen to set the defaults correctly
    ctx.wlrSurface.setExclusiveZone(@intCast(i32, height));
  }

  return buffer;
}

const RenderCtx = struct {
  const Self = @This();

  surface: *rend._cairo_surface,
  cairo: *rend._cairo,
  buf: *DisplayBuffer,
  layout: ?*rend.PangoLayout = null,

  fn init(buf: *DisplayBuffer) !Self {
    const surface = buf.surface;
    const cairo: *rend._cairo = buf.cairo;

    return Self {
      .surface = surface,
      .cairo = cairo,
      .buf = buf,
    };
  }

  /// Return the current pango layout, or create one if it's not available
  fn pangoLayout(self: *Self) !*rend.PangoLayout {
    if (self.layout) |layout| {
      return layout;
    }

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
    if (self.layout) |layout| rend.g_object_unref(layout);
  }
};

// Render a frame, includes (re)allocating buffers
fn render(ctx: *Context) void {
  print("Rendering\n", .{});
  if (!ctx.configured) return;

  var buffer = getBuffer(ctx) catch return;
  buffer.busy = true;

  var renderCtx = RenderCtx.init(buffer) catch return;
  defer renderCtx.deinit();
  renderCtx.drawBackground();
  ctx.wordState.draw(&renderCtx) catch return;

  // The bitwise not of 0 is the largest possible number for a uint
  // TODO: there should be an easier way to do this
  const max = @intCast(i32, ~@as(u31, 0));
  ctx.surface.attach(buffer.wl_buffer, 0, 0);
  ctx.surface.damage(0, 0, max, max);
  ctx.surface.commit();
  print("Done Rendering\n", .{});
}

fn makeEmptyBuf(shm: *wl.Shm) !DisplayBuffer {
  const buf_size = default_stride * default_height;
  const fd = try os.memfd_create("wayland-backing", 0);

  try os.ftruncate(fd, buf_size);
  const data = if (zig_version.major == 0 and zig_version.minor <= 8)
      try os.mmap(
        null, buf_size,
        std.c.PROT_READ | std.c.PROT_WRITE,
        std.c.MAP_SHARED, fd, 0)
  else
      try os.mmap(
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

  const ptr = @ptrCast([*c]u8, data);
  const format = if (zig_version.major == 0 and zig_version.minor <= 8)
    @intToEnum(rend.enum__cairo_format, rend.CAIRO_FORMAT_ARGB32)
  else
    rend.CAIRO_FORMAT_ARGB32;
  const surface = rend.cairo_image_surface_create_for_data(
      ptr, format,
      @intCast(c_int, default_width),
      @intCast(c_int, default_height),
      @intCast(c_int, default_stride))
      orelse return error.CairoSurfaceError;

  const cairo = rend.cairo_create(surface) orelse return error.CairoCreateFailed;
  rend.cairo_scale(cairo, 1, 1);

  var buffer = DisplayBuffer {
    .shm_fd = fd,
    .shm_pool = pool,
    .wl_buffer = wl_buffer,
    .data = data,
    .surface = surface,
    .cairo = cairo,
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

  var alloc: std.heap.GeneralPurposeAllocator(.{}) = .{};
  var appCtx = Context {
    .shm = shm,
    .surface = surface,
    .buffers = .{try makeEmptyBuf(shm), try makeEmptyBuf(shm)},
    .wordState = if (zig_version.major == 0 and zig_version.minor <= 8)
      WordState.init(&alloc.allocator)
    else
      WordState.init(alloc.allocator()),
    .wlrSurface = try layerShell.getLayerSurface(surface, null,
        zwlr.LayerShellV1.Layer.top, ""),
  };

  xdgWmBase.setListener(*Context, baseListener, &appCtx);
  seat.setListener(*Context, seatListener, &appCtx);

  // TODO: we may want to find the correct output ourselves
  appCtx.wlrSurface.setListener(*Context, wlrSurfaceListener, &appCtx);
  appCtx.wlrSurface.setAnchor(.{.bottom = true, .left = true, .right = true});
  appCtx.wlrSurface.setSize(0, default_height);
  surface.commit();
  // _ = try wl_display.roundtrip();

  print("Running main loop\n", .{});

  const POLLIN = if (zig_version.major == 0 and zig_version.minor <= 8)
    std.c.POLLIN
  else
    os.POLL.IN;

  const errMask = if (zig_version.major == 0 and zig_version.minor <= 8)
    std.c.POLLERR | std.c.POLLIN | std.c.POLLHUP
  else 
    os.POLL.ERR | os.POLL.NVAL | os.POLL.HUP;

  const wayland_fd = wl_display.getFd();
  var fds = [_]os.pollfd {
    .{ .fd = wayland_fd, .events = POLLIN, .revents = undefined },
    .{ .fd = std.os.STDIN_FILENO, .events = POLLIN, .revents = undefined },
  };
  var readCtx: ReadCtx = .{
    .buf = undefined,
    .fd = std.os.STDIN_FILENO,
  };

  while (appCtx.running) {
    // Always flush the wayland display, in case something else talked to it
    _ = try wl_display.flush();

    const events = try os.poll(&fds, std.math.maxInt(i32));
    if (events == 0) continue;

    // Handle wayland events
    if (fds[0].revents & POLLIN != 0) _ = try wl_display.dispatch();

    // Handle completed words
    if (fds[1].revents & POLLIN != 0) _ = try processRead(&readCtx, &appCtx);

    // Break if there was a poll error
    if (fds[0].revents & errMask != 0
        or fds[1].revents & errMask != 0) {
      print("Poll Error\n", .{});
      break;
    }
  }

  print("Exiting\n", .{});
}
