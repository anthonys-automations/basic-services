#!/usr/bin/env bash
set -euo pipefail

runtime_dir="${SANDBOX_RUNTIME_DIR:-/run/sandbox}"
session_marker="$runtime_dir/session-active"
ready_marker="$runtime_dir/ready"
sshd_pid=""
xrdp_pid=""
sesman_pid=""

cleanup() {
  rm -rf "$runtime_dir"
  for pid in "$sshd_pid" "$xrdp_pid" "$sesman_pid"; do
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  done
}

trap cleanup EXIT
trap 'exit 143' TERM INT

prepare_runtime() {
  rm -rf "$runtime_dir"
  mkdir -p "$runtime_dir"
  chmod 700 "$runtime_dir"
  printf '%s\n' "$SANDBOX_MODE" > "$runtime_dir/mode"

  rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub
  ssh-keygen -A
  make-ssl-cert generate-default-snakeoil --force-overwrite
}

claim_session() {
  touch "$session_marker"
  rm -f "$ready_marker"
}

write_pid() {
  printf '%s\n' "$2" > "$runtime_dir/$1.pid"
}

daemon_alive() {
  kill -0 "$1" 2>/dev/null
}

start_xrdp() {
  [[ -n "${XRDP_PASSWORD:-}" ]] || {
    echo "SANDBOX_MODE=xrdp requires XRDP_PASSWORD." >&2
    return 1
  }

  echo "user:${XRDP_PASSWORD}" | chpasswd
  unset XRDP_PASSWORD

  rm -f /var/run/xrdp/xrdp.pid /var/run/xrdp/xrdp-sesman.pid
  xrdp-sesman --nodaemon &
  sesman_pid=$!
  write_pid sesman "$sesman_pid"
  xrdp --nodaemon &
  xrdp_pid=$!
  write_pid xrdp "$xrdp_pid"

  sleep 1
  daemon_alive "$sesman_pid" && daemon_alive "$xrdp_pid" || return 1
  touch "$ready_marker"

  # A sesman child is an authenticated desktop, so probes cannot claim the sandbox.
  while ! pgrep -P "$sesman_pid" >/dev/null 2>&1; do
    daemon_alive "$sesman_pid" && daemon_alive "$xrdp_pid" || return 1
    sleep 1
  done

  local connection_pid
  connection_pid=$(pgrep -P "$xrdp_pid" | head -1) || return 1
  claim_session

  # The active connection inherits the socket; remove the master to bar new clients.
  kill "$xrdp_pid" 2>/dev/null || true
  xrdp_pid=""
  rm -f "$runtime_dir/xrdp.pid"

  while kill -0 "$connection_pid" 2>/dev/null; do
    daemon_alive "$sesman_pid" || return 1
    sleep 1
  done
}

start_sshd() {
  local authorized_keys=/home/user/.ssh/authorized_keys
  [[ -s "$authorized_keys" ]] || {
    echo "SANDBOX_MODE=ssh requires a public key at $authorized_keys." >&2
    return 1
  }

  local log_fifo="$runtime_dir/sshd-events"
  mkfifo "$log_fifo"

  /usr/sbin/sshd -D -e \
    -o PermitRootLogin=no \
    -o PasswordAuthentication=no \
    -o KbdInteractiveAuthentication=no \
    -o AllowUsers=user \
    -o MaxStartups=1 2>"$log_fifo" &
  sshd_pid=$!
  write_pid sshd "$sshd_pid"

  sleep 1
  daemon_alive "$sshd_pid" || return 1
  touch "$ready_marker"

  local connected=""
  while IFS= read -r line; do
    printf '%s\n' "$line"
    case "$line" in
      *"Accepted publickey"*)
        connected=1
        claim_session
        # Established sessions outlive the listener, so stop it to bar a second client.
        kill "$sshd_pid" 2>/dev/null || true
        sshd_pid=""
        rm -f "$runtime_dir/sshd.pid"
        ;;
      *"Disconnected from user"* | *"Connection closed by user"*)
        [[ -n "$connected" ]] && return 0
        ;;
    esac
  done < "$log_fifo"

  [[ -n "$connected" ]] || return 1
}

case "${SANDBOX_MODE:-}" in
  ssh|xrdp)
    prepare_runtime
    ;;
  *)
    echo "Set SANDBOX_MODE to ssh or xrdp." >&2
    exit 1
    ;;
esac

case "$SANDBOX_MODE" in
  ssh) start_sshd ;;
  xrdp) start_xrdp ;;
esac

echo "Client disconnected; exiting."
