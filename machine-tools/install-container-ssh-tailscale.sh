#!/usr/bin/env bash
set -euo pipefail

startup_src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/start-container-ssh-tailscale.sh"
startup_dest="/usr/local/bin/start-container-ssh-tailscale.sh"
entrypoint=""

log() { printf '[install-container-ssh-tailscale] %s\n' "$*" >&2; }

as_root() {
  if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
}

usage() {
  cat >&2 <<USAGE
Usage: $0 [--entrypoint /path/to/entrypoint-script]

Installs OpenSSH and Tailscale, installs ${startup_dest}, and configures it to
run on container start via Supervisor if available, otherwise by patching the
entrypoint script supplied with --entrypoint.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --entrypoint) entrypoint="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) log "ERROR: unknown argument: $1"; usage; exit 2 ;;
  esac
done

if [ "$(id -u)" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
  log "ERROR: root or sudo is required"
  exit 1
fi

install_ssh() {
  log "installing OpenSSH server"
  as_root apt update
  as_root apt install -y openssh-server
  as_root ssh-keygen -A
  as_root mkdir -p /run/sshd
}

install_tailscale_static() {
  local version arch tmp tgz url
  version="${TAILSCALE_STATIC_VERSION:-1.70.0}"
  case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    armv7l) arch=arm ;;
    *) log "ERROR: unsupported architecture for static Tailscale install: $(uname -m)"; exit 1 ;;
  esac

  command -v curl >/dev/null 2>&1 || as_root apt install -y curl ca-certificates
  command -v tar >/dev/null 2>&1 || as_root apt install -y tar

  tmp="$(mktemp -d)"
  tgz="$tmp/tailscale.tgz"
  url="https://pkgs.tailscale.com/stable/tailscale_${version}_${arch}.tgz"
  log "installing Tailscale static binaries from $url"
  curl -fsSL "$url" -o "$tgz"
  tar -xzf "$tgz" -C "$tmp"
  as_root install -m 0755 "$tmp"/tailscale_*/tailscale /usr/local/bin/tailscale
  as_root install -m 0755 "$tmp"/tailscale_*/tailscaled /usr/local/bin/tailscaled
  rm -rf "$tmp"
}

install_tailscale() {
  if command -v tailscale >/dev/null 2>&1 && command -v tailscaled >/dev/null 2>&1; then
    log "Tailscale is already installed"
    return 0
  fi

  command -v curl >/dev/null 2>&1 || as_root apt install -y curl ca-certificates

  log "installing Tailscale with install.sh"
  if ! sh -c 'curl -fsSL https://tailscale.com/install.sh | sh'; then
    log "install.sh failed; falling back to static binaries"
    install_tailscale_static
  fi
}

install_startup_script() {
  if [ ! -f "$startup_src" ]; then
    log "ERROR: missing startup script: $startup_src"
    exit 1
  fi
  as_root install -m 0755 "$startup_src" "$startup_dest"
}

configure_supervisor() {
  local dir conf
  if ! command -v supervisord >/dev/null 2>&1 && ! command -v supervisorctl >/dev/null 2>&1; then
    return 1
  fi

  if [ -d /etc/supervisor/conf.d ]; then
    dir=/etc/supervisor/conf.d
  elif [ -d /etc/supervisord.d ]; then
    dir=/etc/supervisord.d
  else
    return 1
  fi

  conf="$dir/container-ssh-tailscale.conf"
  log "configuring Supervisor startup at $conf"
  as_root tee "$conf" >/dev/null <<SUPERVISOR
[program:container-ssh-tailscale]
command=$startup_dest
autostart=true
autorestart=false
startsecs=0
stdout_logfile=/tmp/container-ssh-tailscale-supervisor.log
stderr_logfile=/tmp/container-ssh-tailscale-supervisor.err
SUPERVISOR

  if command -v supervisorctl >/dev/null 2>&1; then
    as_root supervisorctl reread || true
    as_root supervisorctl update || true
    as_root supervisorctl start container-ssh-tailscale || true
  fi
  return 0
}

patch_entrypoint() {
  local marker line tmp
  marker="# container-ssh-tailscale startup hook"
  line="if [ -x $startup_dest ]; then $startup_dest || true; fi"

  if [ -z "$entrypoint" ]; then
    return 1
  fi
  if [ ! -f "$entrypoint" ]; then
    log "ERROR: entrypoint script does not exist: $entrypoint"
    exit 1
  fi
  if grep -Fq "$marker" "$entrypoint"; then
    log "entrypoint already has startup hook: $entrypoint"
    return 0
  fi

  tmp="$(mktemp)"
  if head -n 1 "$entrypoint" | grep -q '^#!'; then
    { head -n 1 "$entrypoint"; printf '%s\n%s\n' "$marker" "$line"; tail -n +2 "$entrypoint"; } > "$tmp"
  else
    { printf '%s\n%s\n' "$marker" "$line"; cat "$entrypoint"; } > "$tmp"
  fi
  chmod --reference="$entrypoint" "$tmp" 2>/dev/null || chmod +x "$tmp"
  as_root cp "$tmp" "$entrypoint"
  rm -f "$tmp"
  log "patched entrypoint: $entrypoint"
}

configure_startup() {
  if configure_supervisor; then
    log "configured startup through Supervisor"
    return 0
  fi
  if patch_entrypoint; then
    log "configured startup through entrypoint patch"
    return 0
  fi
  log "ERROR: could not configure startup: no supported process manager found and no --entrypoint script was provided"
  exit 1
}

install_ssh
install_tailscale
install_startup_script
configure_startup
log "installation complete"
