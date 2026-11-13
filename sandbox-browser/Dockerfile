# syntax=docker/dockerfile:1.29

# xrdp-sesman drops privileges with setgid, initgroups and setuid before it
# starts a desktop. All three are no-ops when the target account is the one
# already running, but setgroups(2) demands CAP_SETGID regardless, and sesman
# treats the refusal as fatal for the whole environment setup: HOME is left
# unset and Xvnc is launched with an empty -rfbauth, so the session dies on
# connect. Returning success for the one call the container cannot make keeps
# the group list sesman was going to set anyway.
FROM mcr.microsoft.com/playwright:v1.65.0-noble AS shim
RUN apt-get update \
  && apt-get install -y --no-install-recommends gcc libc6-dev \
  && rm -rf /var/lib/apt/lists/*
COPY <<'EOF' /tmp/noinitgroups.c
int initgroups(const char *user, unsigned int group) { return 0; }
EOF
RUN gcc -O2 -shared -fPIC -o /tmp/noinitgroups.so /tmp/noinitgroups.c

# Playwright's maintained image supplies compatible Chromium, Firefox, Node.js,
# and the OS libraries required to automate both browsers.
FROM mcr.microsoft.com/playwright:v1.65.0-noble

ENV DEBIAN_FRONTEND=noninteractive \
  PLAYWRIGHT_BROWSERS_PATH=/ms-playwright \
  NODE_PATH=/opt/playwright/node_modules \
  MOZ_CRASHREPORTER_DISABLE=1

# Xvnc is used as the xrdp backend because Xorg needs host privileges a container lacks.
# libpam-pwdfile authenticates RDP against a runtime file, since a non-root
# sesman can neither read /etc/shadow nor have a password written into it.
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    dbus-x11 \
    git \
    iproute2 \
    jq \
    libpam-pwdfile \
    openssh-server \
    openssl \
    python3 \
    tigervnc-standalone-server \
    xauth \
    xfce4 \
    xfce4-terminal \
    xrdp \
  && rm -rf /var/lib/apt/lists/* \
  # 1000 and 1001 are already taken by the base image's ubuntu and pwuser accounts.
  && groupadd --gid 10000 user \
  && useradd --uid 10000 --gid 10000 --create-home --shell /bin/bash user \
  # Everything the daemons write at runtime has to be user-owned up front:
  # nothing in the container can create or chown a directory any more.
  && mkdir -p /run/sshd /run/xrdp/sockdir /run/sandbox /home/user/.ssh \
  && chown -R user:user /home/user/.ssh /run/xrdp /run/sandbox \
  && chmod 700 /home/user/.ssh /run/sandbox \
  # X and ICE refuse to create these themselves for a non-root server, which
  # costs xfce4-session its session management.
  && mkdir -p /tmp/.X11-unix /tmp/.ICE-unix \
  && chmod 1777 /tmp/.X11-unix /tmp/.ICE-unix \
  && dbus-uuidgen > /etc/machine-id \
  # The package's install-time host keys are never used; the entrypoint makes its own.
  && rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub \
  && PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install --no-audit --no-fund --prefix /opt/playwright playwright@1.65.0 \
  # Playwright resolves browsers by revision, so a pin that disagrees with the base image builds cleanly and only fails at runtime.
  && node -e 'const p=require("playwright"),f=require("fs");for(const b of [p.chromium,p.firefox]){const e=b.executablePath();if(!f.existsSync(e))throw new Error("npm playwright does not match the base image browsers: "+e)}' \
  # SSH sessions do not inherit image ENV, so PAM supplies these to agents too.
  # BROWSER covers the tools that consult it; NO_AT_BRIDGE stops every GTK app
  # warning about the accessibility bus this image has no reason to run.
  && printf 'PLAYWRIGHT_BROWSERS_PATH=/ms-playwright\nNODE_PATH=/opt/playwright/node_modules\nBROWSER=/usr/local/bin/firefox\nNO_AT_BRIDGE=1\nMOZ_CRASHREPORTER_DISABLE=1\n' >> /etc/environment

# Pin launchers to the image's single installed browser revisions.
# Asking playwright for the paths avoids hardcoding a per-version directory layout,
# which broke when the base image moved the Chromium binary out of chrome-linux/.
RUN mkdir -p /opt/sandbox-browser \
  && ln -s "$(node -e 'process.stdout.write(require("playwright").firefox.executablePath())')" /opt/sandbox-browser/firefox \
  && ln -s "$(node -e 'process.stdout.write(require("playwright").chromium.executablePath())')" /opt/sandbox-browser/chromium

# Install uBlock into the image so a fresh desktop profile does not download it
# through the runtime proxy on every pod start.
RUN mkdir -p /etc/sandbox-browser \
  && curl -fsSL --retry 3 -o /opt/sandbox-browser/ublock-origin.xpi \
    https://addons.mozilla.org/firefox/downloads/latest/ublock-origin/latest.xpi \
  && python3 -m zipfile -t /opt/sandbox-browser/ublock-origin.xpi
COPY <<'EOF' /etc/sandbox-browser/firefox-policies.json
{
  "policies": {
    "DisableTelemetry": true,
    "DisableFirefoxStudies": true,
    "OverrideFirstRunPage": "",
    "DontCheckDefaultBrowser": true,
    "ExtensionSettings": {
      "uBlock0@raymondhill.net": {
        "installation_mode": "force_installed",
        "install_url": "file:///opt/sandbox-browser/ublock-origin.xpi"
      }
    }
  }
}
EOF

# Playwright's Firefox applies playwright.cfg on every start, and autoconfig
# writes to the user branch, not the default one: a home page, PDF viewer or
# spell check setting made in the desktop session is silently overwritten the
# next time the browser starts. Automation still wants those prefs, so the file
# is wrapped in the variable only the interactive launcher exports. Firefox
# requires the first line to be a comment and ignores it, hence the split.
COPY config/firefox/privacy.cfg /tmp/firefox-privacy.cfg
RUN cfg="$(dirname "$(readlink -f /opt/sandbox-browser/firefox)")/playwright.cfg" \
  && { \
    head -n 1 "$cfg"; \
    echo 'if (!getenv("SANDBOX_BROWSER_INTERACTIVE")) {'; \
    tail -n +2 "$cfg"; \
    printf '%s\n' \
      '} else {' \
      '  pref("media.autoplay.default", 5);' \
      '  pref("media.autoplay.blocking_policy", 2);' \
      '  pref("media.av1.enabled", false);' \
      '  pref("layout.frame_rate", 30);' \
      '  pref("general.smoothScroll", false);' \
      '  pref("toolkit.cosmeticAnimations.enabled", false);' \
      '  pref("ui.prefersReducedMotion", 1);' \
      '  pref("image.animation_mode", "once");' \
      '  pref("dom.ipc.processCount", 4);' \
      '  pref("dom.ipc.processCount.webIsolated", 1);' \
      '  pref("browser.tabs.unloadOnLowMemory", true);' \
      '  pref("browser.contentblocking.category", "strict");' \
      '  pref("privacy.trackingprotection.enabled", true);' \
      '  pref("privacy.trackingprotection.socialtracking.enabled", true);' \
      '  pref("browser.sessionstore.interval", 60000);' \
      '  pref("browser.newtabpage.activity-stream.feeds.topsites", false);' \
      '  pref("browser.newtabpage.activity-stream.feeds.section.topstories", false);' \
      '  pref("extensions.pocket.enabled", false);' \
      '  pref("network.trr.mode", 5);' \
      '  function sandboxBrowserProxy(value) {' \
      '    if (!value) return null;' \
      '    var match = value.match(/^(?:(https?):\/\/)?(?:[^@\/]+@)?(\[[0-9a-f:.]+\]|[^\s:\/?#@]+)(?::([0-9]+))?\/?$/i);' \
      '    if (!match) return null;' \
      '    return { host: match[2].replace(/^\[|\]$/g, ""), port: match[3] ? parseInt(match[3], 10) : (match[1] && match[1].toLowerCase() == "https" ? 443 : 80) };' \
      '  }' \
      '  var httpProxy = sandboxBrowserProxy(getenv("http_proxy") || getenv("HTTP_PROXY"));' \
      '  var httpsProxy = sandboxBrowserProxy(getenv("https_proxy") || getenv("HTTPS_PROXY")) || httpProxy;' \
      '  if (httpProxy || httpsProxy) {' \
      '    pref("network.proxy.type", 1);' \
      '    if (httpProxy) {' \
      '      pref("network.proxy.http", httpProxy.host);' \
      '      pref("network.proxy.http_port", httpProxy.port);' \
      '    }' \
      '    if (httpsProxy) {' \
      '      pref("network.proxy.ssl", httpsProxy.host);' \
      '      pref("network.proxy.ssl_port", httpsProxy.port);' \
      '    }' \
      '  }' \
      '  pref("browser.policies.alternatePath", "/etc/sandbox-browser/firefox-policies.json");' \
      '}'; \
    cat /tmp/firefox-privacy.cfg; \
  } > "$cfg.guarded" \
  && mv "$cfg.guarded" "$cfg" \
  && rm /tmp/firefox-privacy.cfg \
  && node --check < "$cfg" \
  && grep -q 'SANDBOX_BROWSER_INTERACTIVE' "$cfg" \
  && grep -q 'browser.policies.alternatePath' "$cfg"

COPY --chmod=755 scripts/firefox scripts/chromium /usr/local/bin/

# The default WebBrowser helper is debian-sensible-browser, which finds nothing
# here and fails the panel launcher with "Input/output error"; the stock firefox
# helper resolves to the wrapper above. Compositing is off because Xvnc already
# provides one, and xfwm4 would only spend RDP bandwidth on it.
RUN sed -i 's/^WebBrowser=.*/WebBrowser=firefox/' /etc/xdg/xfce4/helpers.rc \
  && grep -q '^WebBrowser=firefox' /etc/xdg/xfce4/helpers.rc
