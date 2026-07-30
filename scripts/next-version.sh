#!/usr/bin/env bash
#
# Computes the next immutable calendar version for an image release.
#
# Added as part of the Docker tag strategy work: downstream Kubernetes Renovate
# needs a monotonically increasing, architecture-scoped version to track. The
# contract is:
#
#     <YYYY>.<MM>.<DD>.<N>-<arch>      e.g. 2026.07.30.1-amd64
#
# The date changes whenever a rebuild happens (which is what actually moves for
# this repo: Alpine package contents, not source code), and <N> disambiguates
# multiple builds on the same day. The architecture suffix is consumed by
# Renovate as the `compatibility` group so an amd64 deployment is never offered
# an arm64 image (and vice versa).
#
# Failure handling is deliberately fail-closed: only an empty/first-ever
# repository (HTTP 404) is treated as "no tags yet". Any other non-200
# response, malformed JSON, or network failure aborts the script rather than
# silently allocating from an empty list - a wrongly "empty" listing could
# otherwise produce a version older than one that already exists (e.g. `.1`
# looks free because the listing failed to show that `.2` already exists),
# which Renovate would then never see as an update.
#
# Usage:
#   next-version.sh <dockerhub-repo> <arch>
#
# Example:
#   next-version.sh anthonysautomations/tinyproxy amd64
#
# Prints the new version (without the arch suffix) to stdout. All diagnostics go
# to stderr so the caller can capture stdout directly.

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $(basename "$0") <dockerhub-repo> <arch>" >&2
    exit 2
fi

repo=$1
arch=$2

for dep in curl jq; do
    if ! command -v "$dep" >/dev/null 2>&1; then
        echo "error: required dependency '${dep}' is not installed" >&2
        exit 1
    fi
done

body_file=$(mktemp)
trap 'rm -f "${body_file}"' EXIT

date_part=$(date -u +'%Y.%m.%d')

# Docker Hub's tag listing supports a substring `name` filter, so only the
# handful of tags already published for today are fetched rather than the whole
# (ever growing) tag history.
list_url="https://hub.docker.com/v2/repositories/${repo}/tags?page_size=100&name=${date_part}."

list_status=$(curl -sS --retry 3 --retry-delay 2 -o "${body_file}" -w '%{http_code}' "${list_url}") \
    || { echo "error: could not reach Docker Hub to list existing tags for ${repo}" >&2; exit 1; }

case "${list_status}" in
    200)
        if ! jq -e '
            .results
            | type == "array"
                and all(.[]; type == "object" and (.name | type == "string"))
        ' "${body_file}" >/dev/null 2>&1; then
            echo "error: malformed tag-listing response from Docker Hub for ${repo} (HTTP 200 but invalid response body)" >&2
            exit 1
        fi
        ;;
    404)
        # First-ever build: the repository does not exist yet, so there are no
        # tags to list. This is the only failure-shaped response treated as
        # "empty" - everything else below is fatal.
        echo '{"results":[]}' > "${body_file}"
        ;;
    *)
        echo "error: could not list existing tags for ${repo} (HTTP ${list_status})" >&2
        exit 1
        ;;
esac

highest=0
# Escape the dots so the date is matched literally rather than as wildcards.
pattern="^${date_part//./\\.}\\.([0-9]+)-${arch}$"
while IFS= read -r name; do
    [[ -n ${name} ]] || continue
    if [[ ${name} =~ ${pattern} ]]; then
        seq=${BASH_REMATCH[1]}
        if (( seq > highest )); then
            highest=${seq}
        fi
    fi
done < <(jq -r '.results[]?.name // empty' "${body_file}")

version="${date_part}.$(( highest + 1 ))"
tag="${version}-${arch}"

# Release tags are immutable. Verify the computed tag really is unused before
# handing it back, so a failed/partial listing above can never cause an existing
# release to be silently overwritten.
tag_url="https://hub.docker.com/v2/repositories/${repo}/tags/${tag}"
tag_status=$(curl -sS -o /dev/null -w '%{http_code}' --retry 3 --retry-delay 2 "${tag_url}") \
    || { echo "error: could not verify availability of ${repo}:${tag}" >&2; exit 1; }

case "${tag_status}" in
    404)
        : # Expected: the tag is free.
        ;;
    200)
        echo "error: tag ${repo}:${tag} already exists; refusing to overwrite an immutable release" >&2
        exit 1
        ;;
    *)
        echo "error: could not verify availability of ${repo}:${tag} (HTTP ${tag_status})" >&2
        exit 1
        ;;
esac

echo "resolved next version for ${repo} (${arch}): ${tag}" >&2
echo "${version}"
