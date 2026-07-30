#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "${ROOT}"
if [ -n "${DOCKER_CONTEXT:-}" ]; then
  export DOCKER_CONTEXT
fi

container=$(docker compose ps -q android)
[ -n "${container}" ]
[ "$(docker compose ps -q | wc -l | tr -d ' ')" -eq 1 ]
[ "$(docker inspect --format '{{.State.Health.Status}}' "${container}")" = healthy ]

[ "$(docker compose exec -T android /system/bin/getprop ro.build.version.release | tr -d '\r')" = 16 ]
[ "$(docker compose exec -T android /system/bin/getprop ro.build.version.sdk | tr -d '\r')" = 36 ]
[ "$(docker compose exec -T android /system/bin/getprop sys.boot_completed | tr -d '\r')" = 1 ]
docker compose exec -T android /system/bin/service check SurfaceFlinger 2>&1 |
  grep -Fq 'found'
docker compose exec -T android /system/bin/test -f \
  /data/runtime/scrcpy-first-frame.ready

curl --noproxy '*' --fail --silent --show-error --insecure --max-time 5 \
  --output /dev/null https://127.0.0.1:6080/vnc.html
if curl --noproxy '*' --silent --max-time 5 \
  http://127.0.0.1:6080/vnc.html >/dev/null 2>&1; then
  echo 'FAIL: noVNC accepted plaintext HTTP' >&2
  exit 1
fi
curl --noproxy '*' --fail --silent --show-error --max-time 5 \
  http://127.0.0.1:8090/livez | grep -Fq '"alive":true'
curl --noproxy '*' --fail --silent --show-error --max-time 30 \
  http://127.0.0.1:8090/healthz | grep -Fq '"ready":true'

unauthorized=$(curl --noproxy '*' --silent --output /dev/null \
  --write-out '%{http_code}' --request POST \
  --header 'Content-Type: application/json' --data '{"keycode":3}' \
  http://127.0.0.1:8090/v1/input/keyevent)
[ "${unauthorized}" = 401 ]

token=$(docker compose exec -T android /system/bin/cat \
  /data/runtime/bridge/token | tr -d '\r\n')
authorized=$(curl --noproxy '*' --silent --output /dev/null \
  --write-out '%{http_code}' --request POST \
  --header "Authorization: Bearer ${token}" \
  --header 'Content-Type: application/json' --data '{"keycode":3}' \
  http://127.0.0.1:8090/v1/input/keyevent)
unset token
[ "${authorized}" = 200 ]

echo 'redroid runtime smoke test: PASS'
