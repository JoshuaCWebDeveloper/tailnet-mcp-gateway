package trace

import "testing"

func TestMetadataWithDefaultsFillsMissingFields(t *testing.T) {
	metadata := Metadata{RequestID: "req_existing"}.WithDefaults("execute_command", "remote", "echo test")
	if metadata.RequestID != "req_existing" {
		t.Fatalf("request id changed: %q", metadata.RequestID)
	}
	if metadata.ToolName != "execute_command" {
		t.Fatalf("tool name = %q", metadata.ToolName)
	}
	if metadata.CommandHash == "" {
		t.Fatalf("missing command hash")
	}
	if metadata.StartedAt.IsZero() {
		t.Fatalf("missing start time")
	}
}
