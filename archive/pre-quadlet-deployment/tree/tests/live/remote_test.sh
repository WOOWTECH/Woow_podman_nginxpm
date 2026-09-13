#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
if [[ ${RUN_LIVE_TESTS:-0} != 1 || ${RUN_REMOTE_LIVE_TESTS:-0} != 1 ]]; then echo 'SKIP: remote test requires RUN_LIVE_TESTS=1 and RUN_REMOTE_LIVE_TESTS=1 plus separate clients'; exit 0; fi
exec "$ROOT/scripts/verify-remote.sh"
