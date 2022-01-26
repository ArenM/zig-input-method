#! /bin/sh

# This is a reference implemation for a prediction source, it's not intended to
# produce good results, just enough for an example

while read -r line; do
  printf '\033clear\n'
  [ "$line" = "" ] && continue
  grep -i "^$line" /usr/share/dict/usa | head -n 30
  # grep "^$line" /usr/share/dict/usa | head -n 7 | dmenu
  # printf "\n"
done | ./zig-out/bin/selector
