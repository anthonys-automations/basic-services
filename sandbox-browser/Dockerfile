# syntax=docker/dockerfile:1.28

# xrdp-sesman drops privileges with setgid, initgroups and setuid before it
# starts a desktop. All three are no-ops when the target account is the one
# already running, but setgroups(2) demands CAP_SETGID regardless, and sesman
# treats the refusal as fatal for the whole environment setup: HOME is left
# unset and Xvnc is launched with an empty -rfbauth, so the session dies on
# connect. Returning success for the one call the container cannot make keeps
# the group list sesman was going to set anyway.
FROM mcr.microsoft.com/playwright:v1.64.1-noble AS shim
RUN apt-get update \
  && apt-get install -y --no-install-recommends gcc libc6-dev \
  && rm -rf /var/lib/apt/lists/*
COPY <<'EOF' /tmp/noinitgroups.c
int initgroups(const char *user, unsigned int group) { return 0; }
EOF
RUN gcc -O2 -shared -fPIC -o /tmp/noinitgroups.so /tmp/noinitgroups.c

# Playwright's maintained image supplies a compatible Chromium, Node.js, and the
# OS libraries required to automate it.
FROM mcr.microsoft.com/playwright:v1.64.1-noble

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
  && PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install --no-audit --no-fund --prefix /opt/playwright playwright@1.64.1 \
  # Playwright resolves browsers by revision, so a pin that disagrees with the base image builds cleanly and only fails at runtime.
  && node -e 'const e=require("playwright").chromium.executablePath();if(!require("fs").existsSync(e))throw new Error("npm playwright does not match the base image browsers: "+e)' \
  # Playwright Chromium is the only automation browser. Its Firefox reports
  # navigator.webdriver and no WebGL even when started by hand, which captchas reject.
  && rm -rf /ms-playwright/firefox-* /ms-playwright/webkit-* \
  # SSH sessions do not inherit image ENV, so PAM supplies these to agents too.
  # BROWSER covers the tools that consult it; NO_AT_BRIDGE stops every GTK app
  # warning about the accessibility bus this image has no reason to run.
  && printf 'PLAYWRIGHT_BROWSERS_PATH=/ms-playwright\nNODE_PATH=/opt/playwright/node_modules\nBROWSER=/usr/bin/firefox\nNO_AT_BRIDGE=1\nMOZ_CRASHREPORTER_DISABLE=1\n' >> /etc/environment

# Stock browsers for the desktop, from the vendors' own repositories: Ubuntu's
# firefox package is a snap stub, and the pin keeps its higher epoch from
# winning. Chrome's postinst replaces the bootstrap source with its own
# deb822 file and keyring, so the bootstrap pair is dropped afterwards.
RUN install -d -m 0755 /etc/apt/keyrings \
  && curl -fsSL --retry 3 -o /etc/apt/keyrings/packages.mozilla.org.asc https://packages.mozilla.org/apt/repo-signing-key.gpg \
  && gpg --show-keys --with-colons /etc/apt/keyrings/packages.mozilla.org.asc | grep -qx 'fpr:::::::::35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3:' \
  && curl -fsSL --retry 3 https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /etc/apt/keyrings/google-chrome-bootstrap.gpg \
  && gpg --show-keys --with-colons /etc/apt/keyrings/google-chrome-bootstrap.gpg | grep -qx 'fpr:::::::::EB4C1BFD4F042F6DDDCCEC917721F63BD38B4796:' \
  && echo 'deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main' > /etc/apt/sources.list.d/mozilla.list \
  && printf 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n' > /etc/apt/preferences.d/mozilla \
  && echo 'deb [signed-by=/etc/apt/keyrings/google-chrome-bootstrap.gpg] https://dl.google.com/linux/chrome/deb/ stable main' > /etc/apt/sources.list.d/google-chrome.list \
  && apt-get update \
  && apt-get install -y --no-install-recommends firefox google-chrome-stable \
  && rm -rf /var/lib/apt/lists/* \
  && rm -f /etc/apt/sources.list.d/google-chrome.list /etc/apt/keyrings/google-chrome-bootstrap.gpg \
  && test -x /usr/lib/firefox/firefox \
  && test -x /opt/google/chrome/google-chrome

# Install uBlock into the image so a fresh desktop profile does not download it
# through the runtime proxy on every pod start.
RUN mkdir -p /opt/sandbox-browser \
  && curl -fsSL --retry 3 -o /opt/sandbox-browser/ublock-origin.xpi \
    https://addons.mozilla.org/firefox/downloads/latest/ublock-origin/latest.xpi \
  && python3 -m zipfile -t /opt/sandbox-browser/ublock-origin.xpi
COPY <<'EOF' /etc/firefox/policies/policies.json
{
  "policies": {
    "DisableTelemetry": true,
    "DisableFirefoxStudies": true,
    "DisableAppUpdate": true,
    "DontCheckDefaultBrowser": true,
    "OverrideFirstRunPage": "",
    "OverridePostUpdatePage": "",
    "SkipTermsOfUse": true,
    "UserMessaging": {
      "SkipOnboarding": true,
      "ExtensionRecommendations": false,
      "FeatureRecommendations": false,
      "MoreFromMozilla": false
    },
    "ExtensionSettings": {
      "uBlock0@raymondhill.net": {
        "installation_mode": "force_installed",
        "install_url": "file:///opt/sandbox-browser/ublock-origin.xpi"
      }
    }
  }
}
EOF

# Desktop defaults, the container's proxy variables and the privacy locks.
COPY config/autoconfig.js /usr/lib/firefox/defaults/pref/sandbox-browser.js
COPY config/browser-proxy.js config/firefox/desktop.cfg config/firefox/privacy.cfg /tmp/firefox/
RUN cat /tmp/firefox/browser-proxy.js /tmp/firefox/desktop.cfg /tmp/firefox/privacy.cfg > /usr/lib/firefox/sandbox-browser.cfg \
  && rm -r /tmp/firefox \
  && node --check < /usr/lib/firefox/sandbox-browser.cfg

# Without these Chrome opens on sign-in and promotion pages, and warns about
# --no-sandbox on every start where the wrapper has to pass it.
COPY <<'EOF' /etc/opt/chrome/policies/managed/sandbox-browser.json
{
  "BrowserSignin": 0,
  "SyncDisabled": true,
  "PromotionalTabsEnabled": false,
  "DefaultBrowserSettingEnabled": false,
  "MetricsReportingEnabled": false,
  "PrivacySandboxPromptEnabled": false,
  "BackgroundModeEnabled": false,
  "CommandLineFlagSecurityWarningsEnabled": false
}
EOF
COPY --chmod=755 scripts/google-chrome-stable /usr/local/bin/google-chrome-stable
RUN ln -sfn /usr/local/bin/google-chrome-stable /usr/bin/google-chrome-stable

# The default WebBrowser helper is debian-sensible-browser, which finds nothing
# here and fails the panel launcher with "Input/output error"; the stock firefox
# helper resolves to /usr/bin/firefox. The panel lists one button per window
# rather than grouping them by application. Compositing is off because Xvnc
# already provides one, and xfwm4 would only spend RDP bandwidth on it.
RUN sed -i 's/^WebBrowser=.*/WebBrowser=firefox/' /etc/xdg/xfce4/helpers.rc \
  && grep -q '^WebBrowser=firefox' /etc/xdg/xfce4/helpers.rc \
  && sed -i 's|<property name="grouping" type="uint" value="1"/>|<property name="grouping" type="uint" value="0"/>|' /etc/xdg/xfce4/panel/default.xml \
  && grep -q '<property name="grouping" type="uint" value="0"/>' /etc/xdg/xfce4/panel/default.xml
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

# Shift+Alt, the Windows layout hotkey, otherwise leaves Alt stuck down in the
# session; the script explains why. The layout is the one the client had active
# at connect: Xvnc receives keysyms, so switching cannot happen in the session.
RUN --mount=type=bind,source=scripts/normalize-xrdp-keymaps.py,target=/tmp/normalize-xrdp-keymaps.py \
  python3 /tmp/normalize-xrdp-keymaps.py /etc/xrdp/km-*.ini \
  && grep -qx 'Key64=65513:0' /etc/xrdp/km-00000409.ini \
  && ! grep -q '^Key64=65032:' /etc/xrdp/km-00000409.ini

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
