#!/bin/sh
set -eu

runtime_dir=/run/sandbox
sessions_dir="$runtime_dir/sessions"

# PAM runs this as a child of the sshd or xrdp-sesman process that owns the session,
# so PPID names a marker the entrypoint can also verify by process liveness.
case "${PAM_TYPE:-}" in
  open_session)
    mkdir -p "$sessions_dir"
    touch "$sessions_dir/$PPID"
    # First session takes the container out of the load balancer.
    rm -f "$runtime_dir/ready"
    ;;
  close_session)
    rm -f "$sessions_dir/$PPID"
    ;;
esac

exit 0
