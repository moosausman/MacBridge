#!/bin/bash
set -euo pipefail

APP_NAME="MacBridge"
PIDS="$(pgrep -x "${APP_NAME}" || true)"

if [ -z "${PIDS}" ]; then
    echo "MacBridge is not running."
    exit 0
fi

echo "Stopping MacBridge (${PIDS//$'\n'/, })..."
while IFS= read -r pid; do
    kill -INT "${pid}"
done <<<"${PIDS}"