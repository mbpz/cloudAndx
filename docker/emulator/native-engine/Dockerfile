# syntax=docker/dockerfile:1.7

ARG BUILD_PLATFORM=linux/amd64
ARG BUNDLE_PLATFORM=linux/arm64
ARG BUILD_BASE=debian:bookworm-slim@sha256:7b140f374b289a7c2befc338f42ebe6441b7ea838a042bbd5acbfca6ec875818

FROM --platform=${BUILD_PLATFORM} ${BUILD_BASE} AS build-tools

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

RUN chmod 0755 ./scripts/*.sh ./bin/run-qemu-system-x86_64-headless \
    && ./scripts/fetch-sources.sh \
    && ./scripts/apply-patches.sh

RUN ./scripts/configure.sh \
    && ./scripts/build.sh \
    && ./scripts/package-bundle.sh \
    && ./scripts/smoke-test-bundle.sh

FROM --platform=${BUNDLE_PLATFORM} scratch AS bundle

COPY --from=build-tools /out/bundle/opt/cloudandx/native-aemu /opt/cloudandx/native-aemu
