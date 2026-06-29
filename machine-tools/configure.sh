#!/usr/bin/env bash
set -euo pipefail

MACHINE_TOOLS_LOG_NAME=configure
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/lib.sh"

PUBLIC_KEYS=()
AUTH_KEY=""
HOSTNAME=""

usage() {
  cat >&2 <<USAGE
Usage: $0 --tailscale-auth-key AUTH_KEY [--tailscale-hostname HOSTNAME] [--ssh-public-keys KEY_OR_FILE[,KEY_OR_FILE...]]

Runs all machine-tools configure scripts.
USAGE
}

add_public_key_arg() {
  local value item
  value="$1"
  IFS=',' read -r -a items <<< "${value}"
  for item in "${items[@]}"; do
    if [ -n "${item}" ]; then
      PUBLIC_KEYS+=("${item}")
    fi
  done
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --ssh-public-keys)
      if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
        machine_tools_log "ERROR: --ssh-public-keys requires a value"
        usage
        exit 2
      fi
      add_public_key_arg "$2"
      shift 2
      ;;
    --tailscale-auth-key)
      if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
        machine_tools_log "ERROR: --tailscale-auth-key requires a value"
        usage
        exit 2
      fi
      AUTH_KEY="$2"
      shift 2
      ;;
    --tailscale-hostname)
      if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
        machine_tools_log "ERROR: --tailscale-hostname requires a value"
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
  machine_tools_log "ERROR: --tailscale-auth-key is required"
  usage
  exit 2
fi

ssh_args=()
for key in "${PUBLIC_KEYS[@]}"; do
  ssh_args+=(--public-keys "${key}")
done

"${SCRIPT_DIR}/configure-ssh.sh" "${ssh_args[@]}"

tailscale_args=(--auth-key "${AUTH_KEY}")
if [ -n "${HOSTNAME}" ]; then
  tailscale_args+=(--hostname "${HOSTNAME}")
fi
"${SCRIPT_DIR}/configure-tailscale.sh" "${tailscale_args[@]}"
machine_tools_log "configuration complete"
