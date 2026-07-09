package session

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/mark3labs/mcp-go/mcp"
	"mcp-terminal-server/config"
	"mcp-terminal-server/remote"
)

// ShellSession represents a persistent shell session
type ShellSession struct {
	ID         string
	Cmd        *exec.Cmd
	Stdin      io.WriteCloser
	Stdout     io.ReadCloser
	Stderr     io.ReadCloser
	Reader     *bufio.Reader
	WorkingDir string
	Shell      string
	Remote     remote.Spec
	Created    time.Time
	LastUsed   time.Time
	mu         sync.Mutex
}

// Manager manages persistent shell sessions
type Manager struct {
	sessions          map[string]*ShellSession
	mu                sync.RWMutex
	config            *config.Config
	invocationCounter atomic.Uint64
}

// NewManager creates a new session manager
func NewManager(cfg *config.Config) *Manager {
	sm := &Manager{
		sessions: make(map[string]*ShellSession),
		config:   cfg,
	}

	// Start cleanup goroutine
	go sm.cleanupSessions()

	return sm
}

// GetOrCreateSession gets an existing session or creates a new one
func (sm *Manager) GetOrCreateSession(sessionID string, shell string, remoteRaw string) (*ShellSession, error) {
	sm.mu.Lock()
	defer sm.mu.Unlock()

	remoteSpec, err := remote.Parse(remoteRaw)
	if err != nil {
		return nil, err
	}

	// Check if session exists
	if session, exists := sm.sessions[sessionID]; exists {
		if session.Remote.Raw != remoteSpec.Raw {
			return nil, fmt.Errorf("session %s already exists with a different remote target", sessionID)
		}
		session.LastUsed = time.Now()
		return session, nil
	}

	// Create new session
	if shell == "" {
		shell = sm.config.Shell
	}

	var cmd *exec.Cmd
	if remoteSpec.Raw != "" {
		sshArgs, err := remoteSpec.SSHArgs()
		if err != nil {
			return nil, err
		}
		cmd = exec.Command("ssh", sshArgs...)
	} else {
		cmd = exec.Command(shell)
	}

	// Set up environment variables
	cmd.Env = os.Environ()
	if sm.config.Display != "" {
		cmd.Env = append(cmd.Env, "DISPLAY="+sm.config.Display)
	}

	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, fmt.Errorf("failed to create stdin pipe: %v", err)
	}

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		stdin.Close()
		return nil, fmt.Errorf("failed to create stdout pipe: %v", err)
	}

	stderr, err := cmd.StderrPipe()
	if err != nil {
		stdin.Close()
		stdout.Close()
		return nil, fmt.Errorf("failed to create stderr pipe: %v", err)
	}

	if err := cmd.Start(); err != nil {
		stdin.Close()
		stdout.Close()
		stderr.Close()
		return nil, fmt.Errorf("failed to start shell: %v", err)
	}

	go io.Copy(io.Discard, stderr)

	session := &ShellSession{
		ID:         sessionID,
		Cmd:        cmd,
		Stdin:      stdin,
		Stdout:     stdout,
		Stderr:     stderr,
		Reader:     bufio.NewReader(stdout),
		WorkingDir: "",
		Shell:      shell,
		Remote:     remoteSpec,
		Created:    time.Now(),
		LastUsed:   time.Now(),
	}

	sm.sessions[sessionID] = session

	log.Printf("Created new shell session: %s (shell: %s, remote: %s, pid: %d)", sessionID, shell, remoteSpec.Raw, cmd.Process.Pid)

	return session, nil
}

