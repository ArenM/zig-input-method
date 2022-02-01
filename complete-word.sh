#! /bin/sh

# This is a reference implemation for a prediction source, it's not intended to
# produce good results, just enough for an example

trap 'pkill -P $$' TERM INT EXIT

# Create fifo file to talk to the input-method
TMP=$(mktemp -d)
mkfifo "$TMP/3"
exec 3<> "$TMP/3"
rm -r "$TMP" # we have a file descriptor, we don't need the files

while read -r line; do
  printf '\033clear\n'
  [ "$line" = "" ] && continue
  grep -i "^$line" /usr/share/dict/usa | head -n 30
done <&3 | ./zig-out/bin/selector | ./zig-out/bin/input-method >&3 &

wait
