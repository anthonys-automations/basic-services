#!/bin/sh
set -eu

runtime_dir="${SANDBOX_RUNTIME_DIR:-/run/sandbox}"

# The supervisor tracks the established client after claim; its listener is gone by design.
[ -e "$runtime_dir/session-active" ] && exit 0

mode=$(cat "$runtime_dir/mode")
case "$mode" in
  ssh)
    pid_file="$runtime_dir/sshd.pid"
    ;;
  xrdp)
    for name in xrdp sesman; do
      pid_file="$runtime_dir/$name.pid"
      [ -s "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null || exit 1
    done
    exit 0
    ;;
  *)
    exit 1
    ;;
esac

[ -s "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null
