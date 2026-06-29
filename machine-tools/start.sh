#!/usr/bin/env bash
set -u

MACHINE_TOOLS_LOG_NAME=start
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/lib.sh"

machine_tools_log "starting machine-tools services"
failed=0
"${SCRIPT_DIR}/start-ssh.sh" || failed=1
"${SCRIPT_DIR}/start-tailscale.sh" || failed=1
if [ "${failed}" -eq 0 ]; then
  machine_tools_log "finished starting machine-tools services"
else
  machine_tools_log "finished starting machine-tools services with failures"
fi
exit "${failed}"
