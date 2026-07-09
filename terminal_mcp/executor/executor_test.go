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
	if got := structured["correlated"]; got != true {
		t.Fatalf("correlated = %v, want true", got)
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

func TestExecuteStripsMarkersAndPreservesNoNewlineOutput(t *testing.T) {
	cfg := config.NewConfig()
	e := New(cfg)

	result, err := e.Execute(mcp.CallToolRequest{
		Params: mcp.CallToolParams{
			Arguments: map[string]any{
				"command": "printf no-newline",
			},
		},
	})
	if err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}

	structured := result.StructuredContent.(map[string]interface{})
	if got := structured["stdout"]; got != "no-newline" {
		t.Fatalf("stdout = %q, want no-newline", got)
	}
	if strings.Contains(structured["stdout"].(string), "__MCP_") {
		t.Fatalf("stdout leaked MCP marker: %q", structured["stdout"])
	}
	if got := structured["correlated"]; got != true {
		t.Fatalf("correlated = %v, want true", got)
	}
}

func TestExecuteReportsWrappedExitCode(t *testing.T) {
	cfg := config.NewConfig()
	e := New(cfg)

	result, err := e.Execute(mcp.CallToolRequest{
		Params: mcp.CallToolParams{
			Arguments: map[string]any{
				"command": "echo before-failure; exit 7",
			},
		},
	})
	if err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}

	structured := result.StructuredContent.(map[string]interface{})
	if got := structured["exit_code"]; got != 7 {
		t.Fatalf("exit_code = %v, want 7", got)
	}
	if got := structured["correlated"]; got != true {
		t.Fatalf("correlated = %v, want true", got)
	}
	if !strings.Contains(structured["stdout"].(string), "before-failure") {
		t.Fatalf("stdout = %q, want command output", structured["stdout"])
	}
}

func TestUnwrapCommandOutputDetectsMissingMarkers(t *testing.T) {
	stdout, exitCode, correlated := unwrapCommandOutput("stale output from another command", "missing")
	if correlated {
		t.Fatalf("correlated = true, want false")
	}
	if exitCode != -1 {
		t.Fatalf("exitCode = %d, want -1", exitCode)
	}
	if stdout != "stale output from another command" {
		t.Fatalf("stdout = %q, want original stale output", stdout)
	}
}

func TestExecuteReturnsToolErrorWhenMarkersAreMissing(t *testing.T) {
	cfg := config.NewConfig()
	e := New(cfg)
	originalWrapCommand := wrapCommand
	wrapCommand = func(command string, invocationID string) string {
		return "printf stale-output-without-markers"
	}
	defer func() { wrapCommand = originalWrapCommand }()

	result, err := e.Execute(mcp.CallToolRequest{
		Params: mcp.CallToolParams{
			Arguments: map[string]any{"command": "printf ignored"},
		},
	})
	if err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if !result.IsError {
		t.Fatalf("expected marker correlation failure to be a tool error")
	}
	structured := result.StructuredContent.(map[string]interface{})
	if got := structured["correlated"]; got != false {
		t.Fatalf("correlated = %v, want false", got)
	}
}
