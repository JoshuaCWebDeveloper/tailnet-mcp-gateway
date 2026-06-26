#!/usr/bin/env bash
set -euo pipefail

MACHINE_TOOLS_LOG_NAME=start-tailscale
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/lib.sh"

if ! command -v tailscaled >/dev/null 2>&1; then
  machine_tools_log "ERROR: tailscaled is not installed; run install-tailscale.sh first"
  exit 1
fi

machine_tools_as_root mkdir -p /var/lib/tailscale

if pgrep -x tailscaled >/dev/null 2>&1; then
  machine_tools_log "tailscaled is already running"
  exit 0
fi

machine_tools_log "starting tailscaled in userspace networking mode"
tailscaled_cmd=(
  tailscaled
  --tun=userspace-networking
  --socks5-server=127.0.0.1:1055
  --outbound-http-proxy-listen=127.0.0.1:1055
  --state=/var/lib/tailscale/tailscaled.state
)

if [ "$(id -u)" -ne 0 ]; then
  tailscaled_cmd=(sudo "${tailscaled_cmd[@]}")
fi

nohup "${tailscaled_cmd[@]}" > /tmp/tailscaled.log 2>&1 < /dev/null &
