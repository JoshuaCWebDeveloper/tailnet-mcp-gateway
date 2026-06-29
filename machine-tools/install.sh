#!/usr/bin/env bash
set -euo pipefail

MACHINE_TOOLS_LOG_NAME=install
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
START_SCRIPT_DEST=/usr/local/bin/machine-tools-start.sh
START_SCRIPT_LIB_DIR=/usr/local/lib/machine-tools
START_USER="$(id -un 2>/dev/null || id -u)"
ENTRYPOINT_SCRIPT=""
INSTALL_PRIV_START_HELPER=0
. "${SCRIPT_DIR}/lib.sh"

usage() {
  cat >&2 <<USAGE
Usage: $0 [--entrypoint /path/to/entrypoint-script] [--install-setuid-start-helper]

Runs all machine-tools install scripts, installs the global start script at
${START_SCRIPT_DEST}, and configures it to run on container start as the same
user that ran install.sh: ${START_USER}.

When --install-setuid-start-helper is used, install.sh configures passwordless sudo for the root-owned global start script so a non-root entrypoint can start root-owned services.

Startup configuration order:
  1. Supervisor, if detected.
  2. Explicit --entrypoint script patch.
  3. Error if neither is available.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --entrypoint)
      if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
        machine_tools_log "ERROR: --entrypoint requires a path"
        usage
        exit 2
      fi
      ENTRYPOINT_SCRIPT="$2"
      shift 2
      ;;
    --install-setuid-start-helper)
      INSTALL_PRIV_START_HELPER=1
      shift
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

install_start_script() {
  machine_tools_as_root mkdir -p "${START_SCRIPT_LIB_DIR}"
  machine_tools_as_root install -m 0755 "${SCRIPT_DIR}/start.sh" "${START_SCRIPT_LIB_DIR}/start.sh"
  machine_tools_as_root install -m 0755 "${SCRIPT_DIR}/start-ssh.sh" "${START_SCRIPT_LIB_DIR}/start-ssh.sh"
  machine_tools_as_root install -m 0755 "${SCRIPT_DIR}/start-tailscale.sh" "${START_SCRIPT_LIB_DIR}/start-tailscale.sh"
  machine_tools_as_root install -m 0644 "${SCRIPT_DIR}/lib.sh" "${START_SCRIPT_LIB_DIR}/lib.sh"
  printf '#!/usr/bin/env bash
exec %s/start.sh "$@"
' "${START_SCRIPT_LIB_DIR}" | machine_tools_as_root tee "${START_SCRIPT_DEST}" >/dev/null
  machine_tools_as_root chmod 0755 "${START_SCRIPT_DEST}"
  machine_tools_as_root chown root:root "${START_SCRIPT_DEST}" 2>/dev/null || true
}

install_priv_start_helper() {
  local sudoers_file
  sudoers_file=/etc/sudoers.d/machine-tools-start

  if ! command -v sudo >/dev/null 2>&1; then
    machine_tools_log "sudo not found; installing sudo for entrypoint startup helper"
    machine_tools_as_root apt update
    machine_tools_as_root apt install -y sudo
  fi

  machine_tools_as_root chown root:root "${START_SCRIPT_DEST}" 2>/dev/null || true
  machine_tools_as_root chmod 0755 "${START_SCRIPT_DEST}"
  printf 'ALL ALL=(root) NOPASSWD: %s\n' "${START_SCRIPT_DEST}" | machine_tools_as_root tee "${sudoers_file}" >/dev/null
  machine_tools_as_root chmod 0440 "${sudoers_file}"

  if command -v visudo >/dev/null 2>&1; then
    machine_tools_as_root visudo -cf "${sudoers_file}"
  fi

  machine_tools_log "configured passwordless sudo startup helper for ${START_SCRIPT_DEST}"
}

