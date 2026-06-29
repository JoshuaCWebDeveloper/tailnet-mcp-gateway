#!/usr/bin/env bash
set -euo pipefail

MACHINE_TOOLS_LOG_NAME=configure-tailscale
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/lib.sh"

AUTH_KEY=""
HOSTNAME=""

usage() {
  cat >&2 <<USAGE
Usage: $0 --auth-key AUTH_KEY [--hostname HOSTNAME]

Configures Tailscale by running tailscale up with the provided auth key and hostname.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --auth-key)
      if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
        machine_tools_log "ERROR: --auth-key requires a value"
        usage
        exit 2
      fi
      AUTH_KEY="$2"
      shift 2
      ;;
    --hostname)
      if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
        machine_tools_log "ERROR: --hostname requires a value"
        usage
        exit 2
      fi
      HOSTNAME="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      machine_tools_log "ERROR: unknown argument: $1"
      usage
      exit 2
      ;;
  esac
done

if [ -z "${AUTH_KEY}" ]; then
  machine_tools_log "ERROR: --auth-key is required"
  usage
  exit 2
fi

if [ -z "${HOSTNAME}" ]; then
  HOSTNAME="$(hostname)"
fi

if ! command -v tailscale >/dev/null 2>&1; then
  machine_tools_log "ERROR: tailscale is not installed; run install-tailscale.sh first"
  exit 1
fi

machine_tools_log "ensuring tailscaled is running"
"${SCRIPT_DIR}/start-tailscale.sh"
machine_tools_log "configuring tailscale hostname=${HOSTNAME}"
machine_tools_as_root tailscale up --auth-key "${AUTH_KEY}" --hostname "${HOSTNAME}"
machine_tools_log "tailscale configuration complete"
