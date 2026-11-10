#!/bin/sh
set -eu
cd "$(dirname "$0")"

# Build if the binary is missing.
[ -x ./tty_overlay_native ] || make

pkill -f '[t]ty_overlay_native .*--tty ' >/dev/null 2>&1 || true

TTY_NAME="$(ps -o tty= -p $$ | tr -d ' ')"
if [ -z "$TTY_NAME" ] || [ "$TTY_NAME" = "??" ]; then
  TTY_NAME="$(tty 2>/dev/null || true)"
fi
case "$TTY_NAME" in
  /dev/*) TTY_PATH="$TTY_NAME" ;;
  *) TTY_PATH="/dev/$TTY_NAME" ;;
esac

./tty_overlay_native --mode tty --tty "$TTY_PATH" &
echo "overlay running (pid=$!) targeting $TTY_PATH"