COPY config/xfce4/xfwm4.xml /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml

# glib only reports the XDG document, picture and video directories when this
# file exists, and Firefox treats the missing answer as an error on every
# start. The entrypoint copies /etc/skel into the fresh home, so it lands there.
COPY <<'EOF' /etc/skel/.config/user-dirs.dirs
XDG_DESKTOP_DIR="$HOME/Desktop"
XDG_DOWNLOAD_DIR="$HOME/Downloads"
XDG_DOCUMENTS_DIR="$HOME/Documents"
XDG_MUSIC_DIR="$HOME/Music"
XDG_PICTURES_DIR="$HOME/Pictures"
XDG_VIDEOS_DIR="$HOME/Videos"
XDG_TEMPLATES_DIR="$HOME/Templates"
XDG_PUBLICSHARE_DIR="$HOME/Public"
EOF

RUN sed -i 's/^autorun=.*/autorun=Xvnc/' /etc/xrdp/xrdp.ini \
  && sed -i 's/^max_bpp=.*/max_bpp=16/' /etc/xrdp/xrdp.ini \
  && grep -q '^max_bpp=16' /etc/xrdp/xrdp.ini \
  && grep -q '^autorun=Xvnc' /etc/xrdp/xrdp.ini \
  # autorun only covers clients that send credentials; everyone else gets the
  # login window, whose session list is these sections in file order. Xorg is
  # first and cannot start here, and the -any sections would proxy the client to
  # any host it names, so Xvnc is left as the only choice.
  && sed -i '/^\[Xorg\]/,/^\[Xvnc\]/{/^\[Xvnc\]/!d}; /^\[vnc-any\]/,$d' /etc/xrdp/xrdp.ini \
  && grep -q '^\[Xvnc\]' /etc/xrdp/xrdp.ini \
  && ! grep -qE '^\[(Xorg|vnc-any|neutrinordp-any)\]' /etc/xrdp/xrdp.ini \
  # /var/log and /etc/ssl are root-owned, so logs and the TLS pair move to the runtime dir.
  && sed -i 's|^certificate=.*|certificate=/run/sandbox/cert.pem|; s|^key_file=.*|key_file=/run/sandbox/key.pem|' /etc/xrdp/xrdp.ini \
  && sed -i 's|^LogFile=.*|LogFile=/run/sandbox/xrdp.log|; s/^EnableSyslog=.*/EnableSyslog=false/' /etc/xrdp/xrdp.ini \
  && sed -i 's|^LogFile=.*|LogFile=/run/sandbox/xrdp-sesman.log|; s/^EnableSyslog=.*/EnableSyslog=false/' /etc/xrdp/sesman.ini \
  # KillDisconnected is forwarded only for xorgxrdp, so the entrypoint also
  # watches for a disconnected RDP client before reaping an Xvnc session marker.
  && sed -i 's/^KillDisconnected=.*/KillDisconnected=true/; s/^DisconnectedTimeLimit=.*/DisconnectedTimeLimit=10/' /etc/xrdp/sesman.ini \
  && grep -q '^KillDisconnected=true' /etc/xrdp/sesman.ini \
  && grep -q '^DisconnectedTimeLimit=10' /etc/xrdp/sesman.ini \
  # The first param is the executable, hence the insert rather than an append.
  && sed -i 's/^param=Xvnc$/param=Xvnc\nparam=-MaxDisconnectionTime=10/' /etc/xrdp/sesman.ini \
  && grep -q '^param=-MaxDisconnectionTime=10' /etc/xrdp/sesman.ini \
  # One desktop at a time; SSH runs alongside it.
  && sed -i 's/^MaxSessions=.*/MaxSessions=1/' /etc/xrdp/sesman.ini \
  && grep -q '^MaxSessions=1' /etc/xrdp/sesman.ini \
  # Drive redirection needs /dev/fuse, which an unprivileged container is not given.
  && sed -i 's/^#EnableFuseMount=false/EnableFuseMount=false/' /etc/xrdp/sesman.ini \
  && grep -q '^EnableFuseMount=false' /etc/xrdp/sesman.ini

COPY --from=shim /tmp/noinitgroups.so /usr/local/lib/noinitgroups.so

# /run/sandbox is named in here, in the PAM stack and in xrdp.ini, so it is fixed.
COPY config/ssh/sshd_config /etc/ssh/sshd_config

COPY --chmod=755 scripts/session-hook.sh /usr/local/bin/session-hook.sh
COPY --chmod=755 scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chmod=755 scripts/readiness-probe.sh /usr/local/bin/readiness-probe.sh
COPY --chmod=755 scripts/liveness-probe.sh /usr/local/bin/liveness-probe.sh
COPY --chmod=755 scripts/startwm.sh /etc/xrdp/startwm.sh

# Both stacks run pam_exec on open and close of every authenticated session.
COPY config/pam.d/sshd /etc/pam.d/sshd
COPY config/pam.d/xrdp-sesman /etc/pam.d/xrdp-sesman

# Keep published containers traceable to the source revision.
ARG GIT_COMMIT=unknown
ENV GIT_COMMIT=${GIT_COMMIT}

USER user
WORKDIR /home/user
# 2222 for agent automation over SSH - unprivileged, because the container has
# no capability to bind 22 - and 3389 for interactive XRDP.
EXPOSE 2222 3389

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
