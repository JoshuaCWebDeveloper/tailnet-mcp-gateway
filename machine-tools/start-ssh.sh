#!/usr/bin/env bash
set -euo pipefail

MACHINE_TOOLS_LOG_NAME=start-ssh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/lib.sh"

if ! command -v ssh-keygen >/dev/null 2>&1; then
  machine_tools_log "ERROR: ssh-keygen is not installed; run install-ssh.sh first"
  exit 1
fi
if [ ! -x /usr/sbin/sshd ]; then
  machine_tools_log "ERROR: /usr/sbin/sshd is not installed; run install-ssh.sh first"
  exit 1
fi

machine_tools_as_root ssh-keygen -A
machine_tools_as_root mkdir -p /run/sshd

if pgrep -x sshd >/dev/null 2>&1; then
  machine_tools_log "sshd is already running"
  exit 0
fi

machine_tools_log "starting sshd"
machine_tools_as_root /usr/sbin/sshd
