# Pinned to an explicit Alpine release instead of `latest` so builds are
# reproducible and base image bumps are proposed/reviewed by Renovate.
FROM alpine:3.24.1

RUN apk update && apk add exim

# exim will bind to port 25 (needs root for that) then drop privileges, so no runas user needed for container.

# Build-time provenance: the Git commit this image was built from, requested so a
# running container can be traced back to source for audit. Kept as an env var
# (not just an OCI label) so it is readable from inside the container, and
# declared after the package layers so a new commit does not invalidate the apk
# cache.
ARG GIT_COMMIT=unknown
ENV GIT_COMMIT=${GIT_COMMIT}

CMD ["/usr/sbin/exim", "-bdf", "-q30"]
