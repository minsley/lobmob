ARG BASE_IMAGE=ghcr.io/minsley/lobmob-lobster:latest
FROM ${BASE_IMAGE}

# Android SDK dependencies
ENV ANDROID_HOME=/opt/android-sdk
ENV PATH="${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:${PATH}"

RUN apt-get update && apt-get install -y --no-install-recommends \
    openjdk-17-jdk-headless unzip wget \
    && rm -rf /var/lib/apt/lists/*

# Android command-line tools
RUN mkdir -p "${ANDROID_HOME}/cmdline-tools" \
    && wget -q https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip -O /tmp/cmdtools.zip \
    && unzip -q /tmp/cmdtools.zip -d "${ANDROID_HOME}/cmdline-tools" \
    && mv "${ANDROID_HOME}/cmdline-tools/cmdline-tools" "${ANDROID_HOME}/cmdline-tools/latest" \
    && rm /tmp/cmdtools.zip

# Accept licenses and install platform tools
RUN yes | sdkmanager --licenses > /dev/null 2>&1 \
    && sdkmanager "platform-tools" "build-tools;34.0.0" "platforms;android-34"
