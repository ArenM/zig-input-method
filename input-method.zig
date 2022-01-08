const std = @import("std");
const os = std.os;
const print = std.debug.print;
const min = std.math.min;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwp = wayland.client.zwp;

//
// Data Types
//

const WlGlobals = struct {
  seat: ?*wl.Seat,
  inputMethodManager: ?*zwp.InputMethodManagerV2,
};

const InputState = struct {
  inputMethod: *zwp.InputMethodV2,
  serial: u32,
  cursor: u32,
  predictorFile: std.fs.File,
  text_buf: [4000]u8,
  text: []u8,
};

const Pending = struct {
  text_buf: [4000]u8,
  text: []u8,
  cursor: u32,
  cause: ?zwp.TextInputV3.ChangeCause,

  fn reset(self: *Pending) void {
    self.cause = null;
    self.cursor = 0;
  }

  fn clear(self: *Pending) void {
    self.reset();
    std.mem.set(u8, &self.text_buf, 0);
    self.text = self.text_buf[0..0];
  }
};

const ReadCtx = struct {
  buf: [512]u8,
  head: usize,
  fd: i32,
};

const err_mask = os.POLL.ERR | os.POLL.NVAL | os.POLL.HUP;

var pending = Pending {
  .text_buf = undefined,
  .text = undefined,
  .cause = null,
  .cursor = 0,
};

//
// Helper Functions
//

// TODO: test this, the tests are alredy written
// try std.testing.expect(std.mem.eql(u8, try currentWord("", 0), ""));
// try std.testing.expect(std.mem.eql(u8, try currentWord("a", 1), "a"));
// try std.testing.expect(std.mem.eql(u8, try currentWord("a b", 3), "b"));
// try std.testing.expect(std.mem.eql(u8, try currentWord("a b c", 3), "b"));
// try std.testing.expect(std.mem.eql(u8, try currentWord("a b c", 5), "c"));
fn currentWord(text: []const u8, cursor: usize) ![]const u8 {
  // The cursor must not be beyond the end of the buffer
  if (cursor > text.len) return error.CursorOverflow;

  var start = cursor;
  var end = cursor;

  // Go backword to the beginning of the word
  // The cursor is placed at the end of each char, so we subtract one from it
  // Also we don't need to check the first char, because we can't advance after it
  // TODO: does this work with emoji
  while (start > 0) {
    if (text[start - 1] == ' ') break;
    start -= 1;
  }

  // Go forward to the end of the word
  while (end < text.len and text[end] != ' ') {
    end += 1;
  }

  return text[start..end];
}

fn predictedLine(line: []const u8) void {
  print("Completed word to: {s}\n", .{line});
}

// Call a function for each line read from a file descriptor
fn processRead(ctx: *ReadCtx) !void {
  // Calculate the availabe space we can read into
  // TODO: consider dropping data instead
  // print("Handling read\n", .{});
  if (ctx.head >= ctx.buf.len) return error.BufOverflow;

  // Read data into the buffer
  const read = try os.read(ctx.fd, ctx.buf[ctx.head..]);
  ctx.head += read;

  // Handle each line
  while (std.mem.indexOf(u8, ctx.buf[0..ctx.head], "\n")) |line_end| {
    predictedLine(ctx.buf[0..line_end]);
    ctx.head -= line_end + 1; // include the newline
    std.mem.copy(u8, &ctx.buf, ctx.buf[line_end + 1..]);
  }

  // Break when we reach EOF
  if (read == 0) return error.EOF;

}

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
      if (std.cstr.cmp(g.interface, wl.Seat.getInterface().name) == 0) {
        print("Got Seat\n", .{});
        ctx.seat = registry.bind(g.name, wl.Seat, 7) catch return;
      } else if (std.cstr.cmp(g.interface, zwp.InputMethodManagerV2.getInterface().name) == 0) {
        print("Got inputMethodManager\n", .{});
        ctx.inputMethodManager = registry.bind(g.name, zwp.InputMethodManagerV2, 1) catch return;
      }
    },
    .global_remove => |_| {print("Global remove event\n", .{});},
  }
}

