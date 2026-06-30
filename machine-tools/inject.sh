#!/usr/bin/env bash
set -euo pipefail

MACHINE_TOOLS_LOG_NAME=inject
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/lib.sh"

TARGET=""
EXEC_PREFIX=""
CP_PREFIX=""
REMOTE_DIR="/tmp/machine-tools"
ENTRYPOINT_SCRIPT=""
ROOT_USER="root"
INSTALL_ARGS=()
CONFIGURE_ARGS=()
PUBLIC_KEYS=()
API_KEY=""
HOSTNAME=""
ROOT_RETRY_USED=0

usage() {
  cat >&2 <<USAGE
Usage: $0 [options] [-- install-args...]

Options:
  --target NAME              Container/pod name. Required.
  --exec-prefix COMMAND      Prefix before TARGET and the command run in the container.
                             Example: "docker exec"
                             Example: "kubectl exec"
  --cp-prefix COMMAND        Prefix before source/destination copy arguments.
                             Example: "docker cp"
                             Example: "kubectl cp"
  --remote-dir PATH          Destination directory in the container. Default: ${REMOTE_DIR}
  --entrypoint PATH          Entry point script to pass through to install.sh.
  --root-user USER           User to use for Docker exec retry. Default: ${ROOT_USER}
  --ssh-public-keys VALUE        SSH public key, public-key file, or comma-separated values.
  --tailscale-api-key VALUE            Tailscale API key used by configure.sh. Required.
  --tailscale-hostname VALUE           Tailscale hostname. Default: --target value.
  -h, --help                 Show this help.

Defaults:
  --exec-prefix "docker exec"
  --cp-prefix "docker cp"

The exec command is executed as:
  EXEC_PREFIX TARGET REMOTE_INSTALL_SCRIPT [install-args...]

If that fails and EXEC_PREFIX is exactly "docker exec", inject.sh retries as:
  docker exec --user ROOT_USER TARGET REMOTE_INSTALL_SCRIPT --install-setuid-start-helper [install-args...]

The copy command is executed as:
  CP_PREFIX LOCAL_MACHINE_TOOLS_DIR DESTINATION

DESTINATION defaults to:
  TARGET:${REMOTE_DIR}

Use a target value compatible with your exec/cp tool. For example, kubectl exec
often needs a command separator, so use --target "pod-name --" when appropriate.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --target)
      TARGET="${2:-}"
      shift 2
      ;;
    --exec-prefix)
      EXEC_PREFIX="${2:-}"
      shift 2
      ;;
    --cp-prefix)
      CP_PREFIX="${2:-}"
      shift 2
      ;;
    --remote-dir)
      REMOTE_DIR="${2:-}"
      shift 2
      ;;
    --entrypoint)
      ENTRYPOINT_SCRIPT="${2:-}"
      shift 2
      ;;
    --root-user)
      ROOT_USER="${2:-}"
      shift 2
      ;;
    --ssh-public-keys)
      PUBLIC_KEYS+=("${2:-}")
      shift 2
      ;;
    --tailscale-api-key)
      API_KEY="${2:-}"
      shift 2
      ;;
    --tailscale-hostname)
      HOSTNAME="${2:-}"
      shift 2
      ;;
    --)
      shift
      INSTALL_ARGS=("$@")
      break
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

if [ -n "${ENTRYPOINT_SCRIPT}" ]; then
  INSTALL_ARGS+=(--entrypoint "${ENTRYPOINT_SCRIPT}")
fi

if [ -z "${TARGET}" ]; then
  machine_tools_log "ERROR: provide --target"
  usage
  exit 2
fi

if [ -z "${API_KEY}" ]; then
  machine_tools_log "ERROR: provide --tailscale-api-key"
  usage
  exit 2
fi

if [ -z "${HOSTNAME}" ]; then
  HOSTNAME="${TARGET}"
fi

CONFIGURE_ARGS+=(--tailscale-api-key "${API_KEY}" --tailscale-hostname "${HOSTNAME}")
for key in "${PUBLIC_KEYS[@]}"; do
  CONFIGURE_ARGS+=(--ssh-public-keys "${key}")
done

if [ -z "${EXEC_PREFIX}" ]; then
  EXEC_PREFIX="docker exec"
fi

if [ -z "${CP_PREFIX}" ]; then
  CP_PREFIX="docker cp"
fi

copy_destination="${TARGET}:${REMOTE_DIR}"


