# syntax=docker/dockerfile:1
#
# Image for the orca-serve workload kit (descriptor: orca-serve.yaml).
# Docker-in-sandbox + Orca headless server + mise + chezmoi + git + fish.
# gh and other CLIs are installed per project with mise; Claude Code comes from a mixin.
#
# The launch command stays a login shell, like the official shell workload. `orca-ide serve`
# is started by the descriptor's lifecycle startup hook, once per sandbox boot, not per session.
# For reproducible builds, pin the base by digest: docker/sandbox-templates:shell-docker@sha256:...
ARG BASE_IMAGE=docker/sandbox-templates:shell-docker
FROM ${BASE_IMAGE}

# Release tag on github.com/stablyai/orca ("latest" follows the newest release).
ARG ORCA_VERSION=v1.4.243
# mise release (e.g. v2026.10.5). Empty = latest at build time.
ARG MISE_VERSION=
# chezmoi release (e.g. v2.70.0). Empty = latest at build time.
ARG CHEZMOI_VERSION=
ARG TARGETARCH

USER root
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ENV DEBIAN_FRONTEND=noninteractive

# ---- Base tools + Electron runtime libraries for `orca-ide serve` -------------------------
# Ubuntu 24.04+/Debian 13 rename six libraries with a t64 suffix; pick whichever exists.
RUN apt-get update \
 && pick() { if apt-cache show --no-all-versions "$1t64" >/dev/null 2>&1; then echo "$1t64"; else echo "$1"; fi; } \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git file xvfb fish \
      libnss3 libgbm1 libxtst6 libdrm2 libxkbcommon0 libpango-1.0-0 libcairo2 \
      libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libxrender1 libx11-xcb1 \
      libxcb-dri3-0 libxss1 \
      "$(pick libgtk-3-0)" "$(pick libatk1.0-0)" "$(pick libatk-bridge2.0-0)" \
      "$(pick libasound2)" "$(pick libcups2)" "$(pick libatspi2.0-0)" \
 && rm -rf /var/lib/apt/lists/*

# ---- mise (system-wide binary; tools/data stay per-user under ~/.local/share/mise) ---------
RUN curl -fsSL https://mise.run \
      | MISE_INSTALL_PATH=/usr/local/bin/mise MISE_VERSION="${MISE_VERSION}" sh \
 && mise --version \
 && printf '%s\n' 'if command -v mise >/dev/null 2>&1; then eval "$(mise activate bash)"; fi' \
      > /etc/profile.d/mise.sh

# ---- chezmoi (system-wide binary; source state stays per-user under ~/.local/share/chezmoi)
RUN curl -fsSL https://get.chezmoi.io \
      | sh -s -- -b /usr/local/bin ${CHEZMOI_VERSION:+-t "$CHEZMOI_VERSION"} \
 && chezmoi --version

# ---- Orca (AppImage extracted, so no FUSE device is needed) -------------------------------
# chrome-sandbox is made setuid root so Chromium's sandbox works for the non-root agent user
# (no --no-sandbox needed).
RUN arch="${TARGETARCH:-$(dpkg --print-architecture)}" \
 && case "$arch" in \
      amd64) asset=orca-linux.AppImage ;; \
      arm64) asset=orca-linux-arm64.AppImage ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac \
 && if [ "$ORCA_VERSION" = latest ]; then \
      url="https://github.com/stablyai/orca/releases/latest/download/${asset}"; \
    else \
      url="https://github.com/stablyai/orca/releases/download/${ORCA_VERSION}/${asset}"; \
    fi \
 && tmp="$(mktemp -d)" && cd "$tmp" \
 && curl -fL --retry 3 -o orca.AppImage "$url" \
 && chmod +x orca.AppImage \
 && ./orca.AppImage --appimage-extract >/dev/null \
 && mv squashfs-root /opt/orca \
 && cd / && rm -rf "$tmp" \
 && chown root:root /opt/orca/chrome-sandbox && chmod 4755 /opt/orca/chrome-sandbox \
 && chmod -R a+rX /opt/orca \
 && ln -sf /opt/orca/AppRun /usr/local/bin/orca-ide \
 && grep -m1 '^X-AppImage-Version=' /opt/orca/*.desktop

USER agent
# Shims make mise-managed tools visible to non-interactive shells (agents, `sbx exec`).
ENV PATH=/home/agent/.local/share/mise/shims:${PATH}
RUN grep -q 'mise activate bash' ~/.bashrc 2>/dev/null \
      || echo 'eval "$(mise activate bash)"' >> ~/.bashrc
# Pre-create the parents of the host mounts (~/.config/orca, ~/.local/state/orca-serve) as
# agent: the runtime would otherwise create them root-owned, and other tools could not write.
RUN mkdir -p ~/.config ~/.local/state

# Ask the runtime to start Docker Engine (paired with privileged@1 in the descriptor).
LABEL com.docker.sandboxes.start-docker="true"

ENTRYPOINT ["bash"]
CMD ["-l"]
