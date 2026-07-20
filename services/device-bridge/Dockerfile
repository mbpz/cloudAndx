# syntax=docker/dockerfile:1.7
FROM debian:bookworm-slim AS fetch

ARG PLATFORM_TOOLS_URL=https://dl.google.com/android/repository/platform-tools_r37.0.0-linux.zip
ARG PLATFORM_TOOLS_SHA1=bcf323933980a59dccc3f14c339aed5fb2171163

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl unzip \
    && rm -rf /var/lib/apt/lists/* \
    && curl --fail --location --retry 5 --output /tmp/platform-tools.zip "${PLATFORM_TOOLS_URL}" \
    && echo "${PLATFORM_TOOLS_SHA1}  /tmp/platform-tools.zip" | sha1sum --check --strict \
    && unzip -q /tmp/platform-tools.zip -d /opt \
    && rm /tmp/platform-tools.zip

FROM python:3.13.14-slim-bookworm@sha256:fcbd8dfc2605ba7c2eca646846c5e892b2931e41f6227985154a596f26ab8ed7 AS runtime-base

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates libstdc++6 libusb-1.0-0 \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 bridge \
    && useradd --uid 10001 --gid bridge --home-dir /home/bridge --create-home bridge

COPY --from=fetch /opt/platform-tools /opt/platform-tools
COPY --chown=bridge:bridge bridge.py /app/bridge.py

ENV ADB_PATH=/opt/platform-tools/adb \
    ADB_SERIAL=emulator:5555 \
    EMULATOR_CONSOLE_SOCKET=/run/emulator-console/console.sock \
    EMULATOR_CONSOLE_TIMEOUT_SECONDS=15 \
    ADB_READ_TIMEOUT_SECONDS=180 \
    RUNTIME_HEALTH_BUDGET_SECONDS=180 \
    LISTEN_HOST=0.0.0.0 \
    LISTEN_PORT=8090 \
    HOME=/home/bridge

USER bridge

FROM runtime-base AS test
COPY --chown=bridge:bridge tests /app/tests
RUN python3 -m unittest discover -s /app/tests -v
ENTRYPOINT ["python3", "-m", "unittest", "discover", "-s", "/app/tests", "-v"]

FROM runtime-base AS runtime
EXPOSE 8090
HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=4 \
  CMD ["python3", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8090/livez', timeout=3)"]
ENTRYPOINT ["python3", "/app/bridge.py"]