configure_supervisor() {
  local conf_dir conf_file
  if ! command -v supervisord >/dev/null 2>&1 && ! command -v supervisorctl >/dev/null 2>&1; then
    return 1
  fi

  if [ -d /etc/supervisor/conf.d ]; then
    conf_dir=/etc/supervisor/conf.d
  elif [ -d /etc/supervisord.d ]; then
    conf_dir=/etc/supervisord.d
  else
    return 1
  fi

  conf_file="${conf_dir}/machine-tools-start.conf"
  machine_tools_log "configuring Supervisor startup at ${conf_file} for user ${START_USER}"
  machine_tools_as_root tee "${conf_file}" >/dev/null <<SUPERVISOR
[program:machine-tools-start]
command=${START_SCRIPT_DEST}
user=${START_USER}
autostart=true
autorestart=false
startsecs=0
stdout_logfile=/tmp/machine-tools-start-supervisor.log
stderr_logfile=/tmp/machine-tools-start-supervisor.err
SUPERVISOR

  if command -v supervisorctl >/dev/null 2>&1; then
    machine_tools_as_root supervisorctl reread || true
    machine_tools_as_root supervisorctl update || true
    machine_tools_as_root supervisorctl start machine-tools-start || true
  fi
  return 0
}

patch_entrypoint() {
  local marker line tmp
  marker="# machine-tools startup hook"
  if [ "${INSTALL_PRIV_START_HELPER}" -eq 1 ]; then
    line="if command -v sudo >/dev/null 2>&1; then sudo -n ${START_SCRIPT_DEST} || true; elif [ -x ${START_SCRIPT_DEST} ]; then ${START_SCRIPT_DEST} || true; fi"
  else
    line="if [ -x ${START_SCRIPT_DEST} ]; then ${START_SCRIPT_DEST} || true; fi"
  fi

  if [ -z "${ENTRYPOINT_SCRIPT}" ]; then
    return 1
  fi
  if [ ! -f "${ENTRYPOINT_SCRIPT}" ]; then
    machine_tools_log "ERROR: entrypoint script does not exist: ${ENTRYPOINT_SCRIPT}"
    exit 1
  fi
  tmp="$(mktemp)"
  if grep -Fq "${marker}" "${ENTRYPOINT_SCRIPT}"; then
    machine_tools_log "entrypoint already contains startup hook; updating hook command in ${ENTRYPOINT_SCRIPT}"
    awk -v marker="${marker}" -v line="${line}" '
      $0 == marker { print; print line; getline; next }
      { print }
    ' "${ENTRYPOINT_SCRIPT}" > "${tmp}"
  elif head -n 1 "${ENTRYPOINT_SCRIPT}" | grep -q '^#!'; then
    {
      head -n 1 "${ENTRYPOINT_SCRIPT}"
      printf '%s\n%s\n' "${marker}" "${line}"
      tail -n +2 "${ENTRYPOINT_SCRIPT}"
    } > "${tmp}"
  else
    {
      printf '%s\n%s\n' "${marker}" "${line}"
      cat "${ENTRYPOINT_SCRIPT}"
    } > "${tmp}"
  fi

  chmod --reference="${ENTRYPOINT_SCRIPT}" "${tmp}" 2>/dev/null || chmod +x "${tmp}"
  machine_tools_as_root cp "${tmp}" "${ENTRYPOINT_SCRIPT}"
  rm -f "${tmp}"
  machine_tools_log "patched entrypoint startup hook into ${ENTRYPOINT_SCRIPT}"
}

configure_startup() {
  if configure_supervisor; then
    machine_tools_log "configured startup through Supervisor"
    return 0
  fi
  if patch_entrypoint; then
    machine_tools_log "configured startup through entrypoint patch"
    return 0
  fi

  machine_tools_log "ERROR: could not configure startup: no supported process manager found and no --entrypoint script was provided"
  machine_tools_log "Run the start script manually with: ${START_SCRIPT_DEST}"
  exit 1
}

"${SCRIPT_DIR}/install-ssh.sh"
"${SCRIPT_DIR}/install-tailscale.sh"
install_start_script
if [ "${INSTALL_PRIV_START_HELPER}" -eq 1 ]; then
  install_priv_start_helper
fi
machine_tools_log "configuring start script to run as ${START_USER}"
configure_startup
machine_tools_log "installation complete"
