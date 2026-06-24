# AGENTS.md

## Tailnet command access

For commands that should run on another Tailnet machine, use the gateway wrapper command.

Usage:

```bash
remote USER HOST COMMAND
```

Example:

```bash
remote chatgpt joshua-samsung 'pwd; ls -la ~'
```

The wrapper runs inside the gateway container and connects over Tailscale.
Do not invoke the lower-level network client directly from the MCP terminal tool; direct calls may be blocked before they reach the gateway.

Host keys are stored in `/work/known_hosts` by default so the gateway can remember hosts across restarts.

Environment variables:

- `REMOTE_KNOWN_HOSTS`: path to the known-hosts file. Defaults to `/work/known_hosts`.
- `REMOTE_CONNECT_TIMEOUT`: connect timeout in seconds. Defaults to `10`.
