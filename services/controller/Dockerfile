# syntax=docker/dockerfile:1
FROM golang:1.23-bookworm AS build

WORKDIR /src
COPY go.mod ./
COPY *.go ./

RUN CGO_ENABLED=0 GOOS=linux go test ./... \
    && CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/controller . \
    && mkdir -p /out/data \
    && chown 65532:65532 /out/data

FROM scratch

COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=build --chown=65532:65532 /out/controller /controller
COPY --from=build --chown=65532:65532 /out/data /data

USER 65532:65532
ENV LISTEN_ADDRESS=:8080 \
    DATA_DIR=/data \
    ANDROID_VERSION=17 \
    API_LEVEL=37 \
    SYSTEM_IMAGE_KIND=google_apis_playstore_ps16k \
    KVM_AVAILABLE=false \
    RUNTIME_MODE=registry_only \
    MAX_ACTIVE_SESSIONS=1 \
    PREFLIGHT_EVIDENCE_FILE=

VOLUME ["/data"]
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 CMD ["/controller", "healthcheck"]

ENTRYPOINT ["/controller"]
