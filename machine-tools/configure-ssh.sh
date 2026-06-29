#!/usr/bin/env bash
set -euo pipefail

MACHINE_TOOLS_LOG_NAME=configure-ssh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SSH_KEY_DIRS=("${SCRIPT_DIR}/ssh" "${PROJECT_DIR}/ssh")
. "${SCRIPT_DIR}/lib.sh"

PUBLIC_KEYS=()

usage() {
  cat >&2 <<USAGE
Usage: $0 [--public-keys KEY_OR_FILE[,KEY_OR_FILE...]] [--public-keys KEY_OR_FILE ...]

Creates ~/.ssh and writes authorized_keys.

When --public-keys is omitted, all .pub files in ${SCRIPT_DIR}/ssh or ${PROJECT_DIR}/ssh are used.
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
    --public-keys)
      if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
        machine_tools_log "ERROR: --public-keys requires a value"
        usage
        exit 2
      fi
      add_public_key_arg "$2"
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

if [ "${#PUBLIC_KEYS[@]}" -eq 0 ]; then
  for key_dir in "${SSH_KEY_DIRS[@]}"; do
    if [ -d "${key_dir}" ]; then
      while IFS= read -r key_file; do
        PUBLIC_KEYS+=("${key_file}")
      done < <(find "${key_dir}" -maxdepth 1 -type f -name '*.pub' | sort)
    fi
  done
fi

if [ "${#PUBLIC_KEYS[@]}" -eq 0 ]; then
  machine_tools_log "ERROR: no public keys provided and no .pub files found in ${SSH_KEY_DIRS[*]}"
  exit 1
fi

ssh_dir="${HOME}/.ssh"
authorized_keys="${ssh_dir}/authorized_keys"

mkdir -p "${ssh_dir}"
chmod 700 "${ssh_dir}"
: > "${authorized_keys}"

for key in "${PUBLIC_KEYS[@]}"; do
  if [ -f "${key}" ]; then
    cat "${key}" >> "${authorized_keys}"
  else
    printf '%s\n' "${key}" >> "${authorized_keys}"
  fi
done

chmod 600 "${authorized_keys}"
machine_tools_log "wrote ${#PUBLIC_KEYS[@]} public key source(s) to ${authorized_keys}"
