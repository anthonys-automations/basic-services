# basic-services

Service images (`exim`, `postfix`, `tinyproxy`, `sandbox-browser`) published to
DockerHub under the `anthonysautomations` namespace.

The source here changes very rarely. Almost every release is a rebuild that picks
up newer Alpine packages, produced without human review. The tag strategy below
exists so a separate Kubernetes repository can track these rebuilds safely with
its own Renovate.

> **Note:** the `latest` tag is published again, now as a multi-architecture
> manifest, after a period in which only architecture-suffixed tags were
> produced. It remains a convenience alias only; deploy an immutable
> `<YYYY>.<MM>.<DD>.<N>` tag instead (see [Consuming these images from
> Kubernetes](#consuming-these-images-from-kubernetes)).

## Tag contract

```text
<YYYY>.<MM>.<DD>.<N>      e.g. 2026.07.30.1
```

| Tag | Mutability | Purpose |
| --- | --- | --- |
| `2026.07.30.1` | immutable | multi-architecture release (amd64 + arm64). Pin this in Kubernetes. |
| `latest` | moving | convenience alias, not for deployment |
| `<version>-<arch>` | immutable | out-of-band single-architecture build only (see below) |

Why this shape:

- The **date** moves whenever a rebuild happens, which is what actually changes in
  this repository. A package version alone would not: `tinyproxy` can stay at
  `1.11.2-r3` while `openssl` or `musl` underneath it receives a security fix.
- The **daily sequence** allows more than one build per day.
- **One tag serves every architecture.** The release tag is a manifest list, so a
  node pulls the image matching its own platform and consumers need no
  architecture-specific configuration.
- The exact base image is kept in a **label**, and the full package inventory
  in an **SBOM attestation**, rather than in the tag, so the tag stays short and
  reliably sortable while remaining fully inspectable.

A release tag is only created once **every** architecture has built and pushed
successfully, and the assembled manifest is verified to cover them all before
`latest` is moved. If a build runner is unavailable, no tag appears at all: a
consumer's Renovate then sees no update, rather than an update that would fail
to pull on half the cluster.

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
io.anthonysautomations.base.image
```

The exact set of installed packages is **not** captured as a label — an
independent `apk search` run before the build could drift from what the build
actually resolves, since Alpine's package index is mutable. Instead every build
enables a BuildKit SBOM attestation, generated from the image that is actually
pushed:

```bash
docker buildx imagetools inspect --format '{{ json .SBOM }}' \
    anthonysautomations/tinyproxy:2026.07.30.1
```

Inspect the labels with:

```bash
docker buildx imagetools inspect anthonysautomations/tinyproxy:2026.07.30.1
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

## Builds

`.github/workflows/build-image.yml` is a reusable workflow; the per-service
workflows (`build-exim.yml`, `build-postfix.yml`, `build-tinyproxy.yml`,
`build-sandbox-browser.yml`) supply the inputs and triggers, and `ci.yml` invokes
them on relevant path changes. Each also runs weekly and on manual dispatch.

It runs in three stages:

1. **prepare** — allocates one version and one set of metadata for the whole
   release, so every architecture carries identical labels.
2. **build** — one job per architecture, each on a native GitHub-hosted runner
   (`ubuntu-latest` for amd64, `ubuntu-24.04-arm` for arm64). These push **by
   digest with no tag at all**, so an incomplete release leaves nothing that
   Renovate or a `docker pull` can find.
3. **publish** — assembles the digests into one manifest list, verifies it covers
   every expected platform, and only then tags `<version>` and moves `latest`.

The publish job depends on all build jobs succeeding, with no `if: always()`.
That dependency is the safety mechanism: a failed arm64 build produces no release
rather than an amd64-only one.

`.github/workflows/validate-build.yml` builds all four images on both
architectures **without publishing**. It is manually dispatchable and is what the
Renovate workflow triggers on dependency branches, so a base-image bump is built
for every architecture before it merges without ever allocating a release
version from an unmerged branch.

## Out-of-band single-architecture builds

`scripts/build-arm64.sh` builds and publishes arm64 by hand. It is an escape
hatch, not the normal route — use it when the pipeline itself is unavailable:

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

It publishes `-arm64`-suffixed tags only, from a version stream counted
separately from the multi-architecture one. That is deliberate: a
single-architecture build must never advance the unsuffixed tag, or an amd64
node would be offered an image it cannot run.

The script refuses to publish if the service directory has uncommitted or
untracked changes, since the recorded commit would then not match what was
actually built. Override with `ALLOW_DIRTY=1` only when that mismatch is
acceptable (e.g. local experimentation, never for an audited release).

## Dependency updates (Renovate)

`.github/workflows/renovate.yml` runs a self-hosted Renovate weekly (Friday
03:00 UTC) and on manual dispatch, keeping pinned base images, the Playwright npm
package paired with sandbox-browser, and GitHub Actions versions current.

It authenticates with the built-in `GITHUB_TOKEN`; no secret is needed. Three
consequences follow from that:

- Pushes and PRs made with `GITHUB_TOKEN` never start a workflow run, so a
  `renovate/*` branch would carry no check at all and automerge would wait
  forever. An explicitly dispatched run *is* allowed, so the workflow triggers
  `validate-build.yml` (build-only, no push to DockerHub) on each Renovate
  branch; Renovate merges the PR on a later run once that check is green.
- `GITHUB_TOKEN` has no `workflow` scope and cannot write files under
  `.github/workflows`. GitHub Actions updates are therefore listed on the
  dependency dashboard rather than raised as branches, and have to be applied by
  hand.
- `GITHUB_TOKEN` cannot read Dependabot alerts, so `vulnerabilityAlerts` is
  disabled in `renovate.json`; leaving it on only logged a warning every run and
  never produced an extra PR. Alerts do not cover the pinned Alpine base images
  anyway.

All Dockerfile updates are grouped into a single `renovate/*` branch (including
major bumps, via `separateMajorMinor: false`), so a run produces one PR, one
`validate-build.yml` dispatch and one merge. `prHourlyLimit` is switched off for
the same reason: its default of 2 counts every PR opened in the current clock
hour, including closed ones, and once hit Renovate creates the branch but
silently skips the PR.

The workflow validates `renovate.json` with `renovate-config-validator` before
the run, and afterwards checks Renovate's structured log for errors and for a
`done` repository result. Both exist because Renovate exits 0 even when it
refused to do any work — an invalid config key once produced a green job that
changed nothing.

The job summary lists every PR the run created, updated or automerged, with
links, so unattended dependency changes can be audited from the run page.

## Consuming these images from Kubernetes

Pin an immutable release tag and let Renovate advance it:

```yaml
# renovate: datasource=docker depName=anthonysautomations/tinyproxy versioning=regex:^(?<major>\d{4})\.(?<minor>\d{2})\.(?<patch>\d{2})\.(?<build>\d+)$
image: anthonysautomations/tinyproxy:2026.07.30.1@sha256:...
```

One tag covers every architecture, so the same manifest can be used on amd64 and
arm64 nodes alike. Adding the digest is worth doing: Renovate updates tag and
digest together, and the digest of a manifest list still resolves per-node
correctly, so immutability costs nothing in portability.

The regex deliberately does not match `-<arch>` suffixes, so an out-of-band
single-architecture build is never offered as an update.

Do not deploy `latest`: it moves underneath a running cluster and gives Renovate
nothing to raise a pull request against.
