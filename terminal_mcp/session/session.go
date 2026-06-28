package session

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"

	"github.com/mark3labs/mcp-go/mcp"
	"mcp-terminal-server/config"
	"mcp-terminal-server/remote"
)

// ShellSession represents a persistent shell session
type ShellSession struct {
	ID          string
	Cmd         *exec.Cmd
	Stdin       io.WriteCloser
	Stdout      io.ReadCloser
	Stderr      io.ReadCloser
	WorkingDir  string
	Shell       string
	Remote      remote.Spec
	Created     time.Time
	LastUsed    time.Time
	mu          sync.Mutex
}

// Manager manages persistent shell sessions
type Manager struct {
	sessions map[string]*ShellSession
	mu       sync.RWMutex
	config   *config.Config
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

	session := &ShellSession{
		ID:         sessionID,
		Cmd:        cmd,
		Stdin:      stdin,
		Stdout:     stdout,
		Stderr:     stderr,
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

	commandMarker := fmt.Sprintf("MCPCMD_%d", time.Now().UnixNano())

	commandToRun := command
	if session.Remote.Raw != "" {
		commandToRun = session.Remote.Command(command)
	}
	fullCommand := fmt.Sprintf("%s\necho %s_DONE\n", commandToRun, commandMarker)

	if _, err := session.Stdin.Write([]byte(fullCommand)); err != nil {
		return mcp.NewToolResultError(fmt.Sprintf("Failed to write command: %v", err)), nil
	}

	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	outputChan := make(chan string, 1)
	errorChan := make(chan error, 1)

	go func() {
		var output strings.Builder
		scanner := bufio.NewScanner(session.Stdout)
		doneMarker := commandMarker + "_DONE"

		for scanner.Scan() {
			line := scanner.Text()
			if line == doneMarker {
				outputChan <- output.String()
				return
			}
			output.WriteString(line)
			output.WriteString("\n")
		}

		if err := scanner.Err(); err != nil {
			errorChan <- err
			return
		}

		outputChan <- output.String()
	}()

	select {
	case output := <-outputChan:
		session.LastUsed = time.Now()
		trimmedOutput := strings.TrimSpace(output)
		structured := map[string]interface{}{
			"stdout":          trimmedOutput,
			"session_id":      sessionID,
			"shell":           session.Shell,
			"pid":             session.Cmd.Process.Pid,
			"timeout_seconds": timeout.Seconds(),
			"timed_out":       false,
		}

		location := "local"
		if session.Remote.Raw != "" {
			location = "remote " + session.Remote.Target
			if session.Remote.Path != "" {
				location += " " + session.Remote.Path
			}
		}
		result := fmt.Sprintf("Command executed in persistent shell on %s.\nOutput: %s\nSession ID: %s\nShell: %s (PID: %d)",
			location, trimmedOutput, sessionID, session.Shell, session.Cmd.Process.Pid)

		return mcp.NewToolResultStructured(structured, result), nil

	case err := <-errorChan:
		return mcp.NewToolResultError(fmt.Sprintf("Error reading output: %v", err)), nil

	case <-ctx.Done():
		return mcp.NewToolResultError("Command timeout"), nil
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
