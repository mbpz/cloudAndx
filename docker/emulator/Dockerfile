ARG TEST_BASE_IMAGE=debian:bookworm-slim@sha256:7b140f374b289a7c2befc338f42ebe6441b7ea838a042bbd5acbfca6ec875818
ARG RUNTIME_BASE_IMAGE=debian:bookworm-slim@sha256:7b140f374b289a7c2befc338f42ebe6441b7ea838a042bbd5acbfca6ec875818
ARG RUNTIME_PLATFORM=linux/amd64
ARG NATIVE_ENGINE_IMAGE=cloudandx/aemu-native-engine:37.1.7
ARG NATIVE_ENGINE_PLATFORM=linux/arm64
ARG NATIVE_AEMU_REVISION
ARG NATIVE_AEMU_SOURCE_LOCK_SHA256
ARG NATIVE_AEMU_PATCH_SET_SHA256

# This target deliberately has no network or Android artifact dependency. It is
# used to validate the runtime scripts and the complete Dockerfile on any host.
FROM ${TEST_BASE_IMAGE} AS self-test
WORKDIR /work
COPY bin/ ./bin/
COPY avd/ ./avd/
COPY tests/ ./tests/
COPY native-engine/bin/run-qemu-system-x86_64-headless ./native-engine/bin/run-qemu-system-x86_64-headless
RUN chmod 0555 bin/*.sh tests/*.sh \
      native-engine/bin/run-qemu-system-x86_64-headless \
    && tests/self-test.sh

FROM --platform=${RUNTIME_PLATFORM} ${RUNTIME_BASE_IMAGE} AS artifact-download-base

ARG ACCEPT_ANDROID_SDK_LICENSES=no

RUN test "${ACCEPT_ANDROID_SDK_LICENSES}" = "yes" || { \
      echo >&2 "Build stopped: pass --build-arg ACCEPT_ANDROID_SDK_LICENSES=yes after reviewing the Android SDK license."; \
      exit 64; \
    }

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      unzip \
    && rm -rf /var/lib/apt/lists/*

FROM artifact-download-base AS tool-fetcher

ARG EMULATOR_URL=https://dl.google.com/android/repository/emulator-linux_x64-15507667.zip
ARG EMULATOR_SHA1=f8d8b83cf21a04966326eb1378bacda255f63b93
ARG PLATFORM_TOOLS_URL=https://dl.google.com/android/repository/platform-tools_r37.0.0-linux.zip
ARG PLATFORM_TOOLS_SHA1=bcf323933980a59dccc3f14c339aed5fb2171163

RUN set -eu; \
    mkdir -p /opt/android-sdk; \
    curl --fail --location --retry 5 --retry-all-errors --connect-timeout 30 \
      --output /tmp/emulator.zip "${EMULATOR_URL}"; \
    echo "${EMULATOR_SHA1}  /tmp/emulator.zip" | sha1sum --check --strict -; \
    unzip -q /tmp/emulator.zip -d /opt/android-sdk; \
    test -x /opt/android-sdk/emulator/emulator; \
    rm -f /tmp/emulator.zip; \
    curl --fail --location --retry 5 --retry-all-errors --connect-timeout 30 \
      --output /tmp/platform-tools.zip "${PLATFORM_TOOLS_URL}"; \
    echo "${PLATFORM_TOOLS_SHA1}  /tmp/platform-tools.zip" | sha1sum --check --strict -; \
    unzip -q /tmp/platform-tools.zip -d /opt/android-sdk; \
    test -x /opt/android-sdk/platform-tools/adb; \
    rm -f /tmp/platform-tools.zip

FROM artifact-download-base AS system-image-fetcher

ARG SYSTEM_IMAGE_URL=https://dl.google.com/android/repository/sys-img/google_apis_playstore/x86_64-playstore-ps16k-37.0_r06.zip
ARG SYSTEM_IMAGE_SHA1=8eaeeceb77452c018c3f6b589913cdc45222a87f

RUN set -eu; \
    image_parent=/opt/android-sdk/system-images/android-37.0/google_apis_playstore_ps16k; \
    mkdir -p "${image_parent}"; \
    curl --fail --location --retry 5 --retry-all-errors --connect-timeout 30 \
      --output /tmp/system-image.zip "${SYSTEM_IMAGE_URL}"; \
    echo "${SYSTEM_IMAGE_SHA1}  /tmp/system-image.zip" | sha1sum --check --strict -; \
    unzip -q /tmp/system-image.zip -d "${image_parent}"; \
    test -s "${image_parent}/x86_64/system.img"; \
    test -s "${image_parent}/x86_64/vendor.img"; \
    rm -f /tmp/system-image.zip

FROM --platform=${RUNTIME_PLATFORM} ${RUNTIME_BASE_IMAGE} AS runtime-base

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates \
      fonts-dejavu-core \
      libasound2 \
      libdbus-1-3 \
      libdrm2 \
      libfontconfig1 \
      libgbm1 \
      libgl1 \
      libglib2.0-0 \
      libnss3 \
      libpulse0 \
      libsdl2-2.0-0 \
      libusb-1.0-0 \
      libvulkan1 \
      libx11-6 \
      libx11-xcb1 \
      libxcb1 \
      libxcomposite1 \
      libxcursor1 \
      libxdamage1 \
      libxext6 \
      libxfixes3 \
      libxi6 \
      libxkbcommon0 \
      libxkbfile1 \
      libxrandr2 \
      libxrender1 \
      libxtst6 \
      procps \
      socat \
      zlib1g \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 android \
    && useradd --uid 10001 --gid android --home-dir /data/home --shell /usr/sbin/nologin android \
    && install -d -o android -g android -m 0700 /data /data/home

FROM runtime-base AS runtime-tools
COPY --from=tool-fetcher /opt/android-sdk/ /opt/android-sdk/

FROM runtime-tools AS runtime-tools-smoke
RUN set -eu; \
    emulator_version=$(/opt/android-sdk/emulator/emulator -version 2>&1); \
    printf '%s\n' "${emulator_version}"; \
    printf '%s\n' "${emulator_version}" | grep -q '36\.6\.11'; \
    adb_version=$(/opt/android-sdk/platform-tools/adb version 2>&1); \
    printf '%s\n' "${adb_version}"; \
    printf '%s\n' "${adb_version}" | grep -q 'Version 37\.0\.0'

FROM --platform=${NATIVE_ENGINE_PLATFORM} ${NATIVE_ENGINE_IMAGE} AS native-engine-bundle

FROM runtime-base AS runtime

ARG EMULATOR_URL=https://dl.google.com/android/repository/emulator-linux_x64-15507667.zip
ARG EMULATOR_SHA1=f8d8b83cf21a04966326eb1378bacda255f63b93
ARG PLATFORM_TOOLS_URL=https://dl.google.com/android/repository/platform-tools_r37.0.0-linux.zip
ARG PLATFORM_TOOLS_SHA1=bcf323933980a59dccc3f14c339aed5fb2171163
ARG SYSTEM_IMAGE_URL=https://dl.google.com/android/repository/sys-img/google_apis_playstore/x86_64-playstore-ps16k-37.0_r06.zip
ARG SYSTEM_IMAGE_SHA1=8eaeeceb77452c018c3f6b589913cdc45222a87f
ARG NATIVE_AEMU_REVISION
ARG NATIVE_AEMU_SOURCE_LOCK_SHA256
ARG NATIVE_AEMU_PATCH_SET_SHA256
ARG NATIVE_AEMU_QEMU_COMMIT=98f7f6ffcc4e6ce513a8b978323c3b961dc58143

LABEL org.opencontainers.image.title="Android 17 Google Play Emulator (Docker-only)" \
      org.opencontainers.image.description="Google Android Emulator 36.6.11 with Android 17 API 37.0 Google Play x86_64 16 KB r06" \
      org.opencontainers.image.version="android-17-api-37.0-play-r06-emulator-36.6.11" \
      org.opencontainers.image.vendor="cloudAndx" \
      io.cloudandx.android.release="Android 17 base release (API 37.0); Android 17 QPR1 remains excluded until its public stable release" \
      io.cloudandx.android.emulator.url="${EMULATOR_URL}" \
      io.cloudandx.android.emulator.sha1="${EMULATOR_SHA1}" \
      io.cloudandx.android.platform-tools.url="${PLATFORM_TOOLS_URL}" \
      io.cloudandx.android.platform-tools.sha1="${PLATFORM_TOOLS_SHA1}" \
      io.cloudandx.android.system-image.url="${SYSTEM_IMAGE_URL}" \
      io.cloudandx.android.system-image.sha1="${SYSTEM_IMAGE_SHA1}" \
      io.cloudandx.android.native-aemu.revision="${NATIVE_AEMU_REVISION}" \
      io.cloudandx.android.native-aemu.source-lock-sha256="${NATIVE_AEMU_SOURCE_LOCK_SHA256}" \
      io.cloudandx.android.native-aemu.patch-set-sha256="${NATIVE_AEMU_PATCH_SET_SHA256}" \
      io.cloudandx.android.native-aemu.qemu-commit="${NATIVE_AEMU_QEMU_COMMIT}"

COPY --from=tool-fetcher /opt/android-sdk/ /opt/android-sdk/
COPY --from=system-image-fetcher /opt/android-sdk/system-images/ /opt/android-sdk/system-images/
COPY --from=native-engine-bundle /opt/cloudandx/native-aemu/ /opt/cloudandx/native-aemu/
COPY avd/ /opt/android-avd-template/
COPY bin/entrypoint.sh bin/healthcheck.sh bin/runtime-lib.sh bin/runtime-preflight.sh bin/qemu-system-x86_64-headless-dispatcher.sh /usr/local/bin/

RUN set -eu; \
    test -n "${NATIVE_AEMU_REVISION}"; \
    test "${#NATIVE_AEMU_SOURCE_LOCK_SHA256}" -eq 64; \
    test "${#NATIVE_AEMU_PATCH_SET_SHA256}" -eq 64; \
    qemu_child=/opt/android-sdk/emulator/qemu/linux-x86_64/qemu-system-x86_64-headless; \
    test -x "${qemu_child}"; \
    mv "${qemu_child}" "${qemu_child}.upstream-x86_64"; \
    install -m 0555 /usr/local/bin/qemu-system-x86_64-headless-dispatcher.sh "${qemu_child}"; \
    rm -f /usr/local/bin/qemu-system-x86_64-headless-dispatcher.sh; \
    chmod 0555 /usr/local/bin/entrypoint.sh \
      /usr/local/bin/healthcheck.sh \
      /usr/local/bin/runtime-lib.sh \
      /usr/local/bin/runtime-preflight.sh \
    && install -m 0555 /opt/cloudandx/native-aemu/lib/ld-linux-aarch64.so.1 \
      /lib/ld-linux-aarch64.so.1 \
    && cmp -s /opt/cloudandx/native-aemu/lib/ld-linux-aarch64.so.1 \
      /lib/ld-linux-aarch64.so.1 \
    && (cd /opt/cloudandx/native-aemu && sha256sum -c SHA256SUMS) \
    && grep -Fxq "revision=${NATIVE_AEMU_REVISION}" \
      /opt/cloudandx/native-aemu/identity.properties \
    && grep -Fxq "source_lock_sha256=${NATIVE_AEMU_SOURCE_LOCK_SHA256}" \
      /opt/cloudandx/native-aemu/identity.properties \
    && grep -Fxq "patch_set_sha256=${NATIVE_AEMU_PATCH_SET_SHA256}" \
      /opt/cloudandx/native-aemu/identity.properties \
    && test -L /opt/cloudandx/native-aemu/bin/lib64 \
    && test "$(readlink /opt/cloudandx/native-aemu/bin/lib64)" = ../lib \
    && chmod -R a-w /opt/android-sdk /opt/android-avd-template \
      /opt/cloudandx/native-aemu \
    && test -x /opt/android-sdk/emulator/emulator \
    && test -x /opt/android-sdk/platform-tools/adb \
    && test -x "${qemu_child}" \
    && test -x "${qemu_child}.upstream-x86_64" \
    && test -x /opt/cloudandx/native-aemu/bin/run-qemu-system-x86_64-headless \
    && test -s /opt/android-sdk/system-images/android-37.0/google_apis_playstore_ps16k/x86_64/system.img

ENV ANDROID_SDK_ROOT=/opt/android-sdk \
    ANDROID_HOME=/opt/android-sdk \
    ANDROID_AVD_HOME=/data/avd \
    ANDROID_EMULATOR_HOME=/data/emulator-home \
    ANDROID_PREFS_ROOT=/data/prefs \
    HOME=/data/home \
    PATH=/opt/android-sdk/emulator:/opt/android-sdk/platform-tools:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    AVD_NAME=Pixel_9_Android_17_Play \
    EMULATOR_ACCEL=auto \
    EMULATOR_CORES=4 \
    EMULATOR_MEMORY_MB=4096 \
    EMULATOR_GPU=swiftshader \
    EMULATOR_CONSOLE_PORT=5556 \
    EMULATOR_ADB_PORT=5557 \
    ADB_PROXY_PORT=5555 \
    EMULATOR_GRPC_INTERNAL_PORT=8556 \
    EMULATOR_GRPC_PORT=8554 \
    EMULATOR_WIPE_DATA=0 \
    ANDROID_RUNTIME_IMPLEMENTATION=native \
    NATIVE_AEMU_ROOT=/opt/cloudandx/native-aemu \
    NATIVE_AEMU_REVISION=${NATIVE_AEMU_REVISION} \
    NATIVE_AEMU_SOURCE_LOCK_SHA256=${NATIVE_AEMU_SOURCE_LOCK_SHA256} \
    NATIVE_AEMU_PATCH_SET_SHA256=${NATIVE_AEMU_PATCH_SET_SHA256} \
    ADB_MDNS_OPENSCREEN=0

USER android:android
WORKDIR /data
VOLUME ["/data"]
EXPOSE 5555/tcp 8554/tcp

HEALTHCHECK --start-period=30m --interval=30s --timeout=15s --retries=10 \
  CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
