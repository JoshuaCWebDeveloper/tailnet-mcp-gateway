package executor

import (
	"strings"
	"testing"
	"time"

	"github.com/mark3labs/mcp-go/mcp"
	"mcp-terminal-server/config"
)

func TestExecuteIncludesCorrelationAndRemoteMetadata(t *testing.T) {
	cfg := config.NewConfig()
	e := New(cfg)

	result, err := e.Execute(mcp.CallToolRequest{
		Params: mcp.CallToolParams{
			Arguments: map[string]any{
				"command": "printf test-output",
				"timeout": float64(5),
			},
		},
	})
	if err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}

	structured, ok := result.StructuredContent.(map[string]interface{})
	if !ok {
		t.Fatalf("structured content has type %T", result.StructuredContent)
	}

	if got := structured["stdout"]; got != "test-output" {
		t.Fatalf("stdout = %q, want test-output", got)
	}
	if got := structured["execution_mode"]; got != "local" {
		t.Fatalf("execution_mode = %q, want local", got)
	}
	if got := structured["target"]; got != "" {
		t.Fatalf("target = %q, want empty", got)
	}
	if got := structured["remote_path"]; got != "" {
		t.Fatalf("remote_path = %q, want empty", got)
	}
	invocationID, ok := structured["invocation_id"].(string)
	if !ok || !strings.HasPrefix(invocationID, "mcp_") {
		t.Fatalf("invocation_id = %#v, want mcp_ prefix", structured["invocation_id"])
	}

	text := result.Content[0].(mcp.TextContent).Text
	if !strings.Contains(text, "Invocation ID: "+invocationID) {
		t.Fatalf("fallback text does not contain invocation id %q: %s", invocationID, text)
	}
}

func TestInvocationIDsAreUnique(t *testing.T) {
	first := newInvocationID()
	time.Sleep(time.Nanosecond)
	second := newInvocationID()
	if first == second {
		t.Fatalf("invocation IDs should be unique, got %q twice", first)
	}
}
