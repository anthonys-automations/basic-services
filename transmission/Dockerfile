FROM docker.io/anthonysautomations/dante-client:2026.11.23.4

# Build-time provenance: the Git commit this image was built from, requested so a
# running container can be traced back to source for audit. Kept as an env var
# (not just an OCI label) so it is readable from inside the container, and
# declared after the package layers so a new commit does not invalidate the apk
# cache.
ARG GIT_COMMIT=unknown
ENV GIT_COMMIT=${GIT_COMMIT}

RUN apk update && apk add --no-cache transmission-daemon jq

USER 100:101