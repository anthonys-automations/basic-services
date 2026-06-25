FROM alpine:latest

# postfix:   the MTA itself
# openssl:   STARTTLS support (server- or client-side TLS) and ad-hoc cert ops
# gettext:   provides envsubst, used by entrypoint.sh for config templating
RUN apk update && apk add --no-cache postfix openssl gettext

# Render any files under /etc/postfix-tpl to /etc/postfix at startup,
# substituting env vars listed in $SUBST_VARS. See entrypoint.sh.
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# postfix will bind to port 25 (needs root for that) then drop privileges, so no runas user needed for container.

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
