# Pinned to an explicit Alpine release instead of `latest` so builds are
# reproducible and base image bumps are proposed/reviewed by Renovate.
FROM alpine:3.22.1

RUN apk update && apk add tinyproxy

# tinyproxy will create its pid file (needs root for that) then drop privileges, so no runas user needed for container.

CMD ["/usr/bin/tinyproxy", "-d"]
