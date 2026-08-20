#!/bin/sh
set -eu

runtime_dir=/run/sandbox

# The first session drops the ready marker; the sessions directory is the same fact,
# checked directly so a probe never advertises a container that is already taken.
[ -f "$runtime_dir/ready" ] && [ -z "$(ls -A "$runtime_dir/sessions" 2>/dev/null)" ]
