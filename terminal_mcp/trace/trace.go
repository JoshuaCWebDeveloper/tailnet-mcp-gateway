package trace

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"sync/atomic"
	"time"
)

var counter atomic.Uint64

// Metadata is generated at tool-handler entry and copied into command results so
// callers can distinguish the requested tool call from the process invocation.
type Metadata struct {
	RequestID       string
	ToolName        string
	RequestedRemote string
	CommandHash     string
	StartedAt       time.Time
}

func NewMetadata(toolName string, requestedRemote string, command string) Metadata {
	sum := sha256.Sum256([]byte(command))
	return Metadata{
		RequestID:       fmt.Sprintf("req_%d_%d", time.Now().UnixNano(), counter.Add(1)),
		ToolName:        toolName,
		RequestedRemote: requestedRemote,
		CommandHash:     hex.EncodeToString(sum[:]),
		StartedAt:       time.Now().UTC(),
	}
}

func (m Metadata) WithDefaults(toolName string, requestedRemote string, command string) Metadata {
	if m.RequestID == "" {
		return NewMetadata(toolName, requestedRemote, command)
	}
	if m.ToolName == "" {
		m.ToolName = toolName
	}
	if m.CommandHash == "" {
		sum := sha256.Sum256([]byte(command))
		m.CommandHash = hex.EncodeToString(sum[:])
	}
	if m.StartedAt.IsZero() {
		m.StartedAt = time.Now().UTC()
	}
	return m
}
