#!/bin/sh
set -eu

runtime_dir="${SANDBOX_RUNTIME_DIR:-/run/sandbox}"

case "${PAM_TYPE:-}" in
  open_session)
    mkdir "$runtime_dir/session-lock" 2>/dev/null || exit 1
    touch "$runtime_dir/session-active"
    rm -f "$runtime_dir/ready"
    ;;
  close_session)
    ;;
  *)
    exit 1
    ;;
esac
