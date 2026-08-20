#!/usr/bin/env bash
set -euo pipefail

# Named in /etc/ssh/sshd_config, /etc/pam.d/xrdp-sesman and xrdp.ini, none of
# which this container can edit, so the path is fixed rather than configurable.
runtime_dir=/run/sandbox
sessions_dir="$runtime_dir/sessions"
ready_marker="$runtime_dir/ready"
ssh_dir="$runtime_dir/ssh"
# /etc/pam.d/xrdp-sesman names this file, and only root can edit that.
xrdp_passwd="$runtime_dir/xrdp.passwd"
mounted_keys=/home/user/.ssh/authorized_keys
authorized_keys="$runtime_dir/authorized_keys"
daemon_pids=()

cleanup() {
  # The directory itself is created by the image; an unprivileged process
  # cannot put it back, so only its contents go.
  rm -rf "${runtime_dir:?}"/*
  for pid in ${daemon_pids[@]+"${daemon_pids[@]}"}; do
    kill "$pid" 2>/dev/null || true
  done
}

trap cleanup EXIT
# A stop request is not a failure: exiting 143 makes Kubernetes report Error and
# count the Pod towards CrashLoopBackOff.
trap 'exit 0' TERM INT

process_alive() {
  local stat
  # Unreaped daemons linger as zombies, so the state field, not existence, is the test.
  read -r stat 2>/dev/null < "/proc/$1/stat" || return 1
  [[ "${stat##*) }" != Z\ * ]]
}

# An absent optional Secret still gets a subPath mount, which kubelet creates as
# an empty directory, so the mount path existing proves nothing.
have_mounted_keys() {
  [[ -f "$mounted_keys" && -s "$mounted_keys" ]]
}

prepare_runtime() {
  local prior_umask
  [[ -n "${XRDP_PASSWORD:-}" ]] || have_mounted_keys || {
    echo "Provide an SSH public key at $mounted_keys, XRDP_PASSWORD, or both." >&2
    exit 1
  }

  rm -rf "${runtime_dir:?}"/*
  mkdir -p "$sessions_dir" "$ssh_dir"
  # With a read-only root filesystem these are volumes, so the image's copies are
  # hidden: recreate what xrdp, X and ICE will not create for a non-root process,
  # and put back the skeleton the account was created with.
  mkdir -p /run/xrdp/sockdir /tmp/.X11-unix /tmp/.ICE-unix
  cp -r --update=none /etc/skel/. /home/user/
  # Private keys and the password hash are written below; sessions get the
  # default back before any of them start.
  prior_umask=$(umask)
  umask 077

  # sshd refuses a key file owned by anyone but the account or root, which a
  # bind-mounted or Secret-projected file rarely is, so it is copied in.
  : > "$authorized_keys"
  if have_mounted_keys; then
    cat "$mounted_keys" > "$authorized_keys"
  fi

  ssh-keygen -q -t ed25519 -N '' -f "$ssh_dir/ssh_host_ed25519_key"
  ssh-keygen -q -t rsa -b 3072 -N '' -f "$ssh_dir/ssh_host_rsa_key"

  openssl req -x509 -noenc -newkey rsa:2048 -days 365 -subj '/CN=sandbox-browser' \
    -keyout "$runtime_dir/key.pem" -out "$runtime_dir/cert.pem" 2>/dev/null

  # Without this file pam_pwdfile fails every RDP login, which is the agent-only case.
  if [[ -n "${XRDP_PASSWORD:-}" ]]; then
    printf 'user:%s\n' "$(printf '%s' "$XRDP_PASSWORD" | openssl passwd -6 -stdin)" > "$xrdp_passwd"
    unset XRDP_PASSWORD
  fi

  rm -f /run/xrdp/xrdp.pid /run/xrdp/xrdp-sesman.pid
  umask "$prior_umask"
}

start_daemon() {
  local name=$1
  shift
  "$@" &
  local pid=$!
  daemon_pids+=("$pid")
  printf '%s\n' "$pid" > "$runtime_dir/$name.pid"
}

start_daemons() {
  start_daemon sshd /usr/sbin/sshd -D -e
  # sesman aborts its session setup when setgroups is refused; see the Dockerfile.
  start_daemon sesman env LD_PRELOAD=/usr/local/lib/noinitgroups.so xrdp-sesman --nodaemon
  start_daemon xrdp xrdp --nodaemon
}

daemons_alive() {
  local pid
  for pid in "${daemon_pids[@]}"; do
    process_alive "$pid" || return 1
  done
}

# Markers are named after the sshd or xrdp-sesman process owning the session, so a
# session lost without a PAM close is reaped instead of pinning the container forever.
reap_dead_sessions() {
  local marker
  for marker in "$sessions_dir"/*; do
    [[ -e "$marker" ]] || continue
    process_alive "${marker##*/}" || rm -f "$marker"
  done
}

sessions_active() {
  compgen -G "$sessions_dir/*" >/dev/null
}

prepare_runtime
start_daemons

sleep 1
daemons_alive || {
  echo "SSH or XRDP failed to start." >&2
  exit 1
}
touch "$ready_marker"

claimed=""
while daemons_alive; do
  reap_dead_sessions
  if sessions_active; then
    claimed=1
  elif [[ -n "$claimed" ]]; then
    echo "All sessions ended; exiting."
    exit 0
  fi
  sleep 1
done

echo "SSH or XRDP exited unexpectedly." >&2
exit 1
