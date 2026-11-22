# Sandbox Browser

A container for browser automation with Playwright Chromium, plus desktop browsers for a human. One container serves both access paths at once:

- **SSH** — for an LLM agent to run headless Playwright tasks.
- **RDP** — XRDP + XFCE so a human can drive Firefox or Google Chrome interactively.

Both listeners always start. Supply an SSH public key, `XRDP_PASSWORD`, or both; the container refuses to start with neither. Without a password the `user` account stays locked, so RDP rejects every login.

## Contents

- A single unprivileged account, `user` (UID/GID 10000), which every process
  including the listeners runs as. 1000 and 1001 belong to the base image.
- Node.js, Playwright and its Chromium build, the only browser for automation.
- Stock Mozilla Firefox and Google Chrome for interactive use, launched as
  `firefox` and `google-chrome` or from the application menu.
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
node -e "require('playwright').chromium.launch().then(b => b.close()).then(() => console.log('chromium launched'))"
```

An agent can work in `/home/user/workspace` and invoke `node`, `python3`, `git`, or Playwright directly. Playwright runs headlessly, so no desktop is required. SSH passwords are disabled.

`sshd` listens on 2222: the container holds no capability to bind a privileged port. The mounted `authorized_keys` is copied into the runtime directory at startup, because `sshd` rejects a key file owned by neither the account nor root, which is what a bind mount or a Kubernetes Secret usually produces.

### Desktop access (RDP)

Connect an RDP client to `127.0.0.1:3389` and log in as `user` with `XRDP_PASSWORD`. XFCE starts automatically, and Firefox and Google Chrome can be launched from the application menu or a terminal. The panel shows one button per window rather than grouping them by application.

The keyboard layout is the one active on the client when it connects: xrdp translates keys with that layout's keymap and hands Xvnc finished characters, so switching layouts in the session or on the client has no effect until you reconnect. Switch the Windows layout before connecting to type in another one. Alt+Shift, the Windows layout hotkey, is passed through as ordinary Alt and Shift; the shipped xrdp keymaps turned Alt into a different key while Shift was held, which left Alt stuck down for the rest of the session, and the image corrects them.

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

The Pod requests 900m CPU for browser work under node contention and has no CPU limit, so it can still use available burst capacity. It runs with `readOnlyRootFilesystem: true`, which needs an `emptyDir` for every path written after startup: `/home/user` for the account and its desktop state, `/tmp` for the X and ICE sockets, `/run/sandbox` for the runtime state below, `/run/xrdp` for xrdp's own sockets and PID files, and `/dev/shm` for the browsers. Those volumes hide what the image put at the same paths, so the entrypoint recreates the socket directories and copies `/etc/skel` back into the home directory. Dropping a volume is not an option: the daemon that needs it fails at startup instead of falling back.

```bash
kubectl apply -f k8s/sandbox-browser.yaml
```

## Session lifecycle

The container is claimed by the first client, over either protocol. PAM records a session marker on open and removes it on close, and the first marker drops readiness so a load balancer stops sending new clients. Both listeners keep running, so a client that raced in — an agent opening SSH alongside its own desktop, for example — is served rather than rejected. The container exits once every session has ended, and `restart: unless-stopped` returns it to the pool. A desktop is not parked for reconnection: Xvnc is configured to stop ten seconds after disconnect, and the entrypoint reaps a stale RDP marker after 30 seconds without an established client connection.

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
In particular, `emptyDir` home and workspace contents survive container restarts
within the same Pod; replace the Pod to clear them. Automatic cleanup is not
enabled, so do not treat a container restart as a clean tenant boundary.

## Notes on browsers

- Automation and humans use different browsers. Playwright's builds identify
  themselves as automated (`navigator.webdriver`, a testing banner, no WebGL
  in its Firefox), which bot checks such as captchas reject outright, so the
  desktop gets stock vendor builds instead and Playwright keeps only its
  Chromium. Playwright's Firefox and WebKit are removed from the image.
- At startup, the entrypoint writes the configured `http_proxy`, `https_proxy`,
  `all_proxy`, `no_proxy` and their uppercase equivalents to
  `/run/sandbox/session.env`.
  PAM loads this file for RDP and SSH (including non-interactive commands),
  alongside the static image environment. Restart the container after changing
  proxy settings. Playwright scripts can read these variables to configure
  their launch proxy; Playwright does not automatically use them.
- Firefox comes from Mozilla's APT repository and Chrome from Google's, both
  with fingerprint-checked signing keys. Ubuntu's own `firefox` package is a
  snap stub that cannot run in a container, so an APT pin keeps Mozilla's
  build. Both update with the image rather than in place.
- To browse through a SOCKS5 proxy, set `ALL_PROXY=socks5://host:port` (or
  `socks5h://`; the port defaults to 1080). Both browsers then send all
  traffic, including DNS lookups, through it, and `no_proxy` still applies.
  When `ALL_PROXY` is set, the browsers use it instead of `HTTP_PROXY` and
  `HTTPS_PROXY`, whereas curl prefers the protocol-specific variables. Credentials in a SOCKS URL are ignored: neither
  browser can authenticate to a SOCKS5 proxy.
- Firefox reads an image-wide autoconfig that maps the proxy variables to its
  manual proxy settings, enables WebGL on the software renderer
  (`webgl.forbid-software=false`, `webgl.force-enabled=true`), and sets
  performance-oriented defaults that a user can still change. Enterprise
  policies in `/etc/firefox/policies` skip first-run, terms-of-use and
  onboarding pages, disable updates, and force-install an image-baked uBlock
  Origin. Telemetry uploads, studies and related recommendations are locked
  off, and `MOZ_CRASHREPORTER_DISABLE=1` disables crash reporting for normal
  container and SSH launches. These settings do not block visits to Mozilla
  sites or other Mozilla services such as extension updates, remote settings
  and Firefox Sync; use network controls if those connections must also be
  blocked.
- Chrome reads the HTTP proxy variables natively but treats any `ALL_PROXY` as
  an HTTP proxy, so for a SOCKS5 `ALL_PROXY` the wrapper hands Chrome
  `SOCKS_SERVER` instead and clears the other proxy variables in Chrome's
  environment only. Managed policies in
  `/etc/opt/chrome/policies/managed` turn off sign-in, sync, promotional and
  default-browser prompts, metrics reporting and the command-line flag
  warning, and the `google-chrome` wrapper skips the first-run page. Chrome's
  internal sandbox requires user namespaces; where the container forbids them,
  the wrapper adds `--no-sandbox` and the container boundary remains the
  isolation layer. It also passes `--ignore-gpu-blocklist`, without which
  Chrome refuses WebGL on the software renderer.
- WebGL in both Firefox and Chrome renders on Mesa's `llvmpipe` on the CPU.
  It is slow, but sites that require WebGL work.

## Version policy

The Playwright version is pinned in both the `FROM` tag and the npm package installed alongside it. Renovate updates them together; after a manual update, re-test both access paths.

Firefox and Chrome are not pinned: each image build installs the vendors' current stable release.

## Design

Background on the desktop side is in [docs/xrdp-variant.md](docs/xrdp-variant.md).

Run the entrypoint regression tests from the repository root with
`python3 sandbox-browser/scripts/test_runtime.py -v`. They cover disconnect grace,
concurrent SSH sessions and proxy environment serialization for both images,
the xrdp keymap correction, and the browser autoconfig proxy mapping when
`node` is available.
