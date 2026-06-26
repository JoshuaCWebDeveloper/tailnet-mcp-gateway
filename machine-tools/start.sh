#!/usr/bin/env bash
set -u

MACHINE_TOOLS_LOG_NAME=start
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/lib.sh"

failed=0
"${SCRIPT_DIR}/start-ssh.sh" || failed=1
"${SCRIPT_DIR}/start-tailscale.sh" || failed=1
exit "${failed}"
