ARG BASE_IMAGE=ghcr.io/minsley/lobmob-lobster:latest
FROM ${BASE_IMAGE}

# Unity dependencies (X11 libs required even for headless/batch mode)
RUN apt-get update && apt-get install -y --no-install-recommends \
    libglu1-mesa libx11-6 libxcursor1 libxrandr2 libxi6 \
    xvfb ca-certificates wget gnupg \
    && rm -rf /var/lib/apt/lists/*

# Unity Hub
RUN wget -qO- https://hub.unity3d.com/linux/keys/public | gpg --dearmor > /usr/share/keyrings/unity.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/unity.gpg] https://hub.unity3d.com/linux/repos/deb stable main" \
    > /etc/apt/sources.list.d/unityhub.list \
    && apt-get update && apt-get install -y unityhub \
    && rm -rf /var/lib/apt/lists/*

# Install Unity 6000.3 LTS with Linux IL2CPP module
# NOTE: This layer is large (~5-8GB). Build time will be significant.
RUN unityhub --headless install --version 6000.3 --module linux-il2cpp \
    || echo "Unity install requires manual version specification — update version as needed"

# Unity license activation is handled at runtime via:
# - UNITY_LICENSE_FILE env var (base64-encoded .ulf file), or
# - UNITY_SERIAL + UNITY_EMAIL + UNITY_PASSWORD env vars
# See entrypoint or job spec for activation details.

ENV UNITY_EDITOR_PATH="/opt/unity/editors"
