#!/usr/bin/env bash
set -u

log() {
  printf '[container-ssh-tailscale] %s\n' "$*" >&2
}

as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    log "ERROR: root privileges are required, but this user is not root and sudo is unavailable"
    return 1
  fi
}

start_sshd() {
  if ! command -v ssh-keygen >/dev/null 2>&1; then
    log "ERROR: ssh-keygen is not installed; run the install script first"
    return 1
  fi
  if [ ! -x /usr/sbin/sshd ]; then
    log "ERROR: /usr/sbin/sshd is not installed; run the install script first"
    return 1
  fi

  as_root ssh-keygen -A
  as_root mkdir -p /run/sshd

  if pgrep -x sshd >/dev/null 2>&1; then
    log "sshd is already running"
    return 0
  fi

  log "starting sshd"
  as_root /usr/sbin/sshd
}

start_tailscaled() {
  if ! command -v tailscaled >/dev/null 2>&1; then
    log "ERROR: tailscaled is not installed; run the install script first"
    return 1
  fi

  as_root mkdir -p /var/lib/tailscale

  if pgrep -x tailscaled >/dev/null 2>&1; then
    log "tailscaled is already running"
    return 0
  fi

  log "starting tailscaled in userspace networking mode"
  if [ "$(id -u)" -eq 0 ]; then
    nohup tailscaled \
      --tun=userspace-networking \
      --socks5-server=127.0.0.1:1055 \
      --outbound-http-proxy-listen=127.0.0.1:1055 \
      --state=/var/lib/tailscale/tailscaled.state \
      > /tmp/tailscaled.log 2>&1 < /dev/null &
  else
    nohup sudo tailscaled \
      --tun=userspace-networking \
      --socks5-server=127.0.0.1:1055 \
      --outbound-http-proxy-listen=127.0.0.1:1055 \
      --state=/var/lib/tailscale/tailscaled.state \
      > /tmp/tailscaled.log 2>&1 < /dev/null &
  fi
}

main() {
  local failed=0
  start_sshd || failed=1
  start_tailscaled || failed=1
  return "$failed"
}

main "$@"
