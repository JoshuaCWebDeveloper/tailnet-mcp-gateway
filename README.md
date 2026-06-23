# OpenAI + Tailscale Terminal MCP Gateway

This project runs a terminal MCP server inside Docker, joins the container to your Tailscale tailnet, and exposes the MCP server to ChatGPT through OpenAI Secure MCP Tunnel.

The MCP backend is `iris-networks/terminal_mcp`. It provides terminal tools such as `execute_command`, `persistent_shell`, and `session_manager`. The intended usage is to run commands such as:

```bash
ssh user@tailnet-host "uname -a"
tailscale status
ssh user@100.x.y.z "df -h"
```

## Requirements

- Docker and Docker Compose
- A Tailscale auth key
- An OpenAI Secure MCP Tunnel ID
- An OpenAI API key usable by `tunnel-client run`
- SSH access from inside the container to any Tailnet machine you want to reach

## Install

```bash
cp .env.example .env
mkdir -p ssh work tailscale-state
```

Edit `.env` and set:

```bash
TS_AUTHKEY=...
CONTROL_PLANE_TUNNEL_ID=...
CONTROL_PLANE_API_KEY=...
```

If you need SSH keys inside the container, copy them into `./ssh`:

```bash
cp ~/.ssh/id_ed25519 ./ssh/id_ed25519
cp ~/.ssh/id_ed25519.pub ./ssh/id_ed25519.pub
chmod 600 ./ssh/id_ed25519
```

Optional: create `./ssh/config` for SSH defaults:

```sshconfig
Host *
  StrictHostKeyChecking accept-new
  UserKnownHostsFile /root/.ssh/known_hosts
```

## Run

```bash
docker compose up --build
```

The container will:

1. start `tailscaled`,
2. join your Tailnet using `TS_AUTHKEY`,
3. start `tunnel-client`,
4. launch `/usr/local/bin/mcp-terminal-server` as the MCP backend.

## Using Tailnet machines

This project does not maintain a host list. Use Tailscale IPs or MagicDNS names directly in shell commands:

```bash
ssh ec2-user@my-ec2 "hostname && df -h"
ssh joshua@desktop "uname -a"
```

The target machine must still allow SSH from the container's Tailnet identity or accept an SSH key mounted in `./ssh`.

## Notes

This setup intentionally exposes an unrestricted terminal MCP backend. Treat the container as a powerful remote-control gateway. Use a dedicated Tailscale auth key, a dedicated SSH key, and least-privilege users on target machines if possible.
