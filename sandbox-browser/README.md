# Sandbox Browser

A container for browser automation with Chromium and Firefox. A single image runs in one of two explicit modes:

- **Agent mode** — SSH access for an LLM agent to run headless Playwright tasks.
- **Desktop mode** — XRDP + XFCE so a human can drive Firefox interactively.

Set `SANDBOX_MODE=ssh` or `SANDBOX_MODE=xrdp`. The supplied Compose profiles set the appropriate value.

## Contents

- Non-root `user` account, Node.js, Playwright, Chromium, and Firefox.
- `firefox` and `chromium` launchers on `PATH` for interactive use.
- A bind-mounted `/home/user/workspace` shared by both modes.
- Per-container SSH host keys and XRDP TLS certificate generated at startup.

## Prerequisites

- Docker Engine with Compose v2.
- For agent mode, an SSH key pair: `ssh-keygen -t ed25519 -f ~/.ssh/sandbox-browser`.
- For desktop mode, an RDP client such as Remmina, FreeRDP, or Windows Remote Desktop.

## Agent mode (SSH)

```bash
export AUTHORIZED_KEYS_FILE="$HOME/.ssh/sandbox-browser.pub"
export WORKSPACE_DIR="$PWD/workspace"
mkdir -p "$WORKSPACE_DIR"
docker compose --profile agent up --build -d
```

The container refuses to start without a mounted public key, and SSH passwords are disabled.

```bash
ssh -p 2222 -i ~/.ssh/sandbox-browser user@localhost
node -e "const { chromium, firefox } = require('playwright'); Promise.all([chromium.launch().then(b => b.close()), firefox.launch().then(b => b.close())]).then(() => console.log('both browsers launched'))"
```

An agent can work in `/home/user/workspace` and invoke `node`, `python3`, `git`, or Playwright directly. Playwright runs headlessly, so no desktop is required.

## Desktop mode (XRDP)

```bash
export XRDP_PASSWORD='choose-a-strong-password'
export WORKSPACE_DIR="$PWD/workspace"
docker compose --profile desktop up --build -d
```

`SANDBOX_MODE=xrdp` requires `XRDP_PASSWORD`; a missing value exits with a configuration error. Connect an RDP client to `127.0.0.1:3389` and log in as `user` with that password. XFCE starts automatically, and Firefox can be launched from the application menu or a terminal.

The password is applied to the `user` account at startup, so no credential is stored in the image. The entrypoint unsets the variable before starting the desktop, keeping it out of session processes.

### Security notes

- SSH host keys and the XRDP TLS certificate are generated per container startup. For stable host identity, mount managed keys instead.
- The RDP port is published on loopback only. Keep it behind a VPN or SSH tunnel and never expose it to an untrusted network.
- `XRDP_PASSWORD` is visible to anyone who can run `docker inspect`. Use a unique, disposable password.
- SSH password authentication stays disabled in both modes.

## Session lifecycle

The container serves one authenticated session at a time. PAM atomically claims the sandbox before the SSH command or RDP desktop session opens; competing sessions are rejected. The listener stops once claimed, readiness drops, and the container exits when the client disconnects. Both Compose services use `restart: unless-stopped` to return to the pool.

### Readiness and liveness

Runtime state is stored in `/run/sandbox` (override with `SANDBOX_RUNTIME_DIR`). `/run/sandbox/session-active` exists while a client holds the sandbox. The readiness probe is successful only while an unclaimed listener is running; the liveness probe monitors listener processes until the sandbox is claimed, then leaves established-session supervision to the entrypoint.

```yaml
readinessProbe:
  exec:
    command: ["/usr/local/bin/readiness-probe.sh"]
  periodSeconds: 2
  failureThreshold: 1
livenessProbe:
  exec:
    command: ["/usr/local/bin/liveness-probe.sh"]
  periodSeconds: 5
  failureThreshold: 1
```

A restart replaces processes but not Docker's writable layer. For a pristine local Docker sandbox per session, recreate the container:

```bash
docker compose --profile agent up -d --force-recreate
```

In Kubernetes, only mounted volumes carry state between restarted containers.

## Notes on browsers

- Ubuntu's `firefox` apt package is a snap stub that cannot run in a container, so both launchers point at Playwright's bundled builds.
- Chromium's internal sandbox requires user namespaces. Where the container forbids them, the `chromium` launcher falls back to `--no-sandbox` and the container boundary remains the isolation layer. Firefox handles this case itself.

## Version policy

The Playwright version is pinned in both the `FROM` tag and the npm package installed alongside it. Renovate updates them together; after a manual update, re-test both modes.

## Design

Background on the desktop variant is in [docs/xrdp-variant.md](docs/xrdp-variant.md).
