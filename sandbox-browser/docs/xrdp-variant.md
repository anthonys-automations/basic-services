# XRDP Desktop Mode

The interactive desktop and the SSH automation host are the same container: `sshd`, `xrdp-sesman`, and `xrdp` all start together. Earlier revisions selected one with `SANDBOX_MODE`, which required the entrypoint to supervise a different process tree per mode. Running both removes that branching, and a load balancer decides which port a tenant actually uses.

## Behavior

- Startup requires an SSH public key at `/home/user/.ssh/authorized_keys`, `XRDP_PASSWORD`, or both.
- `XRDP_PASSWORD` is hashed into a PAM password file. Without it that file is absent, so RDP authentication always fails while SSH keys still work.
- `sshd` is key-only on port 2222; `xrdp` listens on 3389.
- Every process, listeners included, runs as `user` (UID/GID 10000).
- Both paths share the `user` account, `/home/user/workspace`, Playwright, Chromium, and Firefox.
- SSH host keys and the XRDP TLS certificate are generated at startup, once per container instance.

## Implementation choices

- **Xvnc backend, not Xorg.** `xorgxrdp` expects host privileges and device access that a container does not have. `xrdp.ini` sets `autorun=Xvnc`, but that only covers clients that send credentials; everyone else gets the login window, which offers the session sections in file order and would otherwise start with `Xorg`. The `Xorg`, `vnc-any` and `neutrinordp-any` sections are deleted from `xrdp.ini` so `Xvnc` is the only choice - which also stops the container being used to proxy RDP or VNC to any host a client names.
- **XFCE session.** `/etc/xrdp/startwm.sh` clears inherited DBus variables before running `startxfce4`.
- **Bundled browsers.** Ubuntu's `firefox` package is a snap stub, so browser launchers point to exact Playwright browser paths resolved during image build.
- **Session tracking, not exclusion.** `pam_exec` creates `/run/sandbox/sessions/<pid>` on session open and removes it on close, for both SSH and XRDP. Concurrent sessions are allowed; readiness is what keeps a claimed container out of the pool. `MaxSessions=1` still limits XRDP to one desktop.

## Running unprivileged

Nothing in the container runs as root, which costs the daemons the privileges they normally assume. Each is dealt with where it is cheapest:

- **Port 2222 for SSH.** Binding 22 needs `CAP_NET_BIND_SERVICE`; publishing the container port is the deployment's job anyway.
- **Writable state in `/run/sandbox`.** `/etc/ssh`, `/etc/ssl` and `/var/log` are root-owned, so host keys, the TLS pair and the xrdp logs move to a directory the image creates and hands to `user`. The entrypoint clears its contents rather than the directory itself, which it could not recreate. `sshd` still reads its own `/etc/ssh/sshd_config`, replaced at build time because it names those paths.
- **`pam_pwdfile` for RDP.** `pam_unix` needs `/etc/shadow`, which cannot be read or written here, so `XRDP_PASSWORD` is hashed into `/run/sandbox/xrdp.passwd` instead. The distribution PAM stack for `xrdp-sesman` is replaced wholesale; `pam_motd` is dropped from the `sshd` stack for the same reason.
- **A no-op `initgroups`.** `xrdp-sesman` drops privileges with `setgid`, `initgroups` and `setuid` before starting a desktop. Only `initgroups` fails, because `setgroups(2)` insists on `CAP_SETGID` even when the group list does not change, and sesman abandons the rest of its environment setup on that failure - leaving `HOME` unset and Xvnc launched with an empty `-rfbauth`, so the desktop dies on connect. A three-line preload library returns success for that one call. Granting the capability instead would also work, but only by handing the container a privilege it has no other use for.

## Disconnect handling

The container exits once every session has ended so a restart policy can return it to the pool.

- `-MaxDisconnectionTime=10` ends Xvnc ten seconds after the RDP client goes away, which ends the window manager and the session. sesman's own `KillDisconnected` is not used: sesman only forwards it to the X server as `XRDP_SESMAN_KILL_DISCONNECTED`, and acting on it is xorgxrdp's job, so it does nothing for an Xvnc session.
- The entrypoint polls the session markers and exits after the set becomes empty, having been non-empty.
- Markers are named after the owning `sshd` or `xrdp-sesman` process, so a session that never reaches PAM close is reaped by liveness check instead of pinning the container.
- Both listeners are monitored for the whole container life; a daemon crash exits PID 1 rather than leaving a half-working container.

## Kubernetes probes

- `/usr/local/bin/readiness-probe.sh` is successful only while the sandbox is unclaimed.
- `/usr/local/bin/liveness-probe.sh` verifies the `sshd`, `xrdp-sesman`, and `xrdp` PIDs.

## Security requirements

- Publish 3389 on loopback or a private network only; put it behind a VPN or SSH tunnel.
- Provide a unique, disposable `XRDP_PASSWORD` at runtime. It is not stored in the image, though it remains visible via `docker inspect`.
- Omit `XRDP_PASSWORD` entirely for agent-only deployments; the missing password file is the RDP kill switch.
- Nothing runs as root, and no capability is needed, so the image satisfies a restricted Pod Security Standard.
- SSH keeps password and keyboard-interactive authentication disabled.
