# XRDP Desktop Mode

The interactive desktop and SSH automation host share one image. `SANDBOX_MODE=xrdp` selects the desktop; `SANDBOX_MODE=ssh` selects the SSH host. This explicit mode prevents a missing RDP password from accidentally starting an unreachable SSH listener.

## Behavior

- XRDP mode requires `XRDP_PASSWORD`, applies it to `user`, then starts `xrdp-sesman` and `xrdp` on port 3389.
- SSH mode requires `/home/user/.ssh/authorized_keys` and starts key-only `sshd` on port 22.
- Both modes share the `user` account, `/home/user/workspace`, Playwright, Chromium, and Firefox.
- SSH host keys and the XRDP TLS certificate are generated at startup, once per container instance.

## Implementation choices

- **Xvnc backend, not Xorg.** `xorgxrdp` expects host privileges and device access that a container does not have. `xrdp.ini` sets `autorun=Xvnc` so sessions start deterministically.
- **XFCE session.** `/etc/xrdp/startwm.sh` clears inherited DBus variables before running `startxfce4`.
- **Bundled browsers.** Ubuntu's `firefox` package is a snap stub, so browser launchers point to exact Playwright browser paths resolved during image build.
- **Single session.** `pam_exec` atomically creates `/run/sandbox/session-lock` during session open. A competing SSH or XRDP session is rejected before it can run work. `MaxSessions=1` adds an XRDP-side limit.

## Disconnect handling

The container exits when its client disconnects so a restart policy can return it to the pool.

- `KillDisconnected=true` prevents XRDP sessions being parked for reconnection.
- The entrypoint watches the per-client `xrdp` process after claim, since the master listener is intentionally stopped to reject new connections.
- It monitors listener processes before claim; a daemon crash exits PID 1 rather than leaving an indefinitely unready container.

## Kubernetes probes

- `/usr/local/bin/readiness-probe.sh` is successful only when a listener is up and the sandbox is unclaimed.
- `/usr/local/bin/liveness-probe.sh` verifies listener PIDs before claim. After claim, the entrypoint supervises the live session.

## Security requirements

- Publish 3389 on loopback or a private network only; put it behind a VPN or SSH tunnel.
- Provide a unique, disposable `XRDP_PASSWORD` at runtime. It is not stored in the image, though it remains visible via `docker inspect`.
- The desktop session runs as `user`, never root.
- SSH keeps password and keyboard-interactive authentication disabled.
