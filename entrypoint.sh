#!/usr/bin/env bash
set -euo pipefail

: "${TS_AUTHKEY:?TS_AUTHKEY is required}"
: "${CONTROL_PLANE_TUNNEL_ID:?CONTROL_PLANE_TUNNEL_ID is required}"
: "${CONTROL_PLANE_API_KEY:?CONTROL_PLANE_API_KEY is required}"

TS_HOSTNAME="${TS_HOSTNAME:-openai-terminal-mcp-gateway}"
TS_STATE_DIR="${TS_STATE_DIR:-/var/lib/tailscale}"
TS_SOCKET="${TS_SOCKET:-/var/run/tailscale/tailscaled.sock}"
TS_EXTRA_ARGS="${TS_EXTRA_ARGS:-}"
TUNNEL_HEALTH_ADDR="${TUNNEL_HEALTH_ADDR:-0.0.0.0:8080}"

cleanup() {
  if [[ -n "${TAILSCALED_PID:-}" ]]; then
    kill "$TAILSCALED_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo "Starting tailscaled..."
tailscaled \
  --state="${TS_STATE_DIR}/tailscaled.state" \
  --socket="${TS_SOCKET}" &
TAILSCALED_PID=$!

echo "Waiting for tailscaled..."
for _ in $(seq 1 30); do
  if tailscale --socket="${TS_SOCKET}" status >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

echo "Connecting to Tailscale as ${TS_HOSTNAME}..."
# shellcheck disable=SC2086
tailscale --socket="${TS_SOCKET}" up \
  --auth-key="${TS_AUTHKEY}" \
  --hostname="${TS_HOSTNAME}" \
  --accept-dns=true \
  ${TS_EXTRA_ARGS}

echo "Tailscale status:"
tailscale --socket="${TS_SOCKET}" status || true

echo "Starting OpenAI Secure MCP Tunnel with terminal MCP backend..."
exec tunnel-client run \
  --control-plane.tunnel-id="${CONTROL_PLANE_TUNNEL_ID}" \
  --control-plane.api-key="env:CONTROL_PLANE_API_KEY" \
  --health.listen-addr="${TUNNEL_HEALTH_ADDR}" \
  --mcp.command="/usr/local/bin/mcp-terminal-server"
