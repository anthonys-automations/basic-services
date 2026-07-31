#!/bin/sh
set -eu

runtime_dir="${SANDBOX_RUNTIME_DIR:-/run/sandbox}"
[ -f "$runtime_dir/ready" ] && [ ! -e "$runtime_dir/session-active" ]
