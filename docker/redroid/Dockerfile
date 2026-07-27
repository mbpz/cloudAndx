ARG UI_BASE_IMAGE=debian:trixie-slim@sha256:020c0d20b9880058cbe785a9db107156c3c75c2ac944a6aa7ab59f2add76a7bd
ARG REDROID_BASE_IMAGE=redroid/redroid@sha256:7b1e389bd15f37af3bcd06138f5b2ffa7cfba4332bd5ef54c53e99c2f160a15b

FROM ${UI_BASE_IMAGE} AS ui-toolchain

ARG SCRCPY_VERSION=4.1
ARG SCRCPY_SOURCE_SHA256=537b2ade623cb94b6edddfa5c61bf0b0af21484aa8365ea2531b686ea573249a
ARG SCRCPY_SERVER_SHA256=deacb991ed2509715160ffdc7907e47b4160eb30d1566217e9047fd5b8850cae
ARG NOVNC_VERSION=1.7.0
ARG NOVNC_SHA256=b1003a11b6e6e8d8f7f5e5586daae7f8ca651d8aee0aa155ff9ac841c48f52c6
ARG WEBSOCKIFY_VERSION=0.13.0
ARG WEBSOCKIFY_SHA256=b6413e364efd04f3c92ec8c17747e3c4adc20157c2ef1c5d019a26d944a46df8

