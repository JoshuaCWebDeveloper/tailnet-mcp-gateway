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
