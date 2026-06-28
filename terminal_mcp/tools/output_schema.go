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
    "timeout_seconds": {"type": "number", "description": "Timeout used for the command, in seconds."}
  },
  "required": ["stdout", "stderr", "exit_code", "error", "timed_out", "platform", "shell", "timeout_seconds"],
  "additionalProperties": false
}`)

var persistentShellOutputSchema = json.RawMessage(`{
  "type": "object",
  "properties": {
    "stdout": {"type": "string", "description": "Output read from the persistent shell session."},
    "session_id": {"type": "string", "description": "Persistent shell session identifier."},
    "shell": {"type": "string", "description": "Shell used by the persistent session."},
    "pid": {"type": "integer", "description": "Process ID for the persistent shell."},
    "timeout_seconds": {"type": "number", "description": "Timeout used while waiting for command output, in seconds."},
    "timed_out": {"type": "boolean", "description": "Whether the command exceeded the configured timeout."}
  },
  "required": ["stdout", "session_id", "shell", "pid", "timeout_seconds", "timed_out"],
  "additionalProperties": false
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
          "alive": {"type": "boolean", "description": "Whether the shell process is still alive."}
        },
        "required": ["id", "shell", "pid", "created", "last_used", "alive"],
        "additionalProperties": false
      }
    },
    "closed_session_id": {"type": "string", "description": "Closed session identifier for close actions, otherwise empty."}
  },
  "required": ["action", "message", "sessions", "closed_session_id"],
  "additionalProperties": false
}`)
