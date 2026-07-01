#!/usr/bin/env bash
set -euo pipefail

MACHINE_TOOLS_LOG_NAME=configure-tailscale
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/lib.sh"

API_KEY=""
HOSTNAME=""
TAILNET="-"
AUTH_KEY_EXPIRY_SECONDS="600"
TAILSCALE_API_BASE_URL="${TAILSCALE_API_BASE_URL:-https://api.tailscale.com/api/v2}"

usage() {
  cat >&2 <<USAGE
Usage: $0 --api-key API_KEY [--hostname HOSTNAME] [--tailnet TAILNET]

Configures Tailscale by deleting any existing same-hostname machine, generating a
one-time Tailscale auth key through the API, and running tailscale up with that
generated auth key.

TAILNET defaults to '-', which tells the Tailscale API to use the tailnet for the
provided API key.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --api-key)
      if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
        machine_tools_log "ERROR: --api-key requires a value"
        usage
        exit 2
      fi
      API_KEY="$2"
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
    --tailnet)
      if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
        machine_tools_log "ERROR: --tailnet requires a value"
        usage
        exit 2
      fi
      TAILNET="$2"
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

if [ -z "${API_KEY}" ]; then
  machine_tools_log "ERROR: --api-key is required"
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

if ! command -v curl >/dev/null 2>&1; then
  machine_tools_log "ERROR: curl is required to call the Tailscale API"
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  machine_tools_log "ERROR: python3 is required to parse Tailscale API responses"
  exit 1
fi

tailscale_api_url() {
  local path
  path="$1"
  printf '%s%s' "${TAILSCALE_API_BASE_URL}" "${path}"
}

tailscale_api_get() {
  local path
  path="$1"
  curl -fsS -u "${API_KEY}:" "$(tailscale_api_url "${path}")"
}

tailscale_api_delete() {
  local path
  path="$1"
  curl -fsS -X DELETE -u "${API_KEY}:" "$(tailscale_api_url "${path}")" >/dev/null
}

tailscale_api_post_json() {
  local path body
  path="$1"
  body="$2"
  curl -fsS -X POST \
    -u "${API_KEY}:" \
    -H 'Content-Type: application/json' \
    --data-binary "${body}" \
    "$(tailscale_api_url "${path}")"
}

list_matching_device_ids() {
  python3 -c '
import json, sys
hostname = sys.argv[1].strip().rstrip(".")
data = json.load(sys.stdin)
for device in data.get("devices", []):
    candidates = []
    for field in ("hostname", "name", "dnsName"):
        value = device.get(field)
        if isinstance(value, str):
            value = value.strip().rstrip(".")
            candidates.append(value)
            if "." in value:
                candidates.append(value.split(".", 1)[0])
    if hostname in candidates:
        device_id = device.get("id") or device.get("nodeId") or device.get("deviceId")
        if device_id:
            print(device_id)
' "${HOSTNAME}"
}

create_one_time_auth_key() {
  local body response
  body="$(python3 -c '
import json, sys
hostname = sys.argv[1]
expiry_seconds = int(sys.argv[2])
print(json.dumps({
    "capabilities": {
        "devices": {
            "create": {
                "reusable": False,
                "ephemeral": False,
                "preauthorized": True,
                "tags": [],
            }
        }
    },
    "expirySeconds": expiry_seconds,
    "description": f"one-time auth key for {hostname}",
}, separators=(",", ":")))
' "${HOSTNAME}" "${AUTH_KEY_EXPIRY_SECONDS}")"

  response="$(tailscale_api_post_json "/tailnet/${TAILNET}/keys" "${body}")"
  python3 -c '
import json, sys
key = json.load(sys.stdin).get("key")
if not key:
    raise SystemExit("Tailscale API did not return an auth key")
print(key)
' <<< "${response}"
}

machine_tools_log "removing existing tailscale machines with hostname=${HOSTNAME}"
device_ids="$(tailscale_api_get "/tailnet/${TAILNET}/devices" | list_matching_device_ids)"
if [ -n "${device_ids}" ]; then
  while IFS= read -r device_id; do
    [ -n "${device_id}" ] || continue
    machine_tools_log "deleting existing tailscale machine ${device_id} for hostname=${HOSTNAME}"
    tailscale_api_delete "/device/${device_id}"
  done <<< "${device_ids}"
else
  machine_tools_log "no existing tailscale machine found for hostname=${HOSTNAME}"
fi

machine_tools_log "creating one-time tailscale auth key for hostname=${HOSTNAME}"
AUTH_KEY="$(create_one_time_auth_key)"

machine_tools_log "ensuring tailscaled is running"
"${SCRIPT_DIR}/start-tailscale.sh"
machine_tools_log "configuring tailscale hostname=${HOSTNAME}"
machine_tools_as_root tailscale up --auth-key "${AUTH_KEY}" --hostname "${HOSTNAME}"
machine_tools_log "tailscale configuration complete"
