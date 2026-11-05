#!/bin/sh
set -eu

# sshd is the only listener and stays up for the whole container life, so its
# process is both the liveness and the readiness signal.
pid_file=/run/devbox/sshd.pid
[ -s "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null
