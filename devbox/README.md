# Devbox

A long-running, SSH-only workstation container with the cloud and automation
tooling an engineer or an agent needs, built on the same unprivileged design as
[sandbox-browser](../sandbox-browser/README.md).

Where sandbox-browser is a disposable pool member — claimed by one client, then
recycled — the devbox is meant to stay up. It serves any number of concurrent
SSH sessions, never exits on its own, and keeps its home directory on a
persistent volume so logins, configuration and work in progress survive
restarts and image upgrades.

## Contents

| Tool | Command | Notes |
| --- | --- | --- |
| Chromium, Firefox | `chromium`, `firefox`, Playwright | Headless only: no desktop. Playwright resolves from `NODE_PATH`. |
| AWS CLI v2 | `aws` | Official bundle. |
| Azure CLI | `az` | Own virtualenv; extensions install into `~/.azure`. |
| Oracle OCI CLI | `oci` | Own virtualenv. |
| Ansible | `ansible`, `ansible-playbook`, … | The full community package, own virtualenv. |
| Terraform | `terraform` | Checked against HashiCorp's `SHA256SUMS`. |
| Claude Code | `claude` | Auto-update disabled; upgrades come with the image. |

Plus Node.js, Python 3 (with `venv`), `git`, `tmux`, `jq`, `make`, `rsync`,
`curl`, `wget`, `dig`, `vim.tiny`, `nano`, `zip`/`unzip`, and bash completion.

Every tool is pinned in the [Dockerfile](Dockerfile) and kept current by
Renovate.

## Security model

- A single account, `user` (UID/GID 10000), runs everything including `sshd`.
  No capability is needed, so the container runs with `cap_drop: ALL`,
  `no-new-privileges` and, in Kubernetes, a read-only root filesystem under the
  restricted Pod Security Standard. There is no `sudo` and no way back to root.
- Public-key authentication only. Passwords and keyboard-interactive are
  disabled, root login is refused, and `AllowUsers user` admits nobody else.
- Only the operator-supplied key list is honoured. `~/.ssh/authorized_keys`
  inside the box is ignored, so a key cannot be smuggled in through the
  persistent home and outlive its removal from the Secret.
- Forwarding is narrowed to what a workstation needs: local port forwarding
  (`ssh -L`) and agent forwarding (`ssh -A`, client opt-in). Remote forwarding,
  gateway ports, tunnel devices, Unix socket forwarding and X11 are off.
- `sshd` listens on 2222, because binding 22 would need a capability.

Every session shares the one account, so everyone with a key has the same
access, including to each other's cloud credentials under the home directory.
Give a separate devbox to each person or trust boundary.

## Prerequisites

- Docker Engine with Compose v2.
- A key pair: `ssh-keygen -t ed25519 -f ~/.ssh/devbox`.

## Run

```bash
export AUTHORIZED_KEYS_FILE="$HOME/.ssh/devbox.pub"
docker compose up --build -d
ssh -p 2222 -i ~/.ssh/devbox user@localhost
```

The container refuses to start without at least one public key. The file may
list several keys; changes take effect on the next container restart.

The home directory lives in the `home` named volume and survives
`docker compose down` and `up --force-recreate`. Only `docker compose down -v`
removes it.

### Host identity

On first start the entrypoint generates Ed25519 and RSA host keys into
`~/.local/state/devbox/ssh-host-keys` in the persistent home, and logs their
fingerprints so the first connection can be checked. They are reused on every
restart, so clients keep trusting the host.

To manage the identity yourself, mount a directory containing
`ssh_host_ed25519_key` (and optionally `ssh_host_rsa_key`) at
`/etc/devbox/host-keys`; it takes precedence over the generated keys.

### Working with the tools

- **Long-running work:** start it in `tmux`. A session left behind by a dropped
  connection keeps running and can be reattached; `tini` as PID 1 reaps
  whatever such sessions orphan.
- **Cloud logins:** there is no desktop browser to hand an OAuth flow to, so
  use device-code flows: `aws sso login --use-device-code`,
  `az login --use-device-code`, or API-key auth via `oci setup config`.
  Claude Code prints a URL to open on your own machine and asks for the code.
- **Reaching a dev server or a callback:** `ssh -L 8080:localhost:8080 …`.
- **Extra tools:** `npm install -g` goes to `~/.local` (on `PATH` from the next
  login). Ubuntu's Python refuses user-wide `pip install`; create a venv under
  the home directory instead.
- **Browsers:** `chromium --headless …`, `firefox --headless …`, or Playwright
  from Node. Chromium falls back to `--no-sandbox` where user namespaces are
  unavailable, leaving the container as the isolation boundary.

## Kubernetes

[k8s/devbox.yaml](k8s/devbox.yaml) runs one devbox as a single-replica
StatefulSet with a ClusterIP Service:

```bash
kubectl create secret generic devbox-ssh --from-file=authorized_keys=$HOME/.ssh/devbox.pub
kubectl apply -f k8s/devbox.yaml
kubectl port-forward svc/devbox 2222:2222
```

- `/home/user` is a 20 GiB `ReadWriteOnce` claim from the volume template.
- With `readOnlyRootFilesystem: true`, `/tmp`, `/run/devbox` and `/dev/shm` are
  `emptyDir` volumes. Everything else that is written goes to the home claim.
- The `authorized_keys` Secret is mounted with `subPath`, which Kubernetes does
  not refresh: restart the Pod after changing keys.
- `healthcheck.sh` serves as startup, readiness and liveness probe; it checks
  that `sshd` is running.

## Design notes

These follow from running `sshd` unprivileged and are shared with
sandbox-browser:

- The PAM stack is replaced. A non-root `sshd` cannot read `/etc/shadow`, and
  the setuid helper `pam_unix` falls back to is neutered by no-new-privs, so the
  distribution stack would deny every login. Authentication itself is decided
  by `sshd`'s public-key check; PAM only runs `pam_env`, which gives SSH
  sessions the variables in `/etc/environment`.
- The mounted key list is copied into `/run/devbox` at startup, because `sshd`
  rejects a key file owned by neither the account nor root, which is what a bind
  mount or a Secret usually produces. Host keys are copied for the same reason:
  a Secret mounted with `fsGroup` is group-readable, which `sshd` refuses for a
  private key.
- `StrictModes` is off because `/run/devbox` is a volume when the root
  filesystem is read-only, and no volume satisfies its directory walk.

## Version policy

The Playwright version is pinned in both the `FROM` tag and the npm package
installed alongside it, and Renovate updates them together, as for
sandbox-browser. The other tools carry `# renovate:` comments on their `ARG`
lines. Version checks at the end of each install step fail the build if a
download or install is broken.
