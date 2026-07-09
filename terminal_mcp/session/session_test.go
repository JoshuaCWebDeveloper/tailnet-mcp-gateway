package session

import (
	"strings"
	"testing"
	"time"

	"mcp-terminal-server/config"
)

func TestPersistentShellSequentialCommandsAreCorrelated(t *testing.T) {
	cfg := config.NewConfig()
	sm := NewManager(cfg)

	first, err := sm.ExecuteCommand("seq", "echo first; echo err-first >&2", 5*time.Second, cfg.Shell, "", false)
	if err != nil {
		t.Fatalf("first command returned error: %v", err)
	}
	firstStructured := first.StructuredContent.(map[string]interface{})
	firstOut := firstStructured["stdout"].(string)
	if !strings.Contains(firstOut, "first") || !strings.Contains(firstOut, "err-first") {
		t.Fatalf("first stdout = %q, want stdout and stderr merged", firstOut)
	}
	if got := firstStructured["execution_mode"]; got != "local" {
		t.Fatalf("execution_mode = %q, want local", got)
	}
	if _, ok := firstStructured["invocation_id"].(string); !ok {
		t.Fatalf("missing invocation_id in %#v", firstStructured)
	}
	if got := firstStructured["correlated"]; got != true {
		t.Fatalf("correlated = %v, want true", got)
	}
	if got := firstStructured["exit_code"]; got != 0 {
		t.Fatalf("exit_code = %v, want 0", got)
	}

	second, err := sm.ExecuteCommand("seq", "echo second", 5*time.Second, cfg.Shell, "", false)
	if err != nil {
		t.Fatalf("second command returned error: %v", err)
	}
	secondOut := second.StructuredContent.(map[string]interface{})["stdout"].(string)
	if strings.Contains(secondOut, "first") || strings.Contains(secondOut, "err-first") {
		t.Fatalf("second stdout was contaminated by first command: %q", secondOut)
	}
	if !strings.Contains(secondOut, "second") {
		t.Fatalf("second stdout = %q, want second", secondOut)
	}

	if err := sm.CloseSession("seq"); err != nil {
		t.Fatalf("failed to close session: %v", err)
	}
}

func TestPersistentShellTimeoutClosesSession(t *testing.T) {
	cfg := config.NewConfig()
	sm := NewManager(cfg)

	result, err := sm.ExecuteCommand("timeout", "sleep 2", 50*time.Millisecond, cfg.Shell, "", false)
	if err != nil {
		t.Fatalf("ExecuteCommand returned Go error: %v", err)
	}
	if !result.IsError {
		t.Fatalf("expected tool error for timed-out command")
	}

	sm.mu.RLock()
	_, exists := sm.sessions["timeout"]
	sm.mu.RUnlock()
	if exists {
		t.Fatalf("timed-out session still exists")
	}
}

func TestPersistentShellDiscardsOutputBeforeStartMarker(t *testing.T) {
	cfg := config.NewConfig()
	sm := NewManager(cfg)
	session, err := sm.GetOrCreateSession("stale", cfg.Shell, "")
	if err != nil {
		t.Fatalf("failed to create session: %v", err)
	}
	if _, err := session.Stdin.Write([]byte("echo stale-before-marker\n")); err != nil {
		t.Fatalf("failed to write stale output: %v", err)
	}
	time.Sleep(50 * time.Millisecond)

	result, err := sm.ExecuteCommand("stale", "echo fresh-output", 5*time.Second, cfg.Shell, "", false)
	if err != nil {
		t.Fatalf("command returned error: %v", err)
	}
	out := result.StructuredContent.(map[string]interface{})["stdout"].(string)
	if strings.Contains(out, "stale-before-marker") {
		t.Fatalf("stdout included stale pre-marker output: %q", out)
	}
	if !strings.Contains(out, "fresh-output") {
		t.Fatalf("stdout = %q, want fresh-output", out)
	}
	if err := sm.CloseSession("stale"); err != nil {
		t.Fatalf("failed to close session: %v", err)
	}
}

func TestPersistentShellReportsExitCode(t *testing.T) {
	cfg := config.NewConfig()
	sm := NewManager(cfg)

	result, err := sm.ExecuteCommand("exit-code", "echo before-exit; bash -c 'exit 9'", 5*time.Second, cfg.Shell, "", false)
	if err != nil {
		t.Fatalf("command returned error: %v", err)
	}
	structured := result.StructuredContent.(map[string]interface{})
	if got := structured["exit_code"]; got != 9 {
		t.Fatalf("exit_code = %v, want 9", got)
	}
	if got := structured["correlated"]; got != true {
		t.Fatalf("correlated = %v, want true", got)
	}
	if !strings.Contains(structured["stdout"].(string), "before-exit") {
		t.Fatalf("stdout = %q, want before-exit", structured["stdout"])
	}
	if err := sm.CloseSession("exit-code"); err != nil {
		t.Fatalf("failed to close session: %v", err)
	}
}

func TestPersistentShellExitClosesSession(t *testing.T) {
	cfg := config.NewConfig()
	sm := NewManager(cfg)

	result, err := sm.ExecuteCommand("dies", "exit 3", 5*time.Second, cfg.Shell, "", false)
	if err != nil {
		t.Fatalf("ExecuteCommand returned Go error: %v", err)
	}
	if !result.IsError {
		t.Fatalf("expected shell exit to return a tool error")
	}

	sm.mu.RLock()
	_, exists := sm.sessions["dies"]
	sm.mu.RUnlock()
	if exists {
		t.Fatalf("dead session still exists")
	}
}
