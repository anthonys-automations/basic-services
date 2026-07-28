# Pinned to an explicit Alpine release instead of `latest` so builds are
# reproducible and base image bumps are proposed/reviewed by Renovate.
FROM alpine:3.22.1

RUN apk update && apk add exim

# exim will bind to port 25 (needs root for that) then drop privileges, so no runas user needed for container.

CMD ["/usr/sbin/exim", "-bdf", "-q30"]