// ExecuteCommand executes a command in a persistent shell session
func (sm *Manager) ExecuteCommand(sessionID string, command string, timeout time.Duration, shell string, remoteRaw string, captureStderr bool) (*mcp.CallToolResult, error) {
	session, err := sm.GetOrCreateSession(sessionID, shell, remoteRaw)
	if err != nil {
		return mcp.NewToolResultError(fmt.Sprintf("Failed to get session: %v", err)), nil
	}

	session.mu.Lock()
	defer session.mu.Unlock()

	if session.Cmd.ProcessState != nil && session.Cmd.ProcessState.Exited() {
		sm.mu.Lock()
		delete(sm.sessions, sessionID)
		sm.mu.Unlock()

		return mcp.NewToolResultError("Shell session died, please retry"), nil
	}

	invocationID := fmt.Sprintf("mcp_%d_%d", time.Now().UnixNano(), sm.invocationCounter.Add(1))
	startMarker := "__MCP_START_" + invocationID + "__"
	endMarker := "__MCP_END_" + invocationID + "__"

	commandToRun := command
	if session.Remote.Raw != "" {
		commandToRun = session.Remote.Command(command)
	}
	fullCommand := fmt.Sprintf(
		"printf '%%s\\n' %s\n{\n%s\n} 2>&1\n__mcp_status=$?\nprintf '\\n%%s:%%s\\n' %s \"$__mcp_status\"\n",
		strconv.Quote(startMarker),
		commandToRun,
		strconv.Quote(endMarker),
	)

	if _, err := session.Stdin.Write([]byte(fullCommand)); err != nil {
		return mcp.NewToolResultError(fmt.Sprintf("Failed to write command: %v", err)), nil
	}

	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	type commandOutput struct {
		stdout   string
		exitCode int
	}
	outputChan := make(chan commandOutput, 1)
	errorChan := make(chan error, 1)

	go func() {
		var output strings.Builder
		started := false
		for {
			line, err := session.Reader.ReadString('\n')
			if err != nil {
				if err == io.EOF && line != "" && started {
					output.WriteString(line)
				}
				errorChan <- err
				return
			}

			line = strings.TrimSuffix(line, "\n")
			line = strings.TrimSuffix(line, "\r")
			if !started {
				if line == startMarker {
					started = true
				}
				continue
			}

			endPrefix := endMarker + ":"
			if strings.HasPrefix(line, endPrefix) {
				exitCode, err := strconv.Atoi(strings.TrimPrefix(line, endPrefix))
				if err != nil {
					errorChan <- err
					return
				}
				outputChan <- commandOutput{stdout: output.String(), exitCode: exitCode}
				return
			}

			output.WriteString(line)
			output.WriteString("\n")
		}
	}()

	select {
	case output := <-outputChan:
		session.LastUsed = time.Now()
		trimmedOutput := strings.TrimSpace(output.stdout)
		executionMode := "local"
		target := ""
		remotePath := ""
		if session.Remote.Raw != "" {
			executionMode = "remote"
			target = session.Remote.Target
			remotePath = session.Remote.Path
		}

		structured := map[string]interface{}{
			"stdout":          trimmedOutput,
			"session_id":      sessionID,
			"shell":           session.Shell,
			"pid":             session.Cmd.Process.Pid,
			"timeout_seconds": timeout.Seconds(),
			"timed_out":       false,
			"exit_code":       output.exitCode,
			"correlated":      true,
			"invocation_id":   invocationID,
			"execution_mode":  executionMode,
			"target":          target,
			"remote_path":     remotePath,
		}

		location := "local"
		if session.Remote.Raw != "" {
			location = "remote " + session.Remote.Target
			if session.Remote.Path != "" {
				location += " " + session.Remote.Path
			}
		}
		result := fmt.Sprintf("Command executed in persistent shell on %s.\nInvocation ID: %s\nExecution Mode: %s",
			location, invocationID, executionMode)
		if target != "" {
			result += fmt.Sprintf("\nTarget: %s", target)
		}
		result += fmt.Sprintf("\nOutput: %s\nExit Code: %d\nSession ID: %s\nShell: %s (PID: %d)", trimmedOutput, output.exitCode, sessionID, session.Shell, session.Cmd.Process.Pid)

		return mcp.NewToolResultStructured(structured, result), nil

	case err := <-errorChan:
		sm.closeSessionAfterFailure(sessionID, session)
		return mcp.NewToolResultError(fmt.Sprintf("Error reading output; closed session %s to prevent stale output from contaminating future commands: %v", sessionID, err)), nil

	case <-ctx.Done():
		sm.closeSessionAfterFailure(sessionID, session)
		return mcp.NewToolResultError(fmt.Sprintf("Command timeout; closed session %s to prevent stale output from contaminating future commands", sessionID)), nil
	}
}

func (sm *Manager) closeSessionAfterFailure(sessionID string, session *ShellSession) {
	sm.mu.Lock()
	delete(sm.sessions, sessionID)
	sm.mu.Unlock()
	session.Stdin.Close()
	session.Stdout.Close()
	session.Stderr.Close()
	if session.Cmd.Process != nil {
		session.Cmd.Process.Kill()
	}
}

// CloseSession closes a specific session
func (sm *Manager) CloseSession(sessionID string) error {
	sm.mu.Lock()
	defer sm.mu.Unlock()

	session, exists := sm.sessions[sessionID]
	if !exists {
		return fmt.Errorf("session not found: %s", sessionID)
	}

	session.Stdin.Close()
	session.Stdout.Close()
	session.Stderr.Close()
	if session.Cmd.Process != nil {
		session.Cmd.Process.Kill()
	}

	delete(sm.sessions, sessionID)
	log.Printf("Closed session: %s", sessionID)

	return nil
}

// ListSessions returns information about active sessions
func (sm *Manager) ListSessions() map[string]interface{} {
	sm.mu.RLock()
	defer sm.mu.RUnlock()

	result := make(map[string]interface{})
	for id, session := range sm.sessions {
		result[id] = map[string]interface{}{
			"shell":       session.Shell,
			"created":     session.Created.Format(time.RFC3339),
			"last_used":   session.LastUsed.Format(time.RFC3339),
			"pid":         session.Cmd.Process.Pid,
			"alive":       session.Cmd.ProcessState == nil || !session.Cmd.ProcessState.Exited(),
			"remote":      session.Remote.Target,
			"remote_path": session.Remote.Path,
		}
	}

	return result
}

// cleanupSessions removes inactive sessions
func (sm *Manager) cleanupSessions() {
	ticker := time.NewTicker(5 * time.Minute)
	defer ticker.Stop()

	for {
		select {
		case <-ticker.C:
			sm.mu.Lock()
			now := time.Now()
			for id, session := range sm.sessions {
				if now.Sub(session.LastUsed) > 30*time.Minute {
					log.Printf("Cleaning up inactive session: %s", id)
					session.Stdin.Close()
					session.Stdout.Close()
					session.Stderr.Close()
					if session.Cmd.Process != nil {
						session.Cmd.Process.Kill()
					}
					delete(sm.sessions, id)
				}
			}
			sm.mu.Unlock()
		}
	}
}
