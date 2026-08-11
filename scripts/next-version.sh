#!/usr/bin/env bash
#
# Computes the next immutable calendar version for an image release.
#
# Added as part of the Docker tag strategy work: downstream Kubernetes Renovate
# needs a monotonically increasing version to track. The contract is:
#
#     <YYYY>.<MM>.<DD>.<N>[-<arch>]    e.g. 2026.07.30.1
#
# The date changes whenever a rebuild happens (which is what actually moves for
# this repo: Alpine package contents, not source code), and <N> disambiguates
# multiple builds on the same day.
#
# The architecture suffix is optional and is now only used by out-of-band
# single-architecture builds. The CI pipeline builds every architecture in
# lockstep and publishes one multi-architecture manifest, so it allocates from
# the unsuffixed stream; the two streams are counted separately, which is
# intended - a single-arch escape-hatch release must never advance the version
# that mixed-architecture consumers track.
#
# Failure handling is deliberately fail-closed: only an empty/first-ever
# repository (HTTP 404) is treated as "no tags yet". Any other non-200
# response, malformed JSON, or network failure aborts the script rather than
# silently allocating from an empty list - a wrongly "empty" listing could
# otherwise produce a version older than one that already exists (e.g. `.1`
# looks free because the listing failed to show that `.2` already exists),
# which Renovate would then never see as an update.
#
# Credentials are REQUIRED even though this image is public today. Docker Hub
# answers an unauthenticated request for a *private* repository with the same
# 404 it uses for one that does not exist, so the 404-means-empty branch above
# would silently allocate `.1` on every run and overwrite the immutable release
# each time. Demanding a login keeps that from becoming true the day the
# repository is made private, and makes a 404 really mean "no such repository".
#
# Usage:
#   DOCKERHUB_USERNAME=... DOCKERHUB_TOKEN=... next-version.sh <dockerhub-repo> [arch]
#
# Examples:
#   next-version.sh anthonysautomations/tinyproxy          # multi-arch stream
#   next-version.sh anthonysautomations/tinyproxy arm64     # single-arch stream
#
# Prints the new version (without the arch suffix) to stdout. All diagnostics go
# to stderr so the caller can capture stdout directly.

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "usage: $(basename "$0") <dockerhub-repo> [arch]" >&2
    exit 2
fi

repo=$1
arch=${2:-}
suffix=${arch:+-${arch}}

for dep in curl jq; do
    if ! command -v "$dep" >/dev/null 2>&1; then
        echo "error: required dependency '${dep}' is not installed" >&2
        exit 1
    fi
done

if [[ -z ${DOCKERHUB_USERNAME:-} || -z ${DOCKERHUB_TOKEN:-} ]]; then
    echo "error: DOCKERHUB_USERNAME and DOCKERHUB_TOKEN must be set; an unauthenticated" >&2
    echo "       listing cannot tell a private repository from a missing one, and would" >&2
    echo "       allocate .1 forever and overwrite the existing release" >&2
    exit 1
fi

body_file=$(mktemp)
# Holds the bearer header: passing it as a curl argument would expose the token
# in the process list.
curl_auth=$(mktemp)
chmod 600 "${curl_auth}"
trap 'rm -f "${body_file}" "${curl_auth}"' EXIT

# The secret goes over stdin, never argv.
login_status=$(jq -n --arg u "${DOCKERHUB_USERNAME}" --arg s "${DOCKERHUB_TOKEN}" \
        '{identifier: $u, secret: $s}' \
    | curl -sS --retry 3 --retry-delay 2 -o "${body_file}" -w '%{http_code}' \
        -X POST -H 'Content-Type: application/json' --data @- \
        'https://hub.docker.com/v2/auth/token') \
    || { echo "error: could not reach Docker Hub to authenticate" >&2; exit 1; }

if [[ "${login_status}" != "200" ]]; then
    echo "error: Docker Hub authentication failed (HTTP ${login_status}) for user ${DOCKERHUB_USERNAME}" >&2
    exit 1
fi

jwt=$(jq -r '.access_token // .token // empty' "${body_file}")
if [[ -z "${jwt}" ]]; then
    echo "error: Docker Hub authentication returned no token" >&2
    exit 1
fi
printf 'header = "Authorization: Bearer %s"\n' "${jwt}" > "${curl_auth}"

date_part=$(date -u +'%Y.%m.%d')

# Docker Hub's tag listing supports a substring `name` filter, so only the
# handful of tags already published for today are fetched rather than the whole
# (ever growing) tag history.
list_url="https://hub.docker.com/v2/repositories/${repo}/tags?page_size=100&name=${date_part}."

list_status=$(curl -sS -K "${curl_auth}" --retry 3 --retry-delay 2 -o "${body_file}" -w '%{http_code}' "${list_url}") \
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
        # "empty" - everything else below is fatal - and it is trustworthy only
        # because the request was authenticated.
        echo '{"results":[]}' > "${body_file}"
        ;;
    *)
        echo "error: could not list existing tags for ${repo} (HTTP ${list_status})" >&2
        exit 1
        ;;
esac

highest=0
# Escape the dots so the date is matched literally rather than as wildcards.
pattern="^${date_part//./\\.}\\.([0-9]+)${suffix}$"
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
tag="${version}${suffix}"

# Release tags are immutable. Verify the computed tag really is unused before
# handing it back, so a failed/partial listing above can never cause an existing
# release to be silently overwritten.
tag_url="https://hub.docker.com/v2/repositories/${repo}/tags/${tag}"
tag_status=$(curl -sS -K "${curl_auth}" -o /dev/null -w '%{http_code}' --retry 3 --retry-delay 2 "${tag_url}") \
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

echo "resolved next version for ${repo} (${arch:-multi-arch}): ${tag}" >&2
echo "${version}"
