#!/usr/bin/env bash
#
# Manually builds and publishes a service image for linux/arm64.
#
# Added alongside the amd64 GitHub Actions pipeline: arm64 images are produced
# by hand on an irregular schedule, but downstream Kubernetes Renovate still
# needs them to follow the same immutable, sortable, architecture-scoped tag
# contract as the automated amd64 builds.
#
# Tags published:
#   <YYYY>.<MM>.<DD>.<N>-arm64   immutable release, this is what k8s pins
#   latest-arm64                 moving alias, convenience only - never deploy it
#
# The arm64 version is allocated independently of amd64 on purpose: a manual
# arm64 build weeks after an amd64 build resolves different Alpine package
# contents, so pretending they are the same release would be a lie. The
# unsuffixed tags stay reserved for a promoted multi-architecture manifest.
#
# Package inventory is not queried from an independent container before the
# build (that could drift from what actually gets installed, since Alpine's
# package index is mutable). Instead the build enables a BuildKit SBOM
# attestation, which reflects the exact image that gets pushed; inspect it with
# `docker buildx imagetools inspect --format '{{ json .SBOM }}' <repo>:<tag>`.
#
# Usage:
#   scripts/build-arm64.sh <service>
#
# Examples:
#   scripts/build-arm64.sh tinyproxy
#   scripts/build-arm64.sh postfix
#
# Environment:
#   DOCKERHUB_NAMESPACE   DockerHub namespace (default: anthonysautomations)
#   DOCKERHUB_USERNAME    optional; if set together with DOCKERHUB_TOKEN the
#                         script logs in, otherwise an existing `docker login`
#                         session is assumed
#   DOCKERHUB_TOKEN       optional access token, read from the environment and
#                         piped to `docker login` so it never appears in argv
#   ALLOW_DIRTY           set to 1 to publish despite uncommitted changes in the
#                         service directory (the recorded revision will then not
#                         match what was actually built - avoid for real releases)
#
# Requires a buildx builder able to produce linux/arm64 (a native arm64 host, or
# qemu registered via `docker run --privileged --rm tonistiigi/binfmt --install arm64`).
#
# Run only one instance at a time per service. The version is checked to be
# unused when it is allocated, not when it is pushed, so two genuinely
# overlapping runs could still settle on the same version and have one overwrite
# the other. That is accepted here because these builds are manual and
# infrequent; it is not defended against.

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/.." && pwd)

usage() {
    echo "usage: $(basename "$0") <service>" >&2
    local services=()
    local candidate
    for candidate in "${repo_root}"/*/Dockerfile; do
        [[ -f ${candidate} ]] || continue
        candidate=${candidate%/Dockerfile}
        services+=("${candidate##*/}")
    done
    echo "       services: ${services[*]}" >&2
}

if [[ $# -ne 1 ]]; then
    usage
    exit 2
fi

service=$1
namespace=${DOCKERHUB_NAMESPACE:-anthonysautomations}
repo="${namespace}/${service}"
arch=arm64
platform="linux/${arch}"

context_dir="${repo_root}/${service}"
dockerfile="${context_dir}/Dockerfile"

if [[ ! -f ${dockerfile} ]]; then
    echo "error: no Dockerfile found for service '${service}' (${dockerfile})" >&2
    usage
    exit 1
fi

for dep in docker curl jq git; do
    if ! command -v "${dep}" >/dev/null 2>&1; then
        echo "error: required dependency '${dep}' is not installed" >&2
        exit 1
    fi
done

if ! docker buildx version >/dev/null 2>&1; then
    echo "error: 'docker buildx' is not available; it is required for --platform builds" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Source integrity
# ---------------------------------------------------------------------------
# The commit recorded in the image (GIT_COMMIT / image.revision) is only
# meaningful for audit if it actually matches what was built. Check tracked AND
# untracked changes within the build context, since an untracked file would
# still be picked up by COPY.
dirty=$(git -C "${repo_root}" status --porcelain -- "${service}")
if [[ -n ${dirty} ]]; then
    if [[ ${ALLOW_DIRTY:-} == 1 ]]; then
        echo "warning: ${service}/ has uncommitted changes; ALLOW_DIRTY=1 set, proceeding anyway" >&2
        echo "${dirty}" >&2
    else
        echo "error: ${service}/ has uncommitted changes; refusing to publish an image whose" >&2
        echo "       recorded revision would not match its actual content:" >&2
        echo "${dirty}" >&2
        echo "       re-run with ALLOW_DIRTY=1 to override (not recommended for audited releases)" >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Authentication
# ---------------------------------------------------------------------------
if [[ -n ${DOCKERHUB_USERNAME:-} && -n ${DOCKERHUB_TOKEN:-} ]]; then
    echo "==> logging in to DockerHub as ${DOCKERHUB_USERNAME}"
    printf '%s' "${DOCKERHUB_TOKEN}" | docker login --username "${DOCKERHUB_USERNAME}" --password-stdin
else
    echo "==> DOCKERHUB_USERNAME/DOCKERHUB_TOKEN not set, assuming an existing docker login session"
fi

# ---------------------------------------------------------------------------
# Release identity
# ---------------------------------------------------------------------------
version=$("${script_dir}/next-version.sh" "${repo}" "${arch}")
tag="${version}-${arch}"

# ---------------------------------------------------------------------------
# Provenance metadata
# ---------------------------------------------------------------------------
# The Alpine release is pinned in the Dockerfile, so read it from there.
alpine_version=$(sed -nE 's|^FROM alpine:([A-Za-z0-9._-]+).*|\1|p' "${dockerfile}")
alpine_version=${alpine_version%%$'\n'*}
if [[ -z ${alpine_version} ]]; then
    echo "error: could not determine the pinned Alpine version from ${dockerfile}" >&2
    exit 1
fi

revision=$(git -C "${repo_root}" rev-parse HEAD)
created=$(date -u +'%Y-%m-%dT%H:%M:%SZ')

# Derive the source URL from the checkout so the label stays correct if the
# repository is ever moved or forked.
source_url=$(git -C "${repo_root}" remote get-url origin 2>/dev/null || true)
source_url=${source_url%.git}
source_url=${source_url/git@github.com:/https://github.com/}

# ---------------------------------------------------------------------------
# Build and push
# ---------------------------------------------------------------------------
cat <<EOF
==> building ${repo}
    platform         ${platform}
    release tag      ${tag}
    moving alias     latest-${arch}
    alpine           ${alpine_version}
    revision         ${revision}
EOF

docker buildx build \
    --platform "${platform}" \
    --file "${dockerfile}" \
    --tag "${repo}:${tag}" \
    --tag "${repo}:latest-${arch}" \
    --build-arg "GIT_COMMIT=${revision}" \
    --label "org.opencontainers.image.title=${service}" \
    --label "org.opencontainers.image.version=${version}" \
    --label "org.opencontainers.image.revision=${revision}" \
    --label "org.opencontainers.image.source=${source_url}" \
    --label "org.opencontainers.image.created=${created}" \
    --label "io.anthonysautomations.alpine.version=${alpine_version}" \
    --sbom=true \
    --push \
    "${context_dir}"

echo "==> published ${repo}:${tag} and ${repo}:latest-${arch}"
