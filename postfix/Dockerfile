# Pinned to an explicit Alpine release instead of `latest` so builds are
# reproducible and base image bumps are proposed/reviewed by Renovate.
FROM alpine:3.22.1

# postfix:                       the MTA itself
# openssl:                       STARTTLS support and ad-hoc cert ops
# cyrus-sasl + plain/login:      SMTP *client* SASL auth to upstream relayhost
RUN apk update && apk add --no-cache \
        postfix \
        openssl \
        cyrus-sasl \
        cyrus-sasl-plain \
        cyrus-sasl-login

# Self-signed TLS cert generation + optional sasl_passwd postmap, then
# exec postfix. All postfix config is expected to be mounted into
# /etc/postfix directly (see entrypoint.sh).
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# postfix will bind to port 25 (needs root for that) then drop privileges, so no runas user needed for container.

# Build-time provenance: the Git commit this image was built from, requested so a
# running container can be traced back to source for audit. Kept as an env var
# (not just an OCI label) so it is readable from inside the container, and
# declared after the package layers so a new commit does not invalidate the apk
# cache.
ARG GIT_COMMIT=unknown
ENV GIT_COMMIT=${GIT_COMMIT}

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
