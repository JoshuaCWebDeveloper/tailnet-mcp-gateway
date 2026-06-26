#!/usr/bin/env bash
set -euo pipefail

MACHINE_TOOLS_LOG_NAME=inject
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/lib.sh"

TARGET=""
EXEC_PREFIX=""
CP_PREFIX=""
REMOTE_DIR="/tmp/machine-tools"
INSTALL_ARGS=()

usage() {
  cat >&2 <<USAGE
Usage: $0 [options] [-- install-args...]

Options:
  --target NAME              Container/pod name used by default docker prefixes.
  --exec-prefix COMMAND      Prefix before commands run in the container.
                             Example: "docker exec container-name"
                             Example: "kubectl exec pod-name --"
  --cp-prefix COMMAND        Prefix before source/destination copy arguments.
                             Example: "docker cp"
                             Example: "kubectl cp"
  --remote-dir PATH          Destination directory in the container. Default: ${REMOTE_DIR}
  -h, --help                 Show this help.

Defaults when --target is provided:
  --exec-prefix "docker exec TARGET"
  --cp-prefix "docker cp"

The copy command is executed as:
  CP_PREFIX LOCAL_MACHINE_TOOLS_DIR DESTINATION

For docker, DESTINATION defaults to:
  TARGET:${REMOTE_DIR}

For custom cp prefixes, pass a prefix whose destination syntax matches the tool.
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

if [ -z "${EXEC_PREFIX}" ]; then
  if [ -z "${TARGET}" ]; then
    machine_tools_log "ERROR: provide --target or --exec-prefix"
    usage
    exit 2
  fi
  EXEC_PREFIX="docker exec ${TARGET}"
fi

if [ -z "${CP_PREFIX}" ]; then
  CP_PREFIX="docker cp"
fi

copy_destination="${REMOTE_DIR}"
if [ -n "${TARGET}" ] && [ "${CP_PREFIX}" = "docker cp" ]; then
  copy_destination="${TARGET}:${REMOTE_DIR}"
fi

machine_tools_log "copying ${SCRIPT_DIR} to ${copy_destination}"
# Intentionally split prefixes so callers can provide shell-style command prefixes.
# shellcheck disable=SC2086
${CP_PREFIX} "${SCRIPT_DIR}" "${copy_destination}"

machine_tools_log "running install script in container"
# shellcheck disable=SC2086
${EXEC_PREFIX} "${REMOTE_DIR}/install.sh" "${INSTALL_ARGS[@]}"
