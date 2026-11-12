#!/usr/bin/env bash
set -euo pipefail

# Named in /etc/ssh/sshd_config, which this container cannot edit, so the path
# is fixed rather than configurable.
runtime_dir=/run/devbox
ssh_dir="$runtime_dir/ssh"
authorized_keys="$runtime_dir/authorized_keys"
home_dir=/home/user
mounted_keys=/etc/devbox/authorized_keys
# An operator-managed host identity, e.g. from a Kubernetes Secret. Without one,
# keys are generated once into the persistent home so the identity survives
# restarts instead of tripping every client's known_hosts check.
mounted_host_keys=/etc/devbox/host-keys
persisted_host_keys="$home_dir/.local/state/devbox/ssh-host-keys"
sshd_pid=""

cleanup() {
  if [[ -n "$sshd_pid" ]]; then
    kill "$sshd_pid" 2>/dev/null || true
    wait "$sshd_pid" 2>/dev/null || true
  fi
  # The directory itself is created by the image; an unprivileged process
  # cannot put it back, so only its contents go.
  rm -rf "${runtime_dir:?}"/*
}

trap cleanup EXIT
# A stop request is not a failure: exiting 143 makes Kubernetes report Error.
trap 'exit 0' TERM INT

# An absent optional Secret still gets a subPath mount, which kubelet creates as
# an empty directory, so the mount path existing proves nothing.
[[ -f "$mounted_keys" && -s "$mounted_keys" ]] || {
  echo "Provide SSH public keys at $mounted_keys; public-key login is the only way in." >&2
  exit 1
}

# Docker keeps the writable layer across restarts, so clear what a previous run left.
rm -rf "${runtime_dir:?}"/*

# PAM imports only the proxy allowlist into SSH sessions.
: > "$runtime_dir/session.env"
chmod 0644 "$runtime_dir/session.env"
for name in http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY; do
  [[ -v "$name" ]] || continue
  value=${!name}
  if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
    echo "Invalid $name: proxy environment values must be single-line." >&2
    exit 1
  fi
  printf '%s=%s\n' "$name" "$value" >> "$runtime_dir/session.env"
done

# A fresh home volume hides what the image put there; put back the skeleton
# without overwriting anything the user has changed since.
cp -r --update=none /etc/skel/. "$home_dir/"

umask 077
mkdir -p "$ssh_dir"

# sshd refuses a key file owned by anyone but the account or root, which a
# bind-mounted or Secret-projected file rarely is, so it is copied in.
cat "$mounted_keys" > "$authorized_keys"

if [[ -f "$mounted_host_keys/ssh_host_ed25519_key" ]]; then
  host_key_source="$mounted_host_keys"
else
  host_key_source="$persisted_host_keys"
  mkdir -p "$host_key_source"
  [[ -f "$host_key_source/ssh_host_ed25519_key" ]] \
    || ssh-keygen -q -t ed25519 -N '' -C devbox -f "$host_key_source/ssh_host_ed25519_key"
  [[ -f "$host_key_source/ssh_host_rsa_key" ]] \
    || ssh-keygen -q -t rsa -b 3072 -N '' -C devbox -f "$host_key_source/ssh_host_rsa_key"
fi
# Copied rather than referenced: sshd rejects a private key that is group or
# world readable, which a Secret mounted with fsGroup always is.
for key_type in ed25519 rsa; do
  key="$host_key_source/ssh_host_${key_type}_key"
  [[ -f "$key" ]] || continue
  cat "$key" > "$ssh_dir/ssh_host_${key_type}_key"
  ssh-keygen -l -f "$ssh_dir/ssh_host_${key_type}_key" | sed 's/^/Host key: /'
done

umask 022

/usr/sbin/sshd -D -e &
sshd_pid=$!
printf '%s\n' "$sshd_pid" > "$runtime_dir/sshd.pid"

# wait returns early when TERM arrives, so the trap above still gets to run.
status=0
wait "$sshd_pid" || status=$?
sshd_pid=""
echo "sshd exited unexpectedly with status $status." >&2
exit 1
