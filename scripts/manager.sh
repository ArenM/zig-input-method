#! /bin/bash

# Cleanup
finish() {
  trap - TERM INT EXIT
  pkill -P $$
}

trap 'finish' TERM INT EXIT

# Create fifo file to talk to the input-method
TMP=$(mktemp -d)
mkfifo "$TMP/3"
exec 3<> "$TMP/3"
mkfifo "$TMP/4"
exec 4<> "$TMP/4"

# Since we have file descriptors, we don't need the files anymore
rm "$TMP/4"
rm "$TMP/3"

# Process the key events before sending them to the input-method
# Reading from fd 0 is required so we can put this in the background
# TODO: how does swipeguess fit here?
# swipeguess needs to:
#  - send the first char
#  - send it's words to the selector
stdbuf -o0 sed \
  -e 's/ /\nt /g' \
  -e 's/^/t /' \
  <&0 >&3 &
  # -e 's/^$/\n/g' \ # Empty lines are a return char

./input-method.sh <&3 >&4 &

while read -r line; do
  printf '\033clear\n'
  [ "$line" = "" ] && continue
  # grep "^$line" /usr/share/dict/usa | head -n 30
  grep "^$line" ../wordsSorted.txt | head -n 30
done <&4 | ../zig-out/bin/selector 2>/dev/null | stdbuf -o0 sed 's/^/s /' >&3 &

wait
