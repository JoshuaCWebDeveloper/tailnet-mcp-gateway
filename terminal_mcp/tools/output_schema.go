package tools

import "encoding/json"

var executeCommandOutputSchema = json.RawMessage(`{
  "type": "object",
  "properties": {
    "stdout": {"type": "string", "description": "Command standard output. If stderr was not captured separately, stderr is merged into this field."},
    "stderr": {"type": "string", "description": "Command standard error when capture_stderr is true; otherwise an empty string."},
    "exit_code": {"type": "integer", "description": "Process exit code, or -1 when the process did not produce one."},
    "error": {"type": "string", "description": "Execution error text, or an empty string when the command succeeded."},
    "timed_out": {"type": "boolean", "description": "Whether the command exceeded the configured timeout."},
    "platform": {"type": "string", "description": "Runtime operating system platform."},
    "shell": {"type": "string", "description": "Shell used to run the command."},
    "timeout_seconds": {"type": "number", "description": "Timeout used for the command, in seconds."},
    "invocation_id": {"type": "string", "description": "Unique identifier generated for this command invocation."},
    "execution_mode": {"type": "string", "enum": ["local", "remote"], "description": "Whether the command ran locally or through SSH."},
    "target": {"type": "string", "description": "SSH target for remote commands, otherwise empty."},
    "remote_path": {"type": "string", "description": "Remote working directory path, otherwise empty."},
    "correlated": {"type": "boolean", "description": "Whether stdout contained the matching MCP invocation markers for this command."},
    "request_id": {"type": "string", "description": "Server-generated tool request identifier."},
    "tool_name": {"type": "string", "description": "MCP tool name that handled the request."},
    "requested_remote": {"type": "string", "description": "Raw remote argument requested by the client, otherwise empty."},
    "resolved_target": {"type": "string", "description": "SSH target actually passed to ssh after remote parsing, otherwise empty."},
    "command_hash": {"type": "string", "description": "SHA-256 hash of the command text received by the tool."},
    "started_at": {"type": "string", "description": "Server-side request start timestamp in RFC3339Nano format."},
    "finished_at": {"type": "string", "description": "Server-side request finish timestamp in RFC3339Nano format."}
  },
  "required": ["stdout", "stderr", "exit_code", "error", "timed_out", "platform", "shell", "timeout_seconds", "invocation_id", "execution_mode", "target", "remote_path", "correlated", "request_id", "tool_name", "requested_remote", "resolved_target", "command_hash", "started_at", "finished_at"],
  "additionalProperties": true
}`)

var persistentShellOutputSchema = json.RawMessage(`{
  "type": "object",
  "properties": {
    "stdout": {"type": "string", "description": "Output read from the persistent shell session."},
    "session_id": {"type": "string", "description": "Persistent shell session identifier."},
    "shell": {"type": "string", "description": "Shell used by the persistent session."},
    "pid": {"type": "integer", "description": "Process ID for the persistent shell."},
    "timeout_seconds": {"type": "number", "description": "Timeout used while waiting for command output, in seconds."},
    "timed_out": {"type": "boolean", "description": "Whether the command exceeded the configured timeout."},
    "exit_code": {"type": "integer", "description": "Process exit code reported by the persistent shell command wrapper."},
    "correlated": {"type": "boolean", "description": "Whether output was bounded by the matching MCP invocation markers for this command."},
    "invocation_id": {"type": "string", "description": "Unique identifier generated for this persistent-shell command invocation."},
    "execution_mode": {"type": "string", "enum": ["local", "remote"], "description": "Whether the session is local or remote over SSH."},
    "target": {"type": "string", "description": "SSH target for remote sessions, otherwise empty."},
    "remote_path": {"type": "string", "description": "Remote working directory path, otherwise empty."},
    "request_id": {"type": "string", "description": "Server-generated tool request identifier."},
    "tool_name": {"type": "string", "description": "MCP tool name that handled the request."},
    "requested_remote": {"type": "string", "description": "Raw remote argument requested by the client, otherwise empty."},
    "resolved_target": {"type": "string", "description": "SSH target actually passed to ssh after remote parsing, otherwise empty."},
    "command_hash": {"type": "string", "description": "SHA-256 hash of the command text received by the tool."},
    "started_at": {"type": "string", "description": "Server-side request start timestamp in RFC3339Nano format."},
    "finished_at": {"type": "string", "description": "Server-side request finish timestamp in RFC3339Nano format."}
  },
  "required": ["stdout", "session_id", "shell", "pid", "timeout_seconds", "timed_out", "exit_code", "correlated", "invocation_id", "execution_mode", "target", "remote_path", "request_id", "tool_name", "requested_remote", "resolved_target", "command_hash", "started_at", "finished_at"],
  "additionalProperties": true
}`)

var sessionManagerOutputSchema = json.RawMessage(`{
  "type": "object",
  "properties": {
    "action": {"type": "string", "enum": ["list", "close"], "description": "Session manager action that was performed."},
    "message": {"type": "string", "description": "Human-readable status message."},
    "sessions": {
      "type": "array",
      "description": "Active persistent shell sessions. Empty for close actions or when no sessions exist.",
      "items": {
        "type": "object",
        "properties": {
          "id": {"type": "string", "description": "Session identifier."},
          "shell": {"type": "string", "description": "Shell used by the session."},
          "pid": {"type": "integer", "description": "Process ID for the persistent shell."},
          "created": {"type": "string", "description": "Session creation timestamp in RFC3339 format."},
          "last_used": {"type": "string", "description": "Last-used timestamp in RFC3339 format."},
          "alive": {"type": "boolean", "description": "Whether the shell process is still alive."},
          "remote": {"type": "string", "description": "SSH target for remote sessions, otherwise empty."},
          "remote_path": {"type": "string", "description": "Remote working directory path, otherwise empty."}
        },
        "required": ["id", "shell", "pid", "created", "last_used", "alive", "remote", "remote_path"],
        "additionalProperties": true
      }
    },
    "closed_session_id": {"type": "string", "description": "Closed session identifier for close actions, otherwise empty."}
  },
  "required": ["action", "message", "sessions", "closed_session_id"],
  "additionalProperties": true
}`)
