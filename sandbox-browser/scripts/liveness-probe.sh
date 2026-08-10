#!/bin/sh
set -eu

runtime_dir="${SANDBOX_RUNTIME_DIR:-/run/sandbox}"

# Both listeners stay up for the whole container life, so liveness is their liveness.
for name in sshd sesman xrdp; do
  pid_file="$runtime_dir/$name.pid"
  [ -s "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null || exit 1
done
