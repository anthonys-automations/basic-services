# basic-services

Minimal Alpine-based service images (`exim`, `postfix`, `tinyproxy`) published to
DockerHub under the `anthonysautomations` namespace.

The source here changes very rarely. Almost every release is a rebuild that picks
up newer Alpine packages, produced without human review. The tag strategy below
exists so a separate Kubernetes repository can track these rebuilds safely with
its own Renovate.

> **Breaking change:** this repository no longer publishes a plain `latest` tag.
> It previously did; that tag is now frozen at its last pre-migration value and
> will not receive further updates. If anything still deploys
> `anthonysautomations/{exim,postfix,tinyproxy}:latest`, repoint it to an
> immutable, architecture-scoped tag (see [Consuming these images from
> Kubernetes](#consuming-these-images-from-kubernetes)) before relying on new
> releases.

## Tag contract

```text
<YYYY>.<MM>.<DD>.<N>-<arch>      e.g. 2026.07.30.1-amd64
```

| Tag | Mutability | Purpose |
| --- | --- | --- |
| `2026.07.30.1-amd64` | immutable | amd64 release. Pin this in Kubernetes. |
| `2026.07.30.1-arm64` | immutable | arm64 release. Pin this in Kubernetes. |
| `latest-amd64` | moving | convenience alias, not for deployment |
| `latest-arm64` | moving | convenience alias, not for deployment |
| `latest` / unsuffixed versions | reserved | promoted multi-architecture manifest |

Why this shape:

- The **date** moves whenever a rebuild happens, which is what actually changes in
  this repository. A package version alone would not: `tinyproxy` can stay at
  `1.11.2-r3` while `openssl` or `musl` underneath it receives a security fix.
- The **daily sequence** allows more than one build per day.
- The **architecture suffix** is read by Renovate as its `compatibility` group, so
  an amd64 deployment is never offered an arm64 image, and vice versa.
- The exact Alpine version is kept in a **label**, and the full package inventory
  in an **SBOM attestation**, rather than in the tag, so the tag stays short and
  reliably sortable while remaining fully inspectable.

The full rationale, algorithm, and a re-implementation guide for reusing this
approach on another product are in [docs/image-versioning.md](docs/image-versioning.md).

Release tags are never overwritten. `scripts/next-version.sh` verifies the tag is
unused before it is handed to a build.

### Labels and package inventory

Every published image carries:

```text
org.opencontainers.image.title
org.opencontainers.image.version
org.opencontainers.image.revision
org.opencontainers.image.source
org.opencontainers.image.created
io.anthonysautomations.alpine.version
```

The exact set of installed packages is **not** captured as a label — an
independent `apk search` run before the build could drift from what the build
actually resolves, since Alpine's package index is mutable. Instead every build
enables a BuildKit SBOM attestation, generated from the image that is actually
pushed:

```bash
docker buildx imagetools inspect --format '{{ json .SBOM }}' \
    anthonysautomations/tinyproxy:2026.07.30.1-amd64
```

Inspect the labels with:

```bash
docker buildx imagetools inspect anthonysautomations/tinyproxy:2026.07.30.1-amd64
```

### Tracing a running container to a commit

The source commit is baked into the image as a `GIT_COMMIT` environment variable
in addition to the `org.opencontainers.image.revision` label, so an already
running container can be traced back to source without access to the registry:

```bash
docker exec <container> printenv GIT_COMMIT
kubectl exec <pod> -- printenv GIT_COMMIT
```

Images built outside the pipeline without the build arg report `unknown`.

Treat both as **best-effort, not authoritative**: an environment variable can be
overridden by a pod/container spec, and a dirty working tree at manual-build time
would also make the recorded commit misleading (`build-arm64.sh` refuses to
publish in that case unless `ALLOW_DIRTY=1` is set — see below). For a binding
audit record, pin and reason about the immutable **image digest**, not the env
var or label alone.

## amd64 builds (automated)

`.github/workflows/build-image.yml` is a reusable workflow; the per-service
workflows (`build-exim.yml`, `build-postfix.yml`, `build-tinyproxy.yml`) supply the
inputs and triggers, and `ci.yml` invokes them on relevant path changes. Each also
runs weekly and on manual dispatch.

## arm64 builds (manual)

arm64 images are built by hand on an irregular schedule using the same contract:

```bash
export DOCKERHUB_USERNAME=...
export DOCKERHUB_TOKEN=...          # access token, never committed
scripts/build-arm64.sh tinyproxy
```

Requires `docker`, `curl`, `jq`, and `git`. Run only one instance at a time per
service: the version is checked to be unused when it is allocated, not when it is
pushed, so two overlapping runs could settle on the same version. Requires a
buildx builder capable of `linux/arm64` — either a native arm64 host or qemu:

```bash
docker run --privileged --rm tonistiigi/binfmt --install arm64
```

arm64 versions are allocated independently of amd64. An arm64 build made weeks
after an amd64 build resolves different package contents, so it gets its own
version rather than borrowing the amd64 one.

The script refuses to publish if the service directory has uncommitted or
untracked changes, since the recorded commit would then not match what was
actually built. Override with `ALLOW_DIRTY=1` only when that mismatch is
acceptable (e.g. local experimentation, never for an audited release).

## Dependency updates (Renovate)

`.github/workflows/renovate.yml` runs a self-hosted Renovate weekly (Friday
03:00 UTC) and on manual dispatch, keeping the pinned Alpine base images and
GitHub Actions versions current.

It authenticates with the built-in `GITHUB_TOKEN`; no secret is needed. Two
limitations follow from that:

- PRs opened by `GITHUB_TOKEN` do not trigger other workflows, so the CI checks
  automerge would wait on never start. Merges therefore happen without a fresh
  CI run (or need a manual push to the branch to kick one off).
- `GITHUB_TOKEN` cannot write files under `.github/workflows`, so Actions
  version bumps have to be applied by hand.

The workflow validates `renovate.json` with `renovate-config-validator` before
the run, and afterwards checks Renovate's structured log for errors and for a
`done` repository result. Both exist because Renovate exits 0 even when it
refused to do any work — an invalid config key once produced a green job that
changed nothing.

The job summary lists every PR the run created, updated or automerged, with
links, so unattended dependency changes can be audited from the run page.

## Consuming these images from Kubernetes

Pin an immutable, architecture-matched tag and let Renovate advance it:

```yaml
# renovate: datasource=docker depName=anthonysautomations/tinyproxy versioning=regex:^(?<major>\d{4})\.(?<minor>\d{2})\.(?<patch>\d{2})\.(?<build>\d+)(?:-(?<compatibility>amd64|arm64))?$
image: anthonysautomations/tinyproxy:2026.07.30.1-amd64
```

Use the `-arm64` tag for arm64 workloads. Because the suffix is matched as
`compatibility`, Renovate only proposes updates built for the same architecture,
so each workload follows the newest image its nodes can actually run.

Do not deploy `latest-amd64` / `latest-arm64`: they move underneath a running
cluster and give Renovate nothing to raise a pull request against.
