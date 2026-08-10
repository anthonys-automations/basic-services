# XRDP Desktop Mode

The interactive desktop and the SSH automation host are the same container: `sshd`, `xrdp-sesman`, and `xrdp` all start together. Earlier revisions selected one with `SANDBOX_MODE`, which required the entrypoint to supervise a different process tree per mode. Running both removes that branching, and a load balancer decides which port a tenant actually uses.

## Behavior

- Startup requires an SSH public key at `/home/user/.ssh/authorized_keys`, `XRDP_PASSWORD`, or both.
- `XRDP_PASSWORD` is applied to `user`. Without it the account stays locked, so RDP authentication always fails while SSH keys still work.
- `sshd` is key-only on port 22; `xrdp` listens on 3389.
- Both paths share the `user` account, `/home/user/workspace`, Playwright, Chromium, and Firefox.
- SSH host keys and the XRDP TLS certificate are generated at startup, once per container instance.

## Implementation choices

- **Xvnc backend, not Xorg.** `xorgxrdp` expects host privileges and device access that a container does not have. `xrdp.ini` sets `autorun=Xvnc` so sessions start deterministically.
- **XFCE session.** `/etc/xrdp/startwm.sh` clears inherited DBus variables before running `startxfce4`.
- **Bundled browsers.** Ubuntu's `firefox` package is a snap stub, so browser launchers point to exact Playwright browser paths resolved during image build.
- **Session tracking, not exclusion.** `pam_exec` creates `/run/sandbox/sessions/<pid>` on session open and removes it on close, for both SSH and XRDP. Concurrent sessions are allowed; readiness is what keeps a claimed container out of the pool. `MaxSessions=1` still limits XRDP to one desktop.

## Disconnect handling

The container exits once every session has ended so a restart policy can return it to the pool.

- `KillDisconnected=true` prevents XRDP sessions being parked for reconnection.
- The entrypoint polls the session markers and exits after the set becomes empty, having been non-empty.
- Markers are named after the owning `sshd` or `xrdp-sesman` process, so a session that never reaches PAM close is reaped by liveness check instead of pinning the container.
- Both listeners are monitored for the whole container life; a daemon crash exits PID 1 rather than leaving a half-working container.

## Kubernetes probes

- `/usr/local/bin/readiness-probe.sh` is successful only while the sandbox is unclaimed.
- `/usr/local/bin/liveness-probe.sh` verifies the `sshd`, `xrdp-sesman`, and `xrdp` PIDs.

## Security requirements

- Publish 3389 on loopback or a private network only; put it behind a VPN or SSH tunnel.
- Provide a unique, disposable `XRDP_PASSWORD` at runtime. It is not stored in the image, though it remains visible via `docker inspect`.
- Omit `XRDP_PASSWORD` entirely for agent-only deployments; the locked account is the RDP kill switch.
- The desktop session runs as `user`, never root.
- SSH keeps password and keyboard-interactive authentication disabled.
