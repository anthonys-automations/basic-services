#!/bin/sh
# Minimal postfix wrapper:
#   1. Generate a self-signed TLS cert (idempotent) so smtpd can offer STARTTLS.
#   2. postmap the upstream SASL credentials file if one was mounted.
#   3. exec postfix in the foreground.
#
# All postfix configuration lives in /etc/postfix/main.cf, mounted directly
# by the orchestrator (k8s ConfigMap subPath, bind mount, etc.). This script
# does NOT template or rewrite any postfix config files.

set -eu

# --- Self-signed cert (idempotent) ------------------------------------------
# Generated only when $TLS_DIR doesn't exist yet, so any external mount
# (Secret, init container, host volume) that pre-creates the directory
# will be left untouched.
#
# TLS_CN defaults to whatever the container considers its own FQDN; fall
# back to the short hostname if `hostname -f` isn't resolvable.
TLS_DIR="${TLS_DIR:-/etc/postfix/tls}"
TLS_CERT="${TLS_CERT:-$TLS_DIR/tls.crt}"
TLS_KEY="${TLS_KEY:-$TLS_DIR/tls.key}"
TLS_CN="${TLS_CN:-$(hostname -f 2>/dev/null || hostname)}"
TLS_DAYS="${TLS_DAYS:-3650}"

if [ ! -d "$TLS_DIR" ]; then
    mkdir -p "$TLS_DIR"
    openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout "$TLS_KEY" \
        -out "$TLS_CERT" \
        -days "$TLS_DAYS" \
        -subj "/CN=$TLS_CN" >/dev/null 2>&1
    chmod 600 "$TLS_KEY"
fi

# --- Upstream SASL credentials (optional) -----------------------------------
# If a sasl_passwd file is mounted (typically a k8s Secret subPath-mounted
# at /etc/postfix/sasl_passwd), build its hash .db sibling in place. The
# matching `smtp_sasl_*` directives must already be present in main.cf.
SASL_PASSWD_FILE="${SASL_PASSWD_FILE:-/etc/postfix/sasl_passwd}"
if [ -s "$SASL_PASSWD_FILE" ]; then
    /usr/sbin/postmap "hash:$SASL_PASSWD_FILE"
fi

exec /usr/sbin/postfix start-fg
