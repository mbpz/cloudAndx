ARG TEST_BASE_IMAGE=debian:bookworm-slim@sha256:7b140f374b289a7c2befc338f42ebe6441b7ea838a042bbd5acbfca6ec875818
ARG RUNTIME_BASE_IMAGE=debian:bookworm-slim@sha256:7b140f374b289a7c2befc338f42ebe6441b7ea838a042bbd5acbfca6ec875818
ARG RUNTIME_PLATFORM=linux/amd64
ARG NATIVE_ENGINE_IMAGE=cloudandx/aemu-native-engine:37.1.7
ARG NATIVE_ENGINE_PLATFORM=linux/arm64
ARG NATIVE_AEMU_REVISION
ARG NATIVE_AEMU_SOURCE_LOCK_SHA256
ARG NATIVE_AEMU_PATCH_SET_SHA256
ARG ANDROID_HW_TIMEOUT_MULTIPLIER=50
ARG ANDROID_FINALIZER_TIMEOUT_MS=500000
ARG ANDROID_BLUETOOTH_HCI_TIMEOUT_MS=100000
ARG ANDROID_BLUETOOTH_HCI_RESTART_TIMEOUT_MS=250000
ARG ANDROID_RAMDISK_ORIGINAL_SHA256=be1c34d44bdf2484c9bb0f4458b1cb3b8133d887bc87441dd5a5cb7c5fcfdff8
ARG ANDROID_RAMDISK_CPIO_SHA256=56328ce8b964a5f53c7c6922d4c2415a3d10a2d36f100150d522a817054110ed
ARG ANDROID_RAMDISK_DERIVED_SHA256=bfaeb73b28c50733a90337ceb93d66b5eb652f713b807744d86532f28344035c
ARG ANDROID_RAMDISK_OVERLAY_PATH=system/etc/ramdisk/build.prop
ARG NOVNC_VERSION=1.7.0
ARG NOVNC_SHA256=b1003a11b6e6e8d8f7f5e5586daae7f8ca651d8aee0aa155ff9ac841c48f52c6
ARG WEBSOCKIFY_VERSION=0.13.0
ARG WEBSOCKIFY_SHA256=b6413e364efd04f3c92ec8c17747e3c4adc20157c2ef1c5d019a26d944a46df8
ARG SCRCPY_VERSION=4.1
ARG SCRCPY_SHA256=ad56ae8bfeedf41e824945c11dbf55fcb092b3e615b9b486f48a50e30d389635

