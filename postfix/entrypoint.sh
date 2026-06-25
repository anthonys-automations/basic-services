#!/bin/sh
# Render postfix config templates at container start, then exec postfix.
#
# How it works
# ------------
# Walks every regular file under $TPL_DIR (default /etc/postfix-tpl) and
# writes a rendered copy to the same relative path under $DEST_DIR
# (default /etc/postfix), substituting ONLY the env vars listed in
# $SUBST_VARS (space-separated, default "RELAYHOST").
#
# Also generates a self-signed RSA cert + key at $TLS_CERT / $TLS_KEY if
# they don't already exist, so smtpd can offer STARTTLS without any
# external secret. Opportunistic TLS does not verify the peer cert, so an
# ephemeral self-signed cert is sufficient.
#
# Why an allow-list
# -----------------
# postfix main.cf uses its own "$variable" syntax (e.g. $mydomain) that we
# must NOT clobber. envsubst's allow-list form ('${A} ${B} ...') expands
# only the named variables and leaves everything else intact, so this is
# safe to run over arbitrary postfix config files.
#
# Adding new templates
# --------------------
# Drop additional files into the mounted template dir (e.g. master.cf,
# transport, sender_canonical). They are rendered automatically; add any
# new placeholder names to $SUBST_VARS in the deployment.

set -eu

TPL_DIR="${TPL_DIR:-/etc/postfix-tpl}"
DEST_DIR="${DEST_DIR:-/etc/postfix}"
SUBST_VARS="${SUBST_VARS:-RELAYHOST TLS_CERT TLS_KEY}"

# Exported so envsubst can pick them up when rendering templates that
# reference ${TLS_CERT} / ${TLS_KEY} (e.g. main.cf).
export TLS_DIR="${TLS_DIR:-/etc/postfix/tls}"
export TLS_CERT="${TLS_CERT:-$TLS_DIR/tls.crt}"
export TLS_KEY="${TLS_KEY:-$TLS_DIR/tls.key}"
TLS_CN="${TLS_CN:-postfix.local}"
TLS_DAYS="${TLS_DAYS:-3650}"

# --- Self-signed cert (idempotent) ------------------------------------------
# Only generated if either file is missing, so an external mount (Secret,
# emptyDir from a sidecar, etc.) can pre-populate them and we'll honour it.
if [ ! -s "$TLS_CERT" ] || [ ! -s "$TLS_KEY" ]; then
    mkdir -p "$(dirname "$TLS_CERT")" "$(dirname "$TLS_KEY")"
    openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout "$TLS_KEY" \
        -out "$TLS_CERT" \
        -days "$TLS_DAYS" \
        -subj "/CN=$TLS_CN" >/dev/null 2>&1
    chmod 600 "$TLS_KEY"
fi

# --- Template rendering -----------------------------------------------------
if [ -d "$TPL_DIR" ]; then
    # Build the envsubst allow-list: '${VAR1} ${VAR2} ...'
    subst_list=""
    for v in $SUBST_VARS; do
        subst_list="${subst_list}\${${v}} "
    done

    find "$TPL_DIR" -type f | while read -r tpl; do
        rel="${tpl#"$TPL_DIR"/}"
        dest="$DEST_DIR/$rel"
        mkdir -p "$(dirname "$dest")"
        envsubst "$subst_list" < "$tpl" > "$dest"
    done
fi

exec /usr/sbin/postfix -c "$DEST_DIR" start-fg
