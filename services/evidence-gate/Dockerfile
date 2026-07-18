FROM python:3.12.10-slim-bookworm@sha256:fd95fa221297a88e1cf49c55ec1828edd7c5a428187e67b5d1805692d11588db AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app/src \
    CONTRACTS_DIR=/contracts \
    PREFLIGHT_OUTPUT=/evidence/preflight.json

WORKDIR /app

COPY services/evidence-gate/requirements.txt /app/requirements.txt
RUN python -m pip install --no-cache-dir --disable-pip-version-check -r /app/requirements.txt

COPY services/evidence-gate/src /app/src

FROM base AS test
COPY services/evidence-gate/tests /app/tests
CMD ["python", "-m", "unittest", "discover", "-s", "/app/tests", "-v"]

FROM base AS runtime
RUN mkdir -p /evidence /contracts && chown -R 65532:65532 /evidence
USER 65532:65532
ENTRYPOINT ["python", "-m", "evidence_gate"]
CMD ["preflight"]
