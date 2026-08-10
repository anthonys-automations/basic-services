#!/usr/bin/env bash
set -euo pipefail

runtime_dir="${SANDBOX_RUNTIME_DIR:-/run/sandbox}"
sessions_dir="$runtime_dir/sessions"
ready_marker="$runtime_dir/ready"
authorized_keys=/home/user/.ssh/authorized_keys
daemon_pids=()

cleanup() {
  rm -rf "$runtime_dir"
  for pid in ${daemon_pids[@]+"${daemon_pids[@]}"}; do
    kill "$pid" 2>/dev/null || true
  done
}

trap cleanup EXIT
trap 'exit 143' TERM INT

process_alive() {
  local stat
  # Unreaped daemons linger as zombies, so the state field, not existence, is the test.
  read -r stat 2>/dev/null < "/proc/$1/stat" || return 1
  [[ "${stat##*) }" != Z\ * ]]
}

prepare_runtime() {
  [[ -s "$authorized_keys" || -n "${XRDP_PASSWORD:-}" ]] || {
    echo "Provide an SSH public key at $authorized_keys, XRDP_PASSWORD, or both." >&2
    exit 1
  }

  rm -rf "$runtime_dir"
  mkdir -p "$sessions_dir"
  chmod 700 "$runtime_dir"

  rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub
  ssh-keygen -A
  make-ssl-cert generate-default-snakeoil --force-overwrite

  # Without a password the account stays locked, so RDP rejects every login.
  if [[ -n "${XRDP_PASSWORD:-}" ]]; then
    echo "user:${XRDP_PASSWORD}" | chpasswd
    unset XRDP_PASSWORD
  fi

  rm -f /var/run/xrdp/xrdp.pid /var/run/xrdp/xrdp-sesman.pid
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
  start_daemon sshd /usr/sbin/sshd -D -e \
    -o PermitRootLogin=no \
    -o PasswordAuthentication=no \
    -o KbdInteractiveAuthentication=no \
    -o AllowUsers=user
  start_daemon sesman xrdp-sesman --nodaemon
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