# This target deliberately has no network or Android artifact dependency. It is
# used to validate the runtime scripts and the complete Dockerfile on any host.
FROM ${TEST_BASE_IMAGE} AS self-test
WORKDIR /work
COPY docker/emulator/bin/ ./bin/
COPY docker/emulator/avd/ ./avd/
COPY docker/emulator/tests/ ./tests/
COPY docker/emulator/native-engine/bin/run-qemu-system-aarch64-headless ./native-engine/bin/run-qemu-system-aarch64-headless
COPY docker/emulator/native-engine/bin/netsimd ./native-engine/bin/netsimd
RUN chmod 0555 bin/*.sh tests/*.sh \
      native-engine/bin/run-qemu-system-aarch64-headless native-engine/bin/netsimd \
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

ARG SYSTEM_IMAGE_URL=https://dl.google.com/android/repository/sys-img/google_apis_playstore/arm64-v8a-playstore-ps16k-37.0_r06.zip
ARG SYSTEM_IMAGE_SHA1=ef7d53e7b2fba3cf00917364f6d3e4f6dbebe7b4

RUN --mount=type=cache,id=cloudandx-android17-r06-system-image,target=/var/cache/cloudandx-downloads \
    set -eu; \
    image_parent=/opt/android-sdk/system-images/android-37.0/google_apis_playstore_ps16k; \
    archive=/var/cache/cloudandx-downloads/arm64-v8a-playstore-ps16k-37.0_r06.zip; \
    mkdir -p "${image_parent}"; \
    if ! echo "${SYSTEM_IMAGE_SHA1}  ${archive}" | sha1sum --check --status -; then \
      curl --fail --location --retry 5 --retry-all-errors --connect-timeout 30 \
        --continue-at - --output "${archive}" "${SYSTEM_IMAGE_URL}"; \
    fi; \
    echo "${SYSTEM_IMAGE_SHA1}  ${archive}" | sha1sum --check --strict -; \
    unzip -q "${archive}" -d "${image_parent}"; \
    test -s "${image_parent}/arm64-v8a/system.img"; \
    test -s "${image_parent}/arm64-v8a/vendor.img"

FROM artifact-download-base AS remote-ui-fetcher

ARG NOVNC_VERSION
ARG NOVNC_SHA256
ARG WEBSOCKIFY_VERSION
ARG WEBSOCKIFY_SHA256
ARG SCRCPY_VERSION
ARG SCRCPY_SHA256

RUN set -eu; \
    mkdir -p /opt/cloudandx/dist /opt/cloudandx/ui; \
    curl --fail --location --retry 5 --retry-all-errors --connect-timeout 30 \
      --output /tmp/novnc.tar.gz \
      "https://github.com/novnc/noVNC/archive/refs/tags/v${NOVNC_VERSION}.tar.gz"; \
    echo "${NOVNC_SHA256}  /tmp/novnc.tar.gz" | sha256sum --check --strict -; \
    tar -xzf /tmp/novnc.tar.gz -C /opt/cloudandx/ui; \
    mv "/opt/cloudandx/ui/noVNC-${NOVNC_VERSION}" /opt/cloudandx/novnc; \
    test -f /opt/cloudandx/novnc/vnc.html; \
    ln -s vnc.html /opt/cloudandx/novnc/index.html; \
    rm -f /tmp/novnc.tar.gz; \
    curl --fail --location --retry 5 --retry-all-errors --connect-timeout 30 \
      --output /tmp/websockify.tar.gz \
      "https://github.com/novnc/websockify/archive/refs/tags/v${WEBSOCKIFY_VERSION}.tar.gz"; \
    echo "${WEBSOCKIFY_SHA256}  /tmp/websockify.tar.gz" | sha256sum --check --strict -; \
    install -D -m 0444 /tmp/websockify.tar.gz \
      "/opt/cloudandx/dist/websockify-${WEBSOCKIFY_VERSION}.tar.gz"; \
    rm -f /tmp/websockify.tar.gz; \
    curl --fail --location --retry 5 --retry-all-errors --connect-timeout 30 \
      --output /tmp/scrcpy.tar.gz \
      "https://github.com/Genymobile/scrcpy/releases/download/v${SCRCPY_VERSION}/scrcpy-linux-x86_64-v${SCRCPY_VERSION}.tar.gz"; \
    echo "${SCRCPY_SHA256}  /tmp/scrcpy.tar.gz" | sha256sum --check --strict -; \
    tar -xzf /tmp/scrcpy.tar.gz -C /opt/cloudandx/ui; \
    mv "/opt/cloudandx/ui/scrcpy-linux-x86_64-v${SCRCPY_VERSION}" /opt/cloudandx/scrcpy; \
    test -x /opt/cloudandx/scrcpy/scrcpy; \
    test -s /opt/cloudandx/scrcpy/scrcpy-server; \
    rm -f /tmp/scrcpy.tar.gz

FROM artifact-download-base AS ramdisk-overlay-builder

ARG ANDROID_HW_TIMEOUT_MULTIPLIER
ARG ANDROID_FINALIZER_TIMEOUT_MS
ARG ANDROID_BLUETOOTH_HCI_TIMEOUT_MS
ARG ANDROID_BLUETOOTH_HCI_RESTART_TIMEOUT_MS
ARG ANDROID_RAMDISK_ORIGINAL_SHA256
ARG ANDROID_RAMDISK_CPIO_SHA256
ARG ANDROID_RAMDISK_DERIVED_SHA256
ARG ANDROID_RAMDISK_OVERLAY_PATH

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      cpio \
      lz4 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=system-image-fetcher \
  /opt/android-sdk/system-images/android-37.0/google_apis_playstore_ps16k/arm64-v8a/ramdisk.img \
  /work/official-ramdisk.img
COPY docker/emulator/bin/build-ramdisk-overlay.sh /usr/local/bin/build-ramdisk-overlay.sh

RUN chmod 0555 /usr/local/bin/build-ramdisk-overlay.sh \
    && /usr/local/bin/build-ramdisk-overlay.sh \
      /work/official-ramdisk.img \
      /opt/cloudandx/android-ramdisk \
      "${ANDROID_HW_TIMEOUT_MULTIPLIER}" \
      "${ANDROID_FINALIZER_TIMEOUT_MS}" \
      "${ANDROID_BLUETOOTH_HCI_TIMEOUT_MS}" \
      "${ANDROID_BLUETOOTH_HCI_RESTART_TIMEOUT_MS}" \
      "${ANDROID_RAMDISK_ORIGINAL_SHA256}" \
      "${ANDROID_RAMDISK_CPIO_SHA256}" \
      "${ANDROID_RAMDISK_DERIVED_SHA256}" \
      "${ANDROID_RAMDISK_OVERLAY_PATH}"

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
      openssl \
      procps \
      python3 \
      python3-pip \
      socat \
      x11vnc \
      xvfb \
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
ARG SYSTEM_IMAGE_URL=https://dl.google.com/android/repository/sys-img/google_apis_playstore/arm64-v8a-playstore-ps16k-37.0_r06.zip
ARG SYSTEM_IMAGE_SHA1=ef7d53e7b2fba3cf00917364f6d3e4f6dbebe7b4
ARG NATIVE_AEMU_REVISION
ARG NATIVE_AEMU_SOURCE_LOCK_SHA256
ARG NATIVE_AEMU_PATCH_SET_SHA256
ARG NATIVE_AEMU_QEMU_COMMIT=98f7f6ffcc4e6ce513a8b978323c3b961dc58143
ARG ANDROID_HW_TIMEOUT_MULTIPLIER
ARG ANDROID_FINALIZER_TIMEOUT_MS
ARG ANDROID_BLUETOOTH_HCI_TIMEOUT_MS
ARG ANDROID_BLUETOOTH_HCI_RESTART_TIMEOUT_MS
ARG ANDROID_RAMDISK_ORIGINAL_SHA256
ARG ANDROID_RAMDISK_CPIO_SHA256
ARG ANDROID_RAMDISK_DERIVED_SHA256
ARG ANDROID_RAMDISK_OVERLAY_PATH
ARG NOVNC_VERSION
ARG NOVNC_SHA256
ARG WEBSOCKIFY_VERSION
ARG WEBSOCKIFY_SHA256
ARG SCRCPY_VERSION
ARG SCRCPY_SHA256

LABEL org.opencontainers.image.title="Android 17 Google Play Emulator (Docker-only)" \
      org.opencontainers.image.description="Google Android 17 API 37.0 Play arm64-v8a 16 KB r06 with native AEMU 37.1.7 and SDK resources from Emulator 36.6.11" \
      org.opencontainers.image.version="android-17-api-37.0-play-r06-native-aemu-37.1.7-sdk-emulator-36.6.11" \
      org.opencontainers.image.vendor="cloudAndx" \
      io.cloudandx.android.release="Android 17 base release (API 37.0); Android 17 QPR1 remains excluded until its public stable release" \
      io.cloudandx.android.emulator.url="${EMULATOR_URL}" \
      io.cloudandx.android.emulator.sha1="${EMULATOR_SHA1}" \
      io.cloudandx.android.platform-tools.url="${PLATFORM_TOOLS_URL}" \
      io.cloudandx.android.platform-tools.sha1="${PLATFORM_TOOLS_SHA1}" \
      io.cloudandx.android.system-image.url="${SYSTEM_IMAGE_URL}" \
      io.cloudandx.android.system-image.sha1="${SYSTEM_IMAGE_SHA1}" \
      io.cloudandx.android.ramdisk.original-sha256="${ANDROID_RAMDISK_ORIGINAL_SHA256}" \
      io.cloudandx.android.ramdisk.derived-sha256="${ANDROID_RAMDISK_DERIVED_SHA256}" \
      io.cloudandx.android.ramdisk.overlay="${ANDROID_RAMDISK_OVERLAY_PATH}:ro.hw_timeout_multiplier=${ANDROID_HW_TIMEOUT_MULTIPLIER},dalvik.vm.finalizer-timeout-ms=${ANDROID_FINALIZER_TIMEOUT_MS},bluetooth.hci.timeout_milliseconds=${ANDROID_BLUETOOTH_HCI_TIMEOUT_MS},bluetooth.hci.restart_timeout_milliseconds=${ANDROID_BLUETOOTH_HCI_RESTART_TIMEOUT_MS}" \
      io.cloudandx.android.native-aemu.revision="${NATIVE_AEMU_REVISION}" \
      io.cloudandx.android.native-aemu.netsimd.version="0.3.112" \
      io.cloudandx.android.native-aemu.vulkan-loader.commit="bac41319cafb4527a2a959237b17611dd08bfe11" \
      io.cloudandx.android.native-aemu.vulkan-swiftshader.commit="9a22bb9de00f5d8ddf4fc5ba5c2f425c2816e679" \
      io.cloudandx.android.native-aemu.source-lock-sha256="${NATIVE_AEMU_SOURCE_LOCK_SHA256}" \
      io.cloudandx.android.native-aemu.patch-set-sha256="${NATIVE_AEMU_PATCH_SET_SHA256}" \
      io.cloudandx.android.native-aemu.qemu-commit="${NATIVE_AEMU_QEMU_COMMIT}"

COPY --from=tool-fetcher /opt/android-sdk/ /opt/android-sdk/
COPY --from=system-image-fetcher /opt/android-sdk/system-images/ /opt/android-sdk/system-images/
COPY --from=ramdisk-overlay-builder /opt/cloudandx/android-ramdisk/ /opt/cloudandx/android-ramdisk/
COPY --from=remote-ui-fetcher /opt/cloudandx/novnc/ /opt/cloudandx/novnc/
COPY --from=remote-ui-fetcher /opt/cloudandx/scrcpy/ /opt/cloudandx/scrcpy/
COPY --from=remote-ui-fetcher /opt/cloudandx/dist/ /opt/cloudandx/dist/
COPY --from=ramdisk-overlay-builder \
  /opt/cloudandx/android-ramdisk/derived-ramdisk.img \
  /opt/android-sdk/system-images/android-37.0/google_apis_playstore_ps16k/arm64-v8a/ramdisk.img
COPY --from=native-engine-bundle /opt/cloudandx/native-aemu/ /opt/cloudandx/native-aemu/
COPY docker/emulator/avd/ /opt/android-avd-template/
COPY docker/emulator/bin/entrypoint.sh docker/emulator/bin/single-container-entrypoint.sh docker/emulator/bin/healthcheck.sh docker/emulator/bin/runtime-lib.sh docker/emulator/bin/runtime-preflight.sh /usr/local/bin/
COPY docker/bootstrap/check-runtime-arch.sh /usr/local/bin/
COPY services/device-bridge/bridge.py /opt/cloudandx/device-bridge/bridge.py
COPY services/evidence-gate/requirements.txt /opt/cloudandx/evidence-gate/requirements.txt
COPY services/evidence-gate/src/ /opt/cloudandx/evidence-gate/src/

RUN python3 -m pip install --break-system-packages --no-cache-dir --disable-pip-version-check \
      -r /opt/cloudandx/evidence-gate/requirements.txt \
      "/opt/cloudandx/dist/websockify-${WEBSOCKIFY_VERSION}.tar.gz"

RUN set -eu; \
    test -n "${NATIVE_AEMU_REVISION}"; \
    test "${#NATIVE_AEMU_SOURCE_LOCK_SHA256}" -eq 64; \
    test "${#NATIVE_AEMU_PATCH_SET_SHA256}" -eq 64; \
    test "${#ANDROID_RAMDISK_ORIGINAL_SHA256}" -eq 64; \
    test "${#ANDROID_RAMDISK_CPIO_SHA256}" -eq 64; \
    test "${#ANDROID_RAMDISK_DERIVED_SHA256}" -eq 64; \
    chmod 0555 /usr/local/bin/entrypoint.sh \
      /usr/local/bin/single-container-entrypoint.sh \
      /usr/local/bin/healthcheck.sh \
      /usr/local/bin/runtime-lib.sh \
      /usr/local/bin/runtime-preflight.sh \
      /usr/local/bin/check-runtime-arch.sh \
      /opt/cloudandx/device-bridge/bridge.py \
    && install -m 0555 /opt/cloudandx/native-aemu/lib64/ld-linux-aarch64.so.1 \
      /lib/ld-linux-aarch64.so.1 \
    && cmp -s /opt/cloudandx/native-aemu/lib64/ld-linux-aarch64.so.1 \
      /lib/ld-linux-aarch64.so.1 \
    && (cd /opt/cloudandx/native-aemu && sha256sum -c SHA256SUMS) \
    && grep -Fxq "revision=${NATIVE_AEMU_REVISION}" \
      /opt/cloudandx/native-aemu/identity.properties \
    && grep -Fxq "source_lock_sha256=${NATIVE_AEMU_SOURCE_LOCK_SHA256}" \
      /opt/cloudandx/native-aemu/identity.properties \
    && grep -Fxq "patch_set_sha256=${NATIVE_AEMU_PATCH_SET_SHA256}" \
      /opt/cloudandx/native-aemu/identity.properties \
    && printf '%s  %s\n' "${ANDROID_RAMDISK_ORIGINAL_SHA256}" \
      /opt/cloudandx/android-ramdisk/official-ramdisk.img \
      | sha256sum --check --strict - \
    && printf '%s  %s\n' "${ANDROID_RAMDISK_DERIVED_SHA256}" \
      /opt/cloudandx/android-ramdisk/derived-ramdisk.img \
      | sha256sum --check --strict - \
    && cmp -s /opt/cloudandx/android-ramdisk/derived-ramdisk.img \
      /opt/android-sdk/system-images/android-37.0/google_apis_playstore_ps16k/arm64-v8a/ramdisk.img \
    && grep -Fxq "official_ramdisk_sha256=${ANDROID_RAMDISK_ORIGINAL_SHA256}" \
      /opt/cloudandx/android-ramdisk/identity.properties \
    && grep -Fxq "official_cpio_sha256=${ANDROID_RAMDISK_CPIO_SHA256}" \
      /opt/cloudandx/android-ramdisk/identity.properties \
    && grep -Fxq "derived_ramdisk_sha256=${ANDROID_RAMDISK_DERIVED_SHA256}" \
      /opt/cloudandx/android-ramdisk/identity.properties \
    && grep -Fxq "overlay_path=${ANDROID_RAMDISK_OVERLAY_PATH}" \
      /opt/cloudandx/android-ramdisk/identity.properties \
    && grep -Fxq "overlay_property.ro_hw_timeout_multiplier=${ANDROID_HW_TIMEOUT_MULTIPLIER}" \
      /opt/cloudandx/android-ramdisk/identity.properties \
    && grep -Fxq "overlay_property.dalvik_vm_finalizer_timeout_ms=${ANDROID_FINALIZER_TIMEOUT_MS}" \
      /opt/cloudandx/android-ramdisk/identity.properties \
    && grep -Fxq "overlay_property.bluetooth_hci_timeout_ms=${ANDROID_BLUETOOTH_HCI_TIMEOUT_MS}" \
      /opt/cloudandx/android-ramdisk/identity.properties \
    && grep -Fxq "overlay_property.bluetooth_hci_restart_timeout_ms=${ANDROID_BLUETOOTH_HCI_RESTART_TIMEOUT_MS}" \
      /opt/cloudandx/android-ramdisk/identity.properties \
    && test -L /opt/cloudandx/native-aemu/qemu/linux-aarch64/lib64 \
    && test "$(readlink /opt/cloudandx/native-aemu/qemu/linux-aarch64/lib64)" = ../../lib64 \
    && test -x /opt/cloudandx/native-aemu/qemu/linux-aarch64/qemu-system-aarch64-headless \
    && test -s /opt/cloudandx/native-aemu/lib64/libgfxstream_backend.so \
    && test -s /opt/cloudandx/native-aemu/lib64/libX11-xcb.so.1 \
    && test -x /opt/cloudandx/native-aemu/crashpad_handler \
    && test -x /opt/cloudandx/native-aemu/qemu-img \
    && test -x /opt/cloudandx/native-aemu/nimble_bridge \
    && test -x /opt/cloudandx/native-aemu/netsimd \
    && test -x /opt/cloudandx/native-aemu/libexec/linux-x86_64/netsimd \
    && netsimd_version=$(/opt/cloudandx/native-aemu/netsimd --version 2>&1) \
    && printf '%s\n' "${netsimd_version}" \
    && printf '%s\n' "${netsimd_version}" \
      | grep -Eq '(^|[^0-9])0\.3\.112([^0-9]|$)' \
    && test -s /opt/cloudandx/native-aemu/lib/advancedFeatures.ini \
    && test -s /opt/cloudandx/native-aemu/lib/emu-original-feature-flags.protobuf \
    && test -s /opt/cloudandx/native-aemu/lib/ca-bundle.pem \
    && test -s /opt/cloudandx/native-aemu/lib/hostapd.conf \
    && test -s /opt/cloudandx/native-aemu/lib/emulator_access.json \
    && test -s /opt/cloudandx/native-aemu/lib64/gles_swiftshader/libEGL.so \
    && test -s /opt/cloudandx/native-aemu/lib64/gles_swiftshader/libGLES_CM.so \
    && test -s /opt/cloudandx/native-aemu/lib64/gles_swiftshader/libGLESv2.so \
    && test -s /opt/cloudandx/native-aemu/lib64/vulkan/libvulkan.so.1.4.344 \
    && test -L /opt/cloudandx/native-aemu/lib64/vulkan/libvulkan.so.1 \
    && test "$(readlink /opt/cloudandx/native-aemu/lib64/vulkan/libvulkan.so.1)" = libvulkan.so.1.4.344 \
    && test -L /opt/cloudandx/native-aemu/lib64/vulkan/libvulkan.so \
    && test "$(readlink /opt/cloudandx/native-aemu/lib64/vulkan/libvulkan.so)" = libvulkan.so.1 \
    && test -s /opt/cloudandx/native-aemu/lib64/vulkan/libvk_swiftshader.so \
    && test -s /opt/cloudandx/native-aemu/lib64/vulkan/vk_swiftshader_icd.json \
    && grep -Fq '"library_path": "./libvk_swiftshader.so"' \
      /opt/cloudandx/native-aemu/lib64/vulkan/vk_swiftshader_icd.json \
    && test -x /opt/cloudandx/native-aemu/vulkan-smoke \
    && test -f /opt/cloudandx/novnc/vnc.html \
    && novnc_version=$(python3 -c 'import json; print(json.load(open("/opt/cloudandx/novnc/package.json"))["version"])') \
    && test "${novnc_version}" = "${NOVNC_VERSION}" \
    && websockify_version=$(python3 -c 'import importlib.metadata; print(importlib.metadata.version("websockify"))') \
    && printf '%s\n' "${websockify_version}" \
    && printf '%s\n' "${websockify_version}" | grep -Fq "${WEBSOCKIFY_VERSION}" \
    && scrcpy_version=$(/opt/cloudandx/scrcpy/scrcpy --version 2>&1) \
    && printf '%s\n' "${scrcpy_version}" \
    && printf '%s\n' "${scrcpy_version}" | grep -Fq "scrcpy ${SCRCPY_VERSION}" \
    && test -s /opt/cloudandx/scrcpy/scrcpy-server \
    && test -d /opt/android-sdk/emulator/resources \
    && test -d /opt/cloudandx/native-aemu/resources \
    && for resource_dir in macros macroPreviews; do \
      test -d "/opt/android-sdk/emulator/resources/${resource_dir}"; \
      test ! -e "/opt/cloudandx/native-aemu/resources/${resource_dir}"; \
      cp -a "/opt/android-sdk/emulator/resources/${resource_dir}" \
        /opt/cloudandx/native-aemu/resources/; \
    done \
    && (cd /opt/cloudandx/native-aemu \
      && find resources/macros resources/macroPreviews -type f -print | LC_ALL=C sort \
        | while IFS= read -r resource_file; do sha256sum "${resource_file}"; done \
        > sdk-resources.SHA256SUMS \
      && test -s sdk-resources.SHA256SUMS \
      && sha256sum -c sdk-resources.SHA256SUMS) \
    && chmod -R a-w /opt/android-sdk /opt/android-avd-template \
      /opt/cloudandx/dist /opt/cloudandx/novnc /opt/cloudandx/scrcpy \
      /opt/cloudandx/android-ramdisk \
      /opt/cloudandx/native-aemu \
    && test -x /opt/android-sdk/emulator/emulator \
    && test -x /opt/android-sdk/platform-tools/adb \
    && test -x /opt/cloudandx/native-aemu/bin/run-qemu-system-aarch64-headless \
    && test -s /opt/android-sdk/system-images/android-37.0/google_apis_playstore_ps16k/arm64-v8a/system.img

ENV ANDROID_SDK_ROOT=/opt/android-sdk \
    ANDROID_HOME=/opt/android-sdk \
    ANDROID_AVD_HOME=/data/avd \
    ANDROID_EMULATOR_HOME=/data/emulator-home \
    ANDROID_PREFS_ROOT=/data/prefs \
    HOME=/data/home \
    PATH=/opt/android-sdk/emulator:/opt/android-sdk/platform-tools:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    AVD_NAME=Pixel_9_Android_17_Play_ARM64 \
    EMULATOR_ACCEL=auto \
    EMULATOR_CORES=8 \
    EMULATOR_MEMORY_MB=4096 \
    EMULATOR_GPU=swiftshader \
    EMULATOR_CONSOLE_PORT=5556 \
    EMULATOR_CONSOLE_SOCKET=/run/emulator-console/console.sock \
    EMULATOR_CONSOLE_AUTH_TOKEN_FILE=/run/bridge-secrets/token \
    EMULATOR_ADB_PORT=5557 \
    ADB_PROXY_PORT=5555 \
    EMULATOR_GRPC_INTERNAL_PORT=8556 \
    EMULATOR_GRPC_PORT=8554 \
    EMULATOR_WIPE_DATA=0 \
    ANDROID_RUNTIME_IMPLEMENTATION=hybrid-aemu-arm64 \
    NATIVE_AEMU_ROOT=/opt/cloudandx/native-aemu \
    NOVNC_VERSION=${NOVNC_VERSION} \
    NOVNC_ROOT=/opt/cloudandx/novnc \
    NOVNC_PORT=6080 \
    VNC_PORT=5900 \
    SCRCPY_VERSION=${SCRCPY_VERSION} \
    SCRCPY_ROOT=/opt/cloudandx/scrcpy \
    SCRCPY_SERIAL=emulator-5556 \
    SCRCPY_RETRY_DELAY_SECONDS=2 \
    NATIVE_AEMU_REVISION=${NATIVE_AEMU_REVISION} \
    NATIVE_AEMU_SOURCE_LOCK_SHA256=${NATIVE_AEMU_SOURCE_LOCK_SHA256} \
    NATIVE_AEMU_PATCH_SET_SHA256=${NATIVE_AEMU_PATCH_SET_SHA256} \
    ANDROID_RAMDISK_ROOT=/opt/cloudandx/android-ramdisk \
    ANDROID_RAMDISK_ORIGINAL_SHA256=${ANDROID_RAMDISK_ORIGINAL_SHA256} \
    ANDROID_RAMDISK_CPIO_SHA256=${ANDROID_RAMDISK_CPIO_SHA256} \
    ANDROID_RAMDISK_DERIVED_SHA256=${ANDROID_RAMDISK_DERIVED_SHA256} \
    ANDROID_RAMDISK_OVERLAY_PATH=${ANDROID_RAMDISK_OVERLAY_PATH} \
    EXPECTED_HW_TIMEOUT_MULTIPLIER=${ANDROID_HW_TIMEOUT_MULTIPLIER} \
    EXPECTED_FINALIZER_TIMEOUT_MS=${ANDROID_FINALIZER_TIMEOUT_MS} \
    EXPECTED_BLUETOOTH_HCI_TIMEOUT_MS=${ANDROID_BLUETOOTH_HCI_TIMEOUT_MS} \
    EXPECTED_BLUETOOTH_HCI_RESTART_TIMEOUT_MS=${ANDROID_BLUETOOTH_HCI_RESTART_TIMEOUT_MS} \
    ADB_MDNS_OPENSCREEN=0 \
    DISPLAY=:0 \
    XVFB_SCREEN=0 \
    XVFB_RESOLUTION=1080x2424x24

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/opt/cloudandx/evidence-gate/src \
    CONTRACTS_DIR=/contracts \
    PREFLIGHT_OUTPUT=/evidence/preflight.json

USER android:android
WORKDIR /data
VOLUME ["/data"]
EXPOSE 5555/tcp 6080/tcp 8090/tcp 8554/tcp

HEALTHCHECK --start-period=60m --start-interval=1m --interval=10m --timeout=5m --retries=10 \
  CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/usr/local/bin/single-container-entrypoint.sh"]
