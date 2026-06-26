#!/usr/bin/env bash
set -euo pipefail

MACHINE_TOOLS_LOG_NAME=install-ssh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/lib.sh"

machine_tools_log "installing OpenSSH server"
machine_tools_as_root apt update
machine_tools_as_root apt install -y openssh-server
machine_tools_as_root ssh-keygen -A
machine_tools_as_root mkdir -p /run/sshd
machine_tools_log "OpenSSH server installation complete"
