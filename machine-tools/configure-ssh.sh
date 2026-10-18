#!/usr/bin/env bash
set -euo pipefail

MACHINE_TOOLS_LOG_NAME=configure-ssh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SSH_KEY_DIRS=("${SCRIPT_DIR}/ssh" "${PROJECT_DIR}/ssh")
. "${SCRIPT_DIR}/lib.sh"

PUBLIC_KEYS=()
TARGET_USER=""
TARGET_HOME=""

usage() {
  cat >&2 <<USAGE
Usage: $0 [--user USER] [--home HOME] [--public-keys KEY_OR_FILE[,KEY_OR_FILE...]] [--public-keys KEY_OR_FILE ...]

Creates ~/.ssh and writes authorized_keys.

When --user is omitted, the PID 1 process user is used.
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
    --user)
      if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
        machine_tools_log "ERROR: --user requires a value"
        usage
        exit 2
      fi
      TARGET_USER="$2"
      shift 2
      ;;
    --home)
      if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
        machine_tools_log "ERROR: --home requires a value"
        usage
        exit 2
      fi
      TARGET_HOME="$2"
      shift 2
      ;;
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

detect_default_user_from_pid1() {
  TARGET_USER="$(ps -o user= -p 1 2>/dev/null | awk '{print $1; exit}' || true)"
  if [ -z "${TARGET_USER}" ]; then
    return 1
  fi

  if command -v getent >/dev/null 2>&1; then
    TARGET_HOME="$(getent passwd "${TARGET_USER}" | cut -d: -f6 || true)"
  fi
}

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

if [ -z "${TARGET_USER}" ]; then
  detect_default_user_from_pid1 || TARGET_USER="$(id -un 2>/dev/null || id -u)"
fi

if [ -z "${TARGET_HOME}" ]; then
  if command -v getent >/dev/null 2>&1; then
    TARGET_HOME="$(getent passwd "${TARGET_USER}" | cut -d: -f6 || true)"
  fi
fi

if [ -z "${TARGET_HOME}" ]; then
  if [ "${TARGET_USER}" = "$(id -un 2>/dev/null || id -u)" ]; then
    TARGET_HOME="${HOME}"
  else
    machine_tools_log "ERROR: could not determine home directory for ${TARGET_USER}; pass --home"
    exit 1
  fi
fi

# OpenSSH StrictModes also examines the home directory and its ancestors.
# Do not change ownership of the home directory: Frappe and other applications
# may deliberately rely on its existing owner and group.
TARGET_HOME="${TARGET_HOME%/}"
if [ -z "${TARGET_HOME}" ] || [ ! -d "${TARGET_HOME}" ]; then
  machine_tools_log "ERROR: target home directory does not exist: ${TARGET_HOME}"
  exit 1
fi

# Secure the target user's home without altering its group or other permissions.
# Group/world write access permits unauthorized manipulation of .ssh.

# Refuse unsafe ancestors rather than silently modifying system-wide directories.
target_uid="$(id -u "${TARGET_USER}")"
path="${TARGET_HOME}"
while :; do
  path_uid="$(stat -c %u "${path}")"
  path_mode="$(stat -c %a "${path}")"
  if [ "${path_uid}" != 0 ] && [ "${path_uid}" != "${target_uid}" ]; then
    machine_tools_log "ERROR: ${path} is not owned by root or ${TARGET_USER}"
    exit 1
  fi
  if [ "${path}" = "${TARGET_HOME}" ]; then
    machine_tools_as_root chmod go-w "${path}"
    path_mode="$(stat -c %a "${path}")"
  fi
  if (( (8#${path_mode} & 8#022) != 0 )); then
    machine_tools_log "ERROR: ${path} is group/world writable; cannot safely configure SSH keys"
    exit 1
  fi
  [ "${path}" = / ] && break
  path="$(dirname "${path}")"
done

ssh_dir="${TARGET_HOME}/.ssh"
authorized_keys="${ssh_dir}/authorized_keys"

machine_tools_as_root mkdir -p "${ssh_dir}"
machine_tools_as_root chmod 700 "${ssh_dir}"
machine_tools_as_root sh -c ': > "$1"' sh "${authorized_keys}"

for key in "${PUBLIC_KEYS[@]}"; do
  if [ -f "${key}" ]; then
    cat "${key}" | machine_tools_as_root tee -a "${authorized_keys}" >/dev/null
  else
    printf '%s\n' "${key}" | machine_tools_as_root tee -a "${authorized_keys}" >/dev/null
  fi
done

machine_tools_as_root chmod 600 "${authorized_keys}"
machine_tools_as_root chown -R "${TARGET_USER}:${TARGET_USER}" "${ssh_dir}" 2>/dev/null || machine_tools_as_root chown -R "${TARGET_USER}" "${ssh_dir}"
machine_tools_log "wrote ${#PUBLIC_KEYS[@]} public key source(s) to ${authorized_keys} for ${TARGET_USER}"
