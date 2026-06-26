#!/usr/bin/env bash
set -euo pipefail

MACHINE_TOOLS_LOG_NAME=install-tailscale
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/lib.sh"

install_curl_if_needed() {
  if command -v curl >/dev/null 2>&1; then
    return 0
  fi
  machine_tools_as_root apt update
  machine_tools_as_root apt install -y curl ca-certificates
}

install_tailscale_static() {
  local version arch tmp tgz url
  version="${TAILSCALE_STATIC_VERSION:-1.70.0}"

  case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    armv7l) arch=arm ;;
    *) machine_tools_log "ERROR: unsupported architecture for static Tailscale install: $(uname -m)"; exit 1 ;;
  esac

  install_curl_if_needed
  if ! command -v tar >/dev/null 2>&1; then
    machine_tools_as_root apt install -y tar
  fi

  tmp="$(mktemp -d)"
  tgz="${tmp}/tailscale.tgz"
  url="https://pkgs.tailscale.com/stable/tailscale_${version}_${arch}.tgz"

  machine_tools_log "installing Tailscale static binaries from ${url}"
  curl -fsSL "${url}" -o "${tgz}"
  tar -xzf "${tgz}" -C "${tmp}"
  machine_tools_as_root install -m 0755 "${tmp}"/tailscale_*/tailscale /usr/local/bin/tailscale
  machine_tools_as_root install -m 0755 "${tmp}"/tailscale_*/tailscaled /usr/local/bin/tailscaled
  rm -rf "${tmp}"
}

if command -v tailscale >/dev/null 2>&1 && command -v tailscaled >/dev/null 2>&1; then
  machine_tools_log "Tailscale is already installed"
  exit 0
fi

install_curl_if_needed
machine_tools_log "installing Tailscale with install.sh"
if ! sh -c 'curl -fsSL https://tailscale.com/install.sh | sh'; then
  machine_tools_log "install.sh failed; falling back to static binaries"
  install_tailscale_static
fi
machine_tools_log "Tailscale installation complete"