RUN sed -i \
      's|URIs: http://deb.debian.org/debian-security|URIs: http://mirrors.tuna.tsinghua.edu.cn/debian-security|; s|URIs: http://deb.debian.org/debian|URIs: http://mirrors.tuna.tsinghua.edu.cn/debian|' \
      /etc/apt/sources.list.d/debian.sources \
    && attempt=0; until apt-get update -o Acquire::http::Proxy=false \
      -o Acquire::https::Proxy=false -o Acquire::Retries=5; do \
      attempt=$((attempt + 1)); test "${attempt}" -lt 8; sleep 2; \
    done \
    && find /var/lib/apt/lists -type f -name '*_Packages*' -print -quit | grep -q . \
    && attempt=0; until DEBIAN_FRONTEND=noninteractive apt-get install -y --fix-missing \
        --no-install-recommends -o Acquire::http::Proxy=false \
        -o Acquire::https::Proxy=false -o Acquire::Retries=5 \
        adb build-essential ca-certificates curl fonts-dejavu-core \
        libavcodec-dev libavdevice-dev libavformat-dev libavutil-dev \
        libsdl3-dev libswresample-dev libusb-1.0-0-dev meson ninja-build \
        openssl pkg-config procps python3 python3-pip x11vnc xvfb; do \
      attempt=$((attempt + 1)); test "${attempt}" -lt 12; \
      DEBIAN_FRONTEND=noninteractive apt-get -f install -y --fix-missing \
        -o Acquire::http::Proxy=false -o Acquire::https::Proxy=false \
        -o Acquire::Retries=5 || true; sleep 2; \
    done \
    && rm -rf /var/lib/apt/lists/*

RUN set -eu; \
    curl --fail --location --retry 5 --retry-all-errors \
      --output /tmp/scrcpy.tar.gz \
      "https://github.com/Genymobile/scrcpy/archive/refs/tags/v${SCRCPY_VERSION}.tar.gz"; \
    echo "${SCRCPY_SOURCE_SHA256}  /tmp/scrcpy.tar.gz" | sha256sum --check --strict -; \
    curl --fail --location --retry 5 --retry-all-errors \
      --output /tmp/scrcpy-server \
      "https://github.com/Genymobile/scrcpy/releases/download/v${SCRCPY_VERSION}/scrcpy-server-v${SCRCPY_VERSION}"; \
    echo "${SCRCPY_SERVER_SHA256}  /tmp/scrcpy-server" | sha256sum --check --strict -; \
    mkdir -p /tmp/scrcpy-src /opt/cloudandx/scrcpy; \
    tar -xzf /tmp/scrcpy.tar.gz -C /tmp/scrcpy-src --strip-components=1; \
    meson setup /tmp/scrcpy-build /tmp/scrcpy-src \
      --buildtype=release --strip -Db_lto=true -Dprebuilt_server=/tmp/scrcpy-server; \
    meson compile -C /tmp/scrcpy-build; \
    install -m 0555 /tmp/scrcpy-build/app/scrcpy /opt/cloudandx/scrcpy/scrcpy; \
    install -m 0444 /tmp/scrcpy-server /opt/cloudandx/scrcpy/scrcpy-server; \
    /opt/cloudandx/scrcpy/scrcpy --version | grep -F "scrcpy ${SCRCPY_VERSION}"; \
    rm -rf /tmp/scrcpy-src /tmp/scrcpy-build /tmp/scrcpy.tar.gz /tmp/scrcpy-server

RUN set -eu; \
    curl --fail --location --retry 5 --retry-all-errors \
      --output /tmp/novnc.tar.gz \
      "https://github.com/novnc/noVNC/archive/refs/tags/v${NOVNC_VERSION}.tar.gz"; \
    echo "${NOVNC_SHA256}  /tmp/novnc.tar.gz" | sha256sum --check --strict -; \
    mkdir -p /opt/cloudandx; \
    tar -xzf /tmp/novnc.tar.gz -C /opt/cloudandx; \
    mv "/opt/cloudandx/noVNC-${NOVNC_VERSION}" /opt/cloudandx/novnc; \
    ln -s vnc.html /opt/cloudandx/novnc/index.html; \
    curl --fail --location --retry 5 --retry-all-errors \
      --output /tmp/websockify.tar.gz \
      "https://github.com/novnc/websockify/archive/refs/tags/v${WEBSOCKIFY_VERSION}.tar.gz"; \
    echo "${WEBSOCKIFY_SHA256}  /tmp/websockify.tar.gz" | sha256sum --check --strict -; \
    python3 -m pip install --break-system-packages --no-cache-dir \
      /tmp/websockify.tar.gz; \
    websockify_version=$(python3 -c 'import importlib.metadata; print(importlib.metadata.version("websockify"))'); \
    test "${websockify_version}" = "${WEBSOCKIFY_VERSION}"; \
    rm -f /tmp/novnc.tar.gz /tmp/websockify.tar.gz

COPY docker/emulator/novnc/mandatory.json /opt/cloudandx/novnc/mandatory.json
COPY docker/emulator/novnc/cloudandx.css /opt/cloudandx/novnc/app/styles/cloudandx.css
COPY docker/emulator/novnc/cloudandx-touch.js /opt/cloudandx/novnc/app/cloudandx-touch.js

RUN sed -i '/app\/styles\/base.css/a\    <link rel="stylesheet" href="app/styles/cloudandx.css">' \
      /opt/cloudandx/novnc/vnc.html \
    && sed -i '/<\/body>/i\    <script type="module" src="app/cloudandx-touch.js"><\/script>' \
      /opt/cloudandx/novnc/vnc.html \
    && mkdir -p /usr/local/share/icons/hicolor/256x256/apps \
    && cp /usr/share/pixmaps/debian-logo.png \
      /usr/local/share/icons/hicolor/256x256/apps/scrcpy.png \
    && test -x /usr/bin/Xvfb \
    && test -x /usr/bin/x11vnc \
    && test -x /usr/local/bin/websockify \
    && test -s /opt/cloudandx/scrcpy/scrcpy-server \
    && test -f /opt/cloudandx/novnc/vnc.html

FROM ${REDROID_BASE_IMAGE} AS runtime

ARG SCRCPY_VERSION=4.1
ARG NOVNC_VERSION=1.7.0
ARG WEBSOCKIFY_VERSION=0.13.0

# ReDroid owns /system and Android init. Linux UI tools live only under /usr,
# /lib and /opt, which are unused by the Android rootfs before this overlay.
COPY --from=ui-toolchain /usr/ /usr/
COPY --from=ui-toolchain /lib/ /lib/
COPY --from=ui-toolchain /etc/alternatives/ /etc/alternatives/
COPY --from=ui-toolchain /etc/ssl/ /etc/ssl/
COPY --from=ui-toolchain /opt/cloudandx/ /opt/cloudandx/
COPY services/device-bridge/bridge.py /opt/cloudandx/device-bridge/bridge.py
COPY --chmod=0555 docker/redroid/bin/container-entrypoint.sh /opt/cloudandx/bin/container-entrypoint.sh
COPY --chmod=0555 docker/redroid/bin/ui-supervisor.sh /opt/cloudandx/bin/ui-supervisor.sh
COPY --chmod=0555 docker/redroid/bin/healthcheck.sh /opt/cloudandx/bin/healthcheck.sh

ENV DISPLAY=:0 \
    ANDROID_ADB_SERIAL=127.0.0.1:5555 \
    NOVNC_PORT=6080 \
    VNC_PORT=5900 \
    NOVNC_TLS=true \
    SCRCPY_VERSION=${SCRCPY_VERSION} \
    NOVNC_VERSION=${NOVNC_VERSION} \
    WEBSOCKIFY_VERSION=${WEBSOCKIFY_VERSION} \
    SCRCPY_READY_FILE=/data/runtime/scrcpy-first-frame.ready

EXPOSE 5555/tcp 6080/tcp 8090/tcp

HEALTHCHECK --start-period=60s --start-interval=2s --interval=10s --timeout=5s --retries=6 \
  CMD ["/usr/bin/dash", "/opt/cloudandx/bin/healthcheck.sh"]

ENTRYPOINT ["/usr/bin/dash", "/opt/cloudandx/bin/container-entrypoint.sh"]
CMD ["qemu=1", "androidboot.hardware=redroid"]
