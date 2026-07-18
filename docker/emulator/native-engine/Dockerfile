# syntax=docker/dockerfile:1.7

ARG BUILD_PLATFORM=linux/amd64
ARG BUNDLE_PLATFORM=linux/arm64
ARG BUILD_BASE=debian:bookworm-slim@sha256:7b140f374b289a7c2befc338f42ebe6441b7ea838a042bbd5acbfca6ec875818
ARG NATIVE_AEMU_REVISION
ARG NATIVE_AEMU_SOURCE_LOCK_SHA256
ARG NATIVE_AEMU_PATCH_SET_SHA256

FROM --platform=${BUILD_PLATFORM} ${BUILD_BASE} AS build-tools

ARG NATIVE_AEMU_REVISION
ARG NATIVE_AEMU_SOURCE_LOCK_SHA256
ARG NATIVE_AEMU_PATCH_SET_SHA256

RUN test -n "${NATIVE_AEMU_REVISION}" \
    && test "${#NATIVE_AEMU_SOURCE_LOCK_SHA256}" -eq 64 \
    && test "${#NATIVE_AEMU_PATCH_SET_SHA256}" -eq 64

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      binutils-aarch64-linux-gnu \
      build-essential \
      ca-certificates \
      cmake \
      crossbuild-essential-arm64 \
      curl \
      file \
      git \
      jq \
      ninja-build \
      patch \
      pkg-config \
      python3 \
      python3-dev \
      tar \
      xz-utils \
    && rm -rf /var/lib/apt/lists/*

ENV LC_ALL=C \
    SOURCE_DATE_EPOCH=0 \
    WORKSPACE=/workspace \
    BUILD_DIR=/out/build \
    BUNDLE_DIR=/out/bundle/opt/cloudandx/native-aemu

WORKDIR /native-engine

COPY sources.lock.json ./sources.lock.json
COPY patches/ ./patches/
COPY scripts/ ./scripts/
COPY bin/ ./bin/
COPY probes/ ./probes/

RUN chmod 0755 ./scripts/*.sh ./bin/run-qemu-system-x86_64-headless ./bin/netsimd \
    && ./scripts/fetch-sources.sh \
    && ./scripts/apply-patches.sh

RUN ./scripts/configure.sh \
    && ./scripts/build.sh \
    && ./scripts/build-vulkan.sh \
    && NATIVE_AEMU_REVISION=${NATIVE_AEMU_REVISION} \
       NATIVE_AEMU_SOURCE_LOCK_SHA256=${NATIVE_AEMU_SOURCE_LOCK_SHA256} \
       NATIVE_AEMU_PATCH_SET_SHA256=${NATIVE_AEMU_PATCH_SET_SHA256} \
       ./scripts/package-bundle.sh \
    && NATIVE_AEMU_REVISION=${NATIVE_AEMU_REVISION} \
       NATIVE_AEMU_SOURCE_LOCK_SHA256=${NATIVE_AEMU_SOURCE_LOCK_SHA256} \
       NATIVE_AEMU_PATCH_SET_SHA256=${NATIVE_AEMU_PATCH_SET_SHA256} \
       ./scripts/smoke-test-bundle.sh

FROM --platform=${BUNDLE_PLATFORM} ${BUILD_BASE} AS vulkan-smoke

COPY --from=build-tools /out/bundle/opt/cloudandx/native-aemu /opt/cloudandx/native-aemu

RUN probe_output=$(env -i \
      LD_LIBRARY_PATH=/opt/cloudandx/native-aemu/lib64 \
      VK_DRIVER_FILES=/opt/cloudandx/native-aemu/lib64/vulkan/vk_swiftshader_icd.json \
      VK_LOADER_DEBUG=error,warn \
      /opt/cloudandx/native-aemu/vulkan-smoke) \
    && printf '%s\n' "${probe_output}" \
    && printf '%s\n' "${probe_output}" | grep -Fq ' PASS'

FROM --platform=${BUNDLE_PLATFORM} scratch AS bundle

ARG NATIVE_AEMU_REVISION
ARG NATIVE_AEMU_SOURCE_LOCK_SHA256
ARG NATIVE_AEMU_PATCH_SET_SHA256

LABEL org.opencontainers.image.title="CloudAndX native AEMU engine bundle" \
      org.opencontainers.image.version="${NATIVE_AEMU_REVISION}" \
      io.cloudandx.native-aemu.revision="${NATIVE_AEMU_REVISION}" \
      io.cloudandx.native-aemu.mixed-arch-helper.netsimd="linux-x86_64/0.3.112" \
      io.cloudandx.native-aemu.vulkan-loader.commit="bac41319cafb4527a2a959237b17611dd08bfe11" \
      io.cloudandx.native-aemu.vulkan-swiftshader.commit="9a22bb9de00f5d8ddf4fc5ba5c2f425c2816e679" \
      io.cloudandx.native-aemu.source-lock-sha256="${NATIVE_AEMU_SOURCE_LOCK_SHA256}" \
      io.cloudandx.native-aemu.patch-set-sha256="${NATIVE_AEMU_PATCH_SET_SHA256}"

COPY --from=vulkan-smoke /opt/cloudandx/native-aemu /opt/cloudandx/native-aemu
