#!/usr/bin/env bash

machine_tools_log() {
  local name
  name="${MACHINE_TOOLS_LOG_NAME:-machine-tools}"
  printf '[%s] %s\n' "$name" "$*" >&2
}

machine_tools_as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    machine_tools_log "ERROR: root privileges are required, but this user is not root and sudo is unavailable"
    return 1
  fi
}

# Prints a non-reversible identifier for comparing a credential across scripts.
# Never log raw API keys or the HTTP Authorization header.
machine_tools_key_fingerprint() {
  local key="$1" digest
  digest="$(printf '%s' "$key" | sha256sum)"
  digest="${digest%% *}"
  printf 'length=%s sha256=%s' "${#key}" "${digest:0:16}"
}
