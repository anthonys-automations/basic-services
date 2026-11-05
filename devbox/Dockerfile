# syntax=docker/dockerfile:1.28

# The Python CLIs are built in their own stage so the compiler needed by the odd
# source-only dependency never reaches the final image. Each tool gets its own
# virtualenv: azure-cli, oci-cli and ansible pin overlapping libraries
# differently and would otherwise fight over them. The stage shares the final
# image's base, so the interpreter each venv links to is the same one.
FROM mcr.microsoft.com/playwright:v1.64.1-noble AS python-tools

# renovate: datasource=pypi depName=azure-cli
ARG AZURE_CLI_VERSION=2.92.0
# renovate: datasource=pypi depName=oci-cli
ARG OCI_CLI_VERSION=3.96.0
# renovate: datasource=pypi depName=ansible
ARG ANSIBLE_VERSION=14.6.0

RUN apt-get update \
  && apt-get install -y --no-install-recommends gcc libffi-dev python3-dev python3-venv \
  && rm -rf /var/lib/apt/lists/*
RUN python3 -m venv /opt/venvs/azure-cli \
  && /opt/venvs/azure-cli/bin/pip install --no-cache-dir "azure-cli==${AZURE_CLI_VERSION}"
RUN python3 -m venv /opt/venvs/oci-cli \
  && /opt/venvs/oci-cli/bin/pip install --no-cache-dir "oci-cli==${OCI_CLI_VERSION}"
RUN python3 -m venv /opt/venvs/ansible \
  && /opt/venvs/ansible/bin/pip install --no-cache-dir "ansible==${ANSIBLE_VERSION}"

# Playwright's maintained image supplies compatible Chromium, Firefox, Node.js,
# and the OS libraries required to automate both browsers.
FROM mcr.microsoft.com/playwright:v1.64.1-noble

# renovate: datasource=github-tags depName=aws/aws-cli
ARG AWS_CLI_VERSION=2.39.4
# renovate: datasource=github-releases depName=hashicorp/terraform extractVersion=^v(?<version>.+)$
ARG TERRAFORM_VERSION=1.17.1
# renovate: datasource=npm depName=@anthropic-ai/claude-code
ARG CLAUDE_CODE_VERSION=2.1.318

# Image ENV reaches docker exec and kubectl exec; SSH sessions get the same
# values from /etc/environment below. DISABLE_AUTOUPDATER because Claude Code is
# installed root-owned and the session cannot replace it - upgrades come from
# rebuilding the image.
ENV DEBIAN_FRONTEND=noninteractive \
  LANG=C.UTF-8 \
  PLAYWRIGHT_BROWSERS_PATH=/ms-playwright \
  NODE_PATH=/opt/playwright/node_modules \
  DISABLE_AUTOUPDATER=1

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    bash \
    bash-completion \
    ca-certificates \
    curl \
    dnsutils \
    git \
    gnupg \
    jq \
    less \
    make \
    mc \
    nano \
    openssh-client \
    openssh-server \
    openssl \
    procps \
    python3 \
    python3-venv \
    rsync \
    tini \
    tmux \
    unzip \
    vim-tiny \
    wget \
    xz-utils \
    zip \
  && rm -rf /var/lib/apt/lists/* \
  # Created before the account so useradd copies it too; Ubuntu's ~/.profile
  # only adds ~/.local/bin to PATH when it already exists at login.
  && mkdir -p /etc/skel/.local/bin \
  # 1000 and 1001 are already taken by the base image's ubuntu and pwuser accounts.
  && groupadd --gid 10000 user \
  && useradd --uid 10000 --gid 10000 --create-home --shell /bin/bash user \
  # Everything sshd writes at runtime has to be user-owned up front: nothing in
  # the container can create or chown a root-owned directory any more.
  && mkdir -p /run/sshd /run/devbox \
  && chown user:user /run/devbox \
  && chmod 700 /run/devbox \
  # The package's install-time host keys are never used; the entrypoint supplies its own.
  && rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub \
  # SSH sessions do not inherit image ENV, so PAM supplies these to them too.
  && printf '%s\n' \
    LANG=C.UTF-8 \
    PLAYWRIGHT_BROWSERS_PATH=/ms-playwright \
    NODE_PATH=/opt/playwright/node_modules \
    DISABLE_AUTOUPDATER=1 \
    >> /etc/environment

# Playwright for headless automation, with its browsers resolved from the base
# image. Playwright resolves browsers by revision, so a pin that disagrees with
# the base image builds cleanly and only fails at runtime - hence the check.
RUN PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install --no-audit --no-fund --prefix /opt/playwright playwright@1.64.1 \
  && node -e 'const p=require("playwright"),f=require("fs");for(const b of [p.chromium,p.firefox]){const e=b.executablePath();if(!f.existsSync(e))throw new Error("npm playwright does not match the base image browsers: "+e)}' \
  && mkdir -p /opt/devbox \
  && ln -s "$(node -e 'process.stdout.write(require("playwright").firefox.executablePath())')" /opt/devbox/firefox \
  && ln -s "$(node -e 'process.stdout.write(require("playwright").chromium.executablePath())')" /opt/devbox/chromium
COPY --chmod=755 scripts/firefox scripts/chromium /usr/local/bin/

# AWS CLI v2 is not published to PyPI; the official bundle carries its own Python.
RUN arch="$(uname -m)" \
  && tmp="$(mktemp -d)" \
  && curl -fsSL -o "$tmp/awscli.zip" "https://awscli.amazonaws.com/awscli-exe-linux-${arch}-${AWS_CLI_VERSION}.zip" \
  && unzip -q "$tmp/awscli.zip" -d "$tmp" \
  && "$tmp/aws/install" --install-dir /opt/aws-cli --bin-dir /usr/local/bin \
  && rm -rf "$tmp" \
  && aws --version

# Checked against HashiCorp's published SHA256SUMS for the same release.
RUN arch="$(dpkg --print-architecture)" \
  && tmp="$(mktemp -d)" \
  && base="https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}" \
  && curl -fsSL -o "$tmp/terraform_${TERRAFORM_VERSION}_linux_${arch}.zip" "$base/terraform_${TERRAFORM_VERSION}_linux_${arch}.zip" \
  && curl -fsSL -o "$tmp/SHA256SUMS" "$base/terraform_${TERRAFORM_VERSION}_SHA256SUMS" \
  && (cd "$tmp" && grep " terraform_${TERRAFORM_VERSION}_linux_${arch}.zip\$" SHA256SUMS | sha256sum -c -) \
  && unzip -q "$tmp/terraform_${TERRAFORM_VERSION}_linux_${arch}.zip" terraform -d /usr/local/bin \
  && rm -rf "$tmp" \
  && terraform version

# The npm package installs the matching native binary for the platform.
RUN npm install -g --no-audit --no-fund "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
  && npm cache clean --force \
  && claude --version

COPY --from=python-tools /opt/venvs /opt/venvs
RUN ln -s /opt/venvs/azure-cli/bin/az /usr/local/bin/az \
  && ln -s /opt/venvs/oci-cli/bin/oci /usr/local/bin/oci \
  && for tool in /opt/venvs/ansible/bin/ansible*; do ln -s "$tool" /usr/local/bin/; done \
  && az version --output none \
  && oci --version \
  && ansible --version \
  # The checks above leave per-user state behind in root's home.
  && rm -rf /root/.azure /root/.oci /root/.ansible

# npm's global prefix is root-owned; point `npm install -g` at the persistent
# home instead. pip needs no equivalent: Ubuntu's Python refuses user installs
# outright, so Python tools belong in a venv under the home directory.
COPY <<'EOF' /etc/skel/.npmrc
prefix=${HOME}/.local
EOF

COPY config/ssh/sshd_config /etc/ssh/sshd_config
# The distribution stack runs pam_unix, which a non-root sshd cannot satisfy.
COPY config/pam.d/sshd /etc/pam.d/sshd

COPY --chmod=755 scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chmod=755 scripts/healthcheck.sh /usr/local/bin/healthcheck.sh

# Keep published containers traceable to the source revision.
ARG GIT_COMMIT=unknown
ENV GIT_COMMIT=${GIT_COMMIT}

USER user
WORKDIR /home/user
# Unprivileged, because the container has no capability to bind 22.
EXPOSE 2222

# tini as PID 1 reaps what sessions orphan - a tmux server outliving its
# client, background jobs - which a long-running container accumulates.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
