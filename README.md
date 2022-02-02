# Building

Depends (not yet exhaustive):
 - wayland-protocols
 - wayland-scanner
 - libwayland-client
 - pango
 - cairo
 - zig-wayland (provided as a git submodule)

Build dependencies:
 - zig 0.9 or 0.8

NOTE: to use zig 0.8 zig-wayland needs to be pinned to
38b5de89b3e3de670bb2496de56e5173d626fad5

```
git submodule update --init
zig build
```

# Usage

The entire system can be run with the following. This supports both swipe-typing
and prediction based on the current word.

```
wvkbd-mobintl -O | ./scripts/manager.sh
```

Note that currently only applications that that support the `text_input_v3`
protocol are supported, I've been using gedit for testing. Also for this to be
fully correct wvkbd needs to be patched to *only* output typed characters to
stdout, and not attempt to send them to the compositor.


## Using the selector for just wvkbd swipe-typing

The selector program in this repository can be used as a menu for swype-typing
with wvkbd.

```sh
wvkbd-mobintl -O -L 240 |\
  swipeguess wordsSorted.txt 20 |\
  stdbuf -oL sed -e 's/^/\x1Bclear\n/g' -e 's/\t/\n/g' |\
  ./zig-out/bin/selector |\
  completelyTypeWord.sh
```

# Architecture

The basic architecture I've been designing this for involves a "manager" process
that receives events from the keybaord, predicts text, and sends that to the
input-method process.

The input-method process would then communicate text to insert to the
compositor, and provide the current word(s) to the manager. Currently the
manager and input-method elements are both in the input-method binary, I intend
to separate the manager to a shell script.

```
         input method <-> compositor
              ^
              |
              v
keyboard -> manager <--╮
              |        |--> train the predictor
              v        |
          predict -> select
```

## Input Method Binary

The input-method binary acts as a proxy between the input-method
protocol, and unix pipes. Given that it will need to support several different
protocols in wayland, I expect it should be possible to also add xorg support to
it.

In Scope:
 - provide current word
 - provide surrounding words
 - provide input field type
 - send selected text to the compositor
 - change the current word (for autocorrect)
 - send partial words, only possible sometimes
   (with input-method but not virtual-keyboard)
 - other display protocols, it already needs two for wayland
 - open the keyboard when a text input is selected

Possibly in Scope:
 - provide cursor / selection
 - intercept hardware keyboard input (hopefully not)

Out of Scope:
 - handling keyboard input differently in some cases, like for gesture typing
 - predicting words
 - correcting words
 - gui

# Contributing

If you have a patch you'd like included you can send it to
~aren/public-inbox@lists.sr.ht