fn inputListener(_: *zwp.InputMethodV2,
                 event: zwp.InputMethodV2.Event,
                 ctx: *InputState) void {
  switch (event) {
    .activate => {
      pending.clear();

      // a window is going to send us events
      // we don't need to simulate a text input
    },
    .deactivate => {
      pending.clear();

      // There is no text input sending events,
      // switch back to emulating one, or pass characters straight through
    },
    .surrounding_text => |surround| {
      const len = min(std.mem.len(surround.text), 4000);
      std.mem.copy(u8, &pending.text_buf, surround.text[0..min(len, 4000)]);
      pending.text = pending.text_buf[0..len];
      pending.cursor = surround.cursor;
    },
    .text_change_cause => |cause| { // The text was changed externally?
      pending.cause = cause.cause;
      // switch (cause.cause) {
      //   .input_method => {},
      //   .other => {},
      //   _ => {},
      // }
    },
    .unavailable => {
      // We can't use the input method anymore,
      // We should destroy the input_method, and either exit or retry
      // Something else, has likely claimed the input method,
      // or we never got it

      // TODO: clear pending
    },
    .done => {
      // apply changes
      const changed = !std.mem.eql(u8, ctx.text, pending.text);

      ctx.serial += 1;
      std.mem.copy(u8, &ctx.text_buf, &pending.text_buf);
      ctx.text = pending.text;
      ctx.cursor = pending.cursor;

      print("text: {s}\n", .{pending.text});


      // if new text is different, restart the word search
      // if (std.cstr.cmp(&ctx.text[0..], &pending.text[0..]) != 0) {
      if (changed) {
        print("Text changed\n", .{});
        const word = currentWord(ctx.text, ctx.cursor) catch return;
        ctx.predictorFile.writeAll(word) catch return;
        ctx.predictorFile.writeAll("\n") catch return;
        print("Current word: {s}\n", .{word});
      }

      // GTK doesn't send the correct data, so prod it a bit
      ctx.inputMethod.commitString("");
      ctx.inputMethod.commit(ctx.serial);
    },
    .content_type => {}, // hint: the type in the field
  }
}

pub fn main() anyerror!void {
  // Initiallize wayland connection
  const wl_display = try wl.Display.connect(null);
  defer wl_display.disconnect();
  const registry = try wl_display.getRegistry();

  // Get the wayland globals that we need
  var wl_globals = WlGlobals {
    .seat        = null,
    .inputMethodManager  = null,
  };

  registry.setListener(*WlGlobals, registryListner, &wl_globals);
  _ = try wl_display.roundtrip();

  const seat        = wl_globals.seat orelse return error.NoTextInput;
  const inputMethodManager   = wl_globals.inputMethodManager orelse return error.NoTextInput;

  // Spawn the predictor
  var buffer: [512]u8 = undefined;
  const allocator = std.heap.FixedBufferAllocator.init(&buffer).allocator();

  const predictor = try std.ChildProcess.init(&.{"./complete-word.sh"}, allocator);
  defer predictor.deinit();

  predictor.stdin_behavior = .Pipe;
  predictor.stdout_behavior = .Pipe;
  try predictor.spawn();

  var readCtx = ReadCtx {
    .buf = undefined,
    .head = 0,
    .fd = predictor.stdout.?.handle,
  };

  // Configure the input-method interface
  var inputState = InputState {
    .text = undefined,
    .text_buf = undefined,
    .inputMethod = try inputMethodManager.getInputMethod(seat),
    .serial = 0,
    .cursor = 0,
    .predictorFile = predictor.stdin.?,
  };

  inputState.inputMethod.setListener(*InputState, inputListener, &inputState);
  _ = try wl_display.flush();

  // Create the main loop
  const ev: i32 = wl_display.getFd();
  var fds = [_]os.pollfd{
    .{ .fd = ev, .events = os.POLL.IN, .revents = undefined },
    .{ .fd = predictor.stdout.?.handle, .events = os.POLL.IN, .revents = undefined },
  };

  // poll for output
  //
  // From the wayland book (with extra formatting):
  // You can build your own event loop in any manner you please,
  // and obtain the Wayland display's file descriptor with wl_display_get_fd.
  //  - Upon POLLIN events, call wl_display_dispatch to process incoming events.
  //  - To flush outgoing requests, call wl_display_flush.
  while (true) {
    const events = try os.poll(&fds, std.math.maxInt(i32));
    if (events == 0) continue;

    // Handle wayland events
    if (fds[0].revents & os.POLL.IN != 0) _ = try wl_display.dispatch();

    // Handle completed words
    if (fds[1].revents & os.POLL.IN != 0) _ = try processRead(&readCtx);

    // Always flush the wayland display, in case something else talked to it
    _ = try wl_display.flush();

    // Break if there was a poll error
    if (fds[0].revents & err_mask != 0
        or fds[1].revents & err_mask != 0) break;
  }

  print("Exiting\n", .{});
}
