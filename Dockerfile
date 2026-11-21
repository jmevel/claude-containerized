
FROM debian:12

ARG PUID=1000
ARG PGID=1000

ENV DEBIAN_FRONTEND=noninteractive

# Install Anthropic's official APT repository
RUN apt-get update && apt-get install -y \
    ca-certificates \
    curl \
    dbus \
    dbus-x11 \
    wayland-utils \
    && curl -fsSLo \
       /usr/share/keyrings/claude-desktop-archive-keyring.asc \
       https://downloads.claude.ai/claude-desktop/key.asc \
    && echo "deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/claude-desktop-archive-keyring.asc] https://downloads.claude.ai/claude-desktop/apt/stable stable main" \
       > /etc/apt/sources.list.d/claude-desktop.list \
    && apt-get update \
    && apt-get install -y claude-desktop \
    && rm -rf /var/lib/apt/lists/*

# Create an unprivileged user matching the host UID/GID
RUN groupadd --gid ${PGID} claude \
    && useradd \
       --uid ${PUID} \
       --gid ${PGID} \
       --create-home \
       --shell /bin/bash \
       claude \
    && mkdir -p /workspace /run/user/${PUID} \
    && chown -R ${PUID}:${PGID} \
       /home/claude /workspace /run/user/${PUID} \
    && chmod 700 /run/user/${PUID}

ENV HOME=/home/claude
ENV XDG_RUNTIME_DIR=/run/user/${PUID}
ENV WAYLAND_DISPLAY=wayland-0

USER ${PUID}:${PGID}

WORKDIR /workspace

# CMD ["dbus-run-session", "--", "claude-desktop", "--ozone-platform=wayland"]
# --password-store: Electron picks its secret store from XDG_CURRENT_DESKTOP, which is
# unset here, so it would fall back to "basic_text" and the app would not keep you signed in.
CMD ["dbus-run-session", "--", "claude-desktop", "--ozone-platform=wayland", "--no-sandbox", "--password-store=gnome-libsecret"]
