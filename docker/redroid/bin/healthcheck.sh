#!/usr/bin/dash
set -eu

serial=${ANDROID_ADB_SERIAL:-127.0.0.1:5555}
ready=${SCRCPY_READY_FILE:-/data/runtime/scrcpy-first-frame.ready}

[ "$(/usr/bin/adb -s "${serial}" get-state 2>/dev/null)" = device ]
[ "$(/usr/bin/adb -s "${serial}" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]
[ -f "${ready}" ]
pid=$(cat /data/runtime/ui-supervisor.pid)
kill -0 "${pid}"
/usr/bin/curl --fail --silent --max-time 2 http://127.0.0.1:8090/livez >/dev/null
