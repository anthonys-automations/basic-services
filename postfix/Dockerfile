FROM alpine:latest

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

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
