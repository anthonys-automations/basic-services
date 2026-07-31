# syntax=docker/dockerfile:1.7

# Playwright's maintained image supplies compatible Chromium, Firefox, Node.js,
# and the OS libraries required to automate both browsers.
FROM mcr.microsoft.com/playwright:v1.55.0-noble

ENV DEBIAN_FRONTEND=noninteractive \
  PLAYWRIGHT_BROWSERS_PATH=/ms-playwright \
  NODE_PATH=/opt/playwright/node_modules \
  SANDBOX_RUNTIME_DIR=/run/sandbox

# Xvnc is used as the xrdp backend because Xorg needs host privileges a container lacks.
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    dbus-x11 \
    git \
    jq \
    openssh-server \
    python3 \
    tigervnc-standalone-server \
    xauth \
    xfce4 \
    xfce4-terminal \
    xrdp \
  && rm -rf /var/lib/apt/lists/* \
  && useradd --create-home --shell /bin/bash user \
  && mkdir -p /run/sshd /var/run/xrdp /home/user/.ssh \
  && chown -R user:user /home/user/.ssh \
  && chmod 700 /home/user/.ssh \
  && dbus-uuidgen > /etc/machine-id \
  && rm -f /etc/ssl/private/ssl-cert-snakeoil.key /etc/ssl/certs/ssl-cert-snakeoil.pem \
  && PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install --no-audit --no-fund --prefix /opt/playwright playwright@1.55.0 \
  # Playwright resolves browsers by revision, so a pin that disagrees with the base image builds cleanly and only fails at runtime.
  && node -e 'const p=require("playwright"),f=require("fs");for(const b of [p.chromium,p.firefox]){const e=b.executablePath();if(!f.existsSync(e))throw new Error("npm playwright does not match the base image browsers: "+e)}' \
  # SSH sessions do not inherit image ENV, so PAM supplies these to agents too.
  && printf 'PLAYWRIGHT_BROWSERS_PATH=/ms-playwright\nNODE_PATH=/opt/playwright/node_modules\n' >> /etc/environment

# Pin launchers to the image's single installed browser revisions.
RUN mkdir -p /opt/sandbox-browser \
  && ln -s "$(find /ms-playwright -path '*/firefox/firefox' -type f -print -quit)" /opt/sandbox-browser/firefox \
  && ln -s "$(find /ms-playwright -path '*/chrome-linux/chrome' -type f -print -quit)" /opt/sandbox-browser/chromium

COPY --chmod=755 scripts/firefox scripts/chromium /usr/local/bin/

RUN sed -i 's/^autorun=.*/autorun=Xvnc/' /etc/xrdp/xrdp.ini \
  && grep -q '^autorun=Xvnc' /etc/xrdp/xrdp.ini \
  # End the desktop on disconnect rather than parking it for reconnection.
  && sed -i 's/^KillDisconnected=.*/KillDisconnected=true/' /etc/xrdp/sesman.ini \
  && grep -q '^KillDisconnected=true' /etc/xrdp/sesman.ini \
  # One tenant per container.
  && sed -i 's/^MaxSessions=.*/MaxSessions=1/' /etc/xrdp/sesman.ini \
  && grep -q '^MaxSessions=1' /etc/xrdp/sesman.ini

COPY --chmod=755 scripts/claim-session.sh /usr/local/bin/claim-session.sh
COPY --chmod=755 scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chmod=755 scripts/readiness-probe.sh /usr/local/bin/readiness-probe.sh
COPY --chmod=755 scripts/liveness-probe.sh /usr/local/bin/liveness-probe.sh
COPY --chmod=755 scripts/startwm.sh /etc/xrdp/startwm.sh

# PAM calls this before each authenticated desktop or SSH command session.
RUN printf '\nsession required pam_exec.so quiet /usr/local/bin/claim-session.sh\n' >> /etc/pam.d/sshd \
  && printf '\nsession required pam_exec.so quiet /usr/local/bin/claim-session.sh\n' >> /etc/pam.d/xrdp-sesman

# Keep published containers traceable to the source revision.
ARG GIT_COMMIT=unknown
ENV GIT_COMMIT=${GIT_COMMIT}

WORKDIR /home/user
# 22 for agent automation over SSH, 3389 for interactive XRDP.
EXPOSE 22 3389

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
