#! /bin/bash

# NOTE: The shebang is set to bash becaues this requires string indexing

cd "$(dirname "$0")"

# Cleanup
finish() {
  trap - TERM INT EXIT
  pkill -P $$
}

trap 'finish' TERM INT EXIT

# Create fifo file to talk to the input-method
TMP=$(mktemp -d)
for fd in $(seq 3 5); do
  mkfifo "$TMP/$fd"
  eval "exec $fd<> '$TMP/$fd'"
done

# Since we have file descriptors, we don't need the files anymore
rm -r "$TMP"

# Process the key events before sending them to the input-method
# Reading from fd 0 is required so we can put this in the background

# Process lines from stdin
while read -r line; do
  if [ "${#line}" -eq 1 ]; then
    echo "key: $line"
    echo ".i" >&4
    printf "t%s\n" "$line" >&3
  else
    echo "swipe: $line"
    echo ".s" >&4
    echo "$line" >&5
  fi
done <&0 &

# Send updates to the input method
../zig-out/bin/input-method <&3 | stdbuf -o0 sed 's/^/i/' >&4 &

# Run swipeguess
../swipeguess /usr/share/dict/usa 20 <&5 | stdbuf -o0 sed 's/^/s/' >&4 &

complete_swipe() {
  echo "Completing swipe" >&2

  [ -z "$1" ] && return
  printf '\033clear\n'
  echo "$1" | stdbuf -o0 sed 's/\t/\n/g'
}

complete_word() {
  echo "Completing word" >&2

  printf '\033clear\n'
  [ -z "$1" ] && return
  grep "^$1" /usr/share/dict/usa | head -n 30
}

# Handle output from the input method
source="i";
while read -r line; do
  case "$line" in
    "."*) source="${line:1:2}" ;;
    "i"*)if [ "$source" == "i" ]; then complete_word "${line:1}"; fi ;;
    "s"*) if [ "$source" == "s" ]; then complete_swipe "${line:1}"; fi ;;
  esac
done <&4 | ../zig-out/bin/selector 2>/dev/null | stdbuf -o0 sed 's/^/w/' >&3 &

wait
