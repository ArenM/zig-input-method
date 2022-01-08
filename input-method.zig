const std = @import("std");
const os = std.os;
const print = std.debug.print;
const min = std.math.min;

const wayland = @import("wayland");
const wl = wayland.client.wl;
// const xdg = wayland.client.xdg;
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
        const word = currentWord(ctx.text, ctx.cursor);
        print("Current word: {s}\n", .{word});
        // _ = word;
      }

      // GTK doesn't send the correct data, so prod it a bit
      ctx.inputMethod.commitString("");
      ctx.inputMethod.commit(ctx.serial);
    },
    .content_type => {}, // hint: the type in the field
  }
}

pub fn main() anyerror!void {
  print("Starting\n", .{});

  const wl_display = try wl.Display.connect(null);
  defer wl_display.disconnect();
  const registry = try wl_display.getRegistry();
  print("Connected\n", .{});

  var wl_globals = WlGlobals {
    .seat        = null,
    .inputMethodManager  = null,
  };

  registry.setListener(*WlGlobals, registryListner, &wl_globals);
  _ = try wl_display.roundtrip();

  const seat        = wl_globals.seat orelse return error.NoTextInput;
  const inputMethodManager   = wl_globals.inputMethodManager orelse return error.NoTextInput;

  print("Setting up text input handling\n", .{});
  var inputState = InputState {
    .text = undefined,
    .text_buf = undefined,
    .inputMethod = try inputMethodManager.getInputMethod(seat),
    .serial = 0,
    .cursor = 0,
  };

  inputState.inputMethod.setListener(*InputState, inputListener, &inputState);

  print("Running main loop\n", .{});
  while (true) {
    _ = try wl_display.dispatch();
  }

  print("Exiting\n", .{});
}