validate_local_scripts() {
  if ! grep -Fq -- "--install-setuid-start-helper" "${SCRIPT_DIR}/install.sh"; then
    machine_tools_log "ERROR: local install.sh does not support --install-setuid-start-helper; update the whole machine-tools directory before running inject.sh"
    exit 1
  fi
  if [ ! -x "${SCRIPT_DIR}/configure.sh" ]; then
    machine_tools_log "ERROR: local configure.sh is missing or not executable; update the whole machine-tools directory before running inject.sh"
    exit 1
  fi
}


clear_remote_dir() {
  machine_tools_log "removing existing ${REMOTE_DIR} in container"
  # Intentionally split prefixes/target so callers can provide shell-style command fragments.
  # shellcheck disable=SC2086
  if ${EXEC_PREFIX} ${TARGET} rm -rf "${REMOTE_DIR}"; then
    return 0
  fi

  if [ "${EXEC_PREFIX}" != "docker exec" ]; then
    machine_tools_log "ERROR: failed to remove ${REMOTE_DIR}; root retry is only supported for the default Docker exec prefix"
    return 1
  fi

  machine_tools_log "failed to remove ${REMOTE_DIR}; retrying with docker exec --user ${ROOT_USER}"
  docker exec --user "${ROOT_USER}" ${TARGET} rm -rf "${REMOTE_DIR}"
}

run_copy() {
  machine_tools_log "copying ${SCRIPT_DIR} to ${copy_destination}"
  # Intentionally split prefixes/target so callers can provide shell-style command fragments.
  # shellcheck disable=SC2086
  ${CP_PREFIX} "${SCRIPT_DIR}" "${copy_destination}"
}


run_copy_ssh_dir() {
  local ssh_dir ssh_destination
  ssh_dir="$(cd "${SCRIPT_DIR}/.." && pwd)/ssh"
  ssh_destination="${TARGET}:${REMOTE_DIR}/ssh"

  if [ ! -d "${ssh_dir}" ]; then
    return 0
  fi

  machine_tools_log "copying ${ssh_dir} to ${ssh_destination}"
  # Intentionally split prefixes/target so callers can provide shell-style command fragments.
  # shellcheck disable=SC2086
  ${CP_PREFIX} "${ssh_dir}" "${ssh_destination}"
}

run_exec() {
  local description script_path
  description="$1"
  script_path="$2"
  shift 2

  machine_tools_log "running ${description} script in container"
  # Intentionally split prefixes/target so callers can provide shell-style command fragments.
  # shellcheck disable=SC2086
  ${EXEC_PREFIX} ${TARGET} "${script_path}" "$@"
}

run_exec_with_root_retry() {
  local description script_path
  description="$1"
  script_path="$2"
  shift 2

  if run_exec "${description}" "${script_path}" "$@"; then
    return 0
  fi

  if [ "${EXEC_PREFIX}" != "docker exec" ]; then
    machine_tools_log "ERROR: ${description} failed and root retry is only supported for the default Docker exec prefix"
    return 1
  fi

  machine_tools_log "${description} failed; retrying with docker exec --user ${ROOT_USER}"
  if [ "${description}" = "install" ]; then
    ROOT_RETRY_USED=1
    docker exec --user "${ROOT_USER}" ${TARGET} "${script_path}" --install-setuid-start-helper "$@"
  else
    docker exec --user "${ROOT_USER}" ${TARGET} "${script_path}" "$@"
  fi
}

validate_local_scripts
clear_remote_dir
run_copy
run_copy_ssh_dir
run_exec_with_root_retry install "${REMOTE_DIR}/install.sh" "${INSTALL_ARGS[@]}"
if [ "${ROOT_RETRY_USED}" -eq 1 ]; then
  machine_tools_log "install used root retry; running configure script with docker exec --user ${ROOT_USER}"
  docker exec --user "${ROOT_USER}" ${TARGET} "${REMOTE_DIR}/configure.sh" "${CONFIGURE_ARGS[@]}"
  machine_tools_log "install used root retry; running start script with docker exec --user ${ROOT_USER}"
  docker exec --user "${ROOT_USER}" ${TARGET} "${REMOTE_DIR}/start.sh"
else
  run_exec_with_root_retry configure "${REMOTE_DIR}/configure.sh" "${CONFIGURE_ARGS[@]}"
  run_exec_with_root_retry start "${REMOTE_DIR}/start.sh"
fi
