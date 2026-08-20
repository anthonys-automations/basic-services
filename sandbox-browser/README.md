# Sandbox Browser

A container for browser automation with Chromium and Firefox. One container serves both access paths at once:

- **SSH** — for an LLM agent to run headless Playwright tasks.
- **RDP** — XRDP + XFCE so a human can drive Firefox interactively.

Both listeners always start. Supply an SSH public key, `XRDP_PASSWORD`, or both; the container refuses to start with neither. Without a password the `user` account stays locked, so RDP rejects every login.

## Contents

- A single unprivileged account, `user` (UID/GID 10000), which every process
  including the listeners runs as. 1000 and 1001 belong to the base image.
- Node.js, Playwright, Chromium, and Firefox.
- `firefox` and `chromium` launchers on `PATH` for interactive use.
- A bind-mounted `/home/user/workspace`.
- Per-container SSH host keys and XRDP TLS certificate generated at startup.

## Prerequisites

- Docker Engine with Compose v2.
- For SSH, a key pair: `ssh-keygen -t ed25519 -f ~/.ssh/sandbox-browser`.
- For RDP, a client such as Remmina, FreeRDP, or Windows Remote Desktop.
- A workspace directory writable by UID 10000: `sudo chown 10000:10000 ./workspace`.

## Run

```bash
export AUTHORIZED_KEYS_FILE="$HOME/.ssh/sandbox-browser.pub"
export XRDP_PASSWORD='choose-a-strong-password'
export WORKSPACE_DIR="$PWD/workspace"
mkdir -p "$WORKSPACE_DIR"
docker compose up --build -d
```

Compose always binds an `authorized_keys` file. For an RDP-only container, point `AUTHORIZED_KEYS_FILE` at an empty file so Docker does not create a directory in its place:

```bash
mkdir -p secrets && touch secrets/authorized_keys
```

### Agent access (SSH)

```bash
ssh -p 2222 -i ~/.ssh/sandbox-browser user@localhost
node -e "const { chromium, firefox } = require('playwright'); Promise.all([chromium.launch().then(b => b.close()), firefox.launch().then(b => b.close())]).then(() => console.log('both browsers launched'))"
```

An agent can work in `/home/user/workspace` and invoke `node`, `python3`, `git`, or Playwright directly. Playwright runs headlessly, so no desktop is required. SSH passwords are disabled.

`sshd` listens on 2222: the container holds no capability to bind a privileged port. The mounted `authorized_keys` is copied into the runtime directory at startup, because `sshd` rejects a key file owned by neither the account nor root, which is what a bind mount or a Kubernetes Secret usually produces.

### Desktop access (RDP)

Connect an RDP client to `127.0.0.1:3389` and log in as `user` with `XRDP_PASSWORD`. XFCE starts automatically, and Firefox can be launched from the application menu or a terminal.

The password is hashed into a runtime file that PAM checks; nothing is written to `/etc/shadow`, which an unprivileged container cannot touch anyway. No credential is stored in the image, and the entrypoint unsets the variable before starting the listeners, keeping it out of session processes.

### Security notes

- Every process runs as UID 10000. No capability is required, so the container can run under a restricted Kubernetes Pod Security Standard.
- SSH host keys and the XRDP TLS certificate are generated per container startup. For stable host identity, mount managed keys instead.
- The RDP port is published on loopback only. Keep it behind a VPN or SSH tunnel and never expose it to an untrusted network.
- `XRDP_PASSWORD` is visible to anyone who can run `docker inspect`. Use a unique, disposable password.
- SSH password authentication stays disabled.

## Kubernetes

[k8s/sandbox-browser.yaml](k8s/sandbox-browser.yaml) is a working example of a Deployment and a ClusterIP Service. The readiness probe is what makes a replica pool usable: a claimed Pod leaves the Service endpoints, so the next client lands on an unused one.

Every session ends in a container restart, and Kubernetes rate limits restarts, so a replica that has just recycled can sit in `CrashLoopBackOff` for a while before it is ready again. Run more replicas than concurrent tenants so a recycling one is never the only candidate. A startup probe covers the few seconds the container spends generating host keys and the TLS certificate, which is otherwise long enough for the first liveness check to kill it.

The Pod runs with `readOnlyRootFilesystem: true`, which needs an `emptyDir` for every path written after startup: `/home/user` for the account and its desktop state, `/tmp` for the X and ICE sockets, `/run/sandbox` for the runtime state below, `/run/xrdp` for xrdp's own sockets and PID files, and `/dev/shm` for the browsers. Those volumes hide what the image put at the same paths, so the entrypoint recreates the socket directories and copies `/etc/skel` back into the home directory. Dropping a volume is not an option: the daemon that needs it fails at startup instead of falling back.

```bash
kubectl apply -f k8s/sandbox-browser.yaml
```

## Session lifecycle

The container is claimed by the first client, over either protocol. PAM records a session marker on open and removes it on close, and the first marker drops readiness so a load balancer stops sending new clients. Both listeners keep running, so a client that raced in — an agent opening SSH alongside its own desktop, for example — is served rather than rejected. The container exits once every session has ended, and `restart: unless-stopped` returns it to the pool. A desktop is not parked for reconnection: Xvnc terminates ten seconds after the RDP client disconnects, which ends that session.

### Readiness and liveness

Runtime state is stored in `/run/sandbox`, which the image creates because an unprivileged process cannot. Host keys, the TLS pair, the RDP password hash, and the xrdp logs all live there; the path is also compiled into the `sshd`, xrdp and PAM configuration, so it is fixed. `/run/sandbox/sessions` holds one marker per live session, named after the owning `sshd` or `xrdp-sesman` process so the entrypoint can reap a session that died without a PAM close. The readiness probe is successful only while the sandbox is unclaimed; the liveness probe watches both listeners for the whole container life.

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
  failureThreshold: 3
```

A restart replaces processes but not Docker's writable layer. For a pristine local Docker sandbox per session, recreate the container:

```bash
docker compose up -d --force-recreate
```

In Kubernetes, only mounted volumes carry state between restarted containers.

## Notes on browsers

- Ubuntu's `firefox` apt package is a snap stub that cannot run in a container, so both launchers point at Playwright's bundled builds.
- Chromium's internal sandbox requires user namespaces. Where the container forbids them, the `chromium` launcher falls back to `--no-sandbox` and the container boundary remains the isolation layer. Firefox handles this case itself.

## Version policy

The Playwright version is pinned in both the `FROM` tag and the npm package installed alongside it. Renovate updates them together; after a manual update, re-test both access paths.

## Design

Background on the desktop side is in [docs/xrdp-variant.md](docs/xrdp-variant.md).
