package executor

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"github.com/mark3labs/mcp-go/mcp"
	"mcp-terminal-server/config"
	"mcp-terminal-server/remote"
	"mcp-terminal-server/trace"
)

// Executor handles non-persistent command execution
type Executor struct {
	config *config.Config
}

// New creates a new executor
func New(cfg *config.Config) *Executor {
	return &Executor{
		config: cfg,
	}
}

var invocationCounter atomic.Uint64

func newInvocationID() string {
	return fmt.Sprintf("mcp_%d_%d", time.Now().UnixNano(), invocationCounter.Add(1))
}

func startMarker(invocationID string) string {
	return "__MCP_START_" + invocationID + "__"
}

func endMarker(invocationID string) string {
	return "__MCP_END_" + invocationID + "__"
}

var wrapCommand = func(command string, invocationID string) string {
	return fmt.Sprintf(
		"printf '%%s\n' %s\n(\n%s\n)\n__mcp_status=$?\nprintf '\n%%s:%%s\n' %s \"$__mcp_status\"\nexit \"$__mcp_status\"",
		strconv.Quote(startMarker(invocationID)),
		command,
		strconv.Quote(endMarker(invocationID)),
	)
}

func unwrapCommandOutput(stdout string, invocationID string) (string, int, bool) {
	start := startMarker(invocationID) + "\n"
	startIndex := strings.Index(stdout, start)
	if startIndex < 0 {
		return stdout, -1, false
	}

	payload := stdout[startIndex+len(start):]
	endPrefix := "\n" + endMarker(invocationID) + ":"
	endIndex := strings.LastIndex(payload, endPrefix)
	if endIndex < 0 {
		return payload, -1, false
	}

	output := payload[:endIndex]
	statusStart := endIndex + len(endPrefix)
	statusEnd := strings.IndexByte(payload[statusStart:], '\n')
	if statusEnd < 0 {
		return output, -1, false
	}

	exitCode, err := strconv.Atoi(payload[statusStart : statusStart+statusEnd])
	if err != nil {
		return output, -1, false
	}

	return output, exitCode, true
}

// Execute executes a command in a non-persistent manner
func (e *Executor) Execute(request mcp.CallToolRequest) (*mcp.CallToolResult, error) {
	return e.ExecuteWithMetadata(request, trace.Metadata{})
}

func (e *Executor) ExecuteWithMetadata(request mcp.CallToolRequest, metadata trace.Metadata) (*mcp.CallToolResult, error) {
	args := request.GetArguments()

	command, ok := args["command"].(string)
	if !ok || command == "" {
		return mcp.NewToolResultError("Command is required"), nil
	}

	// Get optional remote target
	remoteRaw := ""
	if remoteArg, ok := args["remote"].(string); ok {
		remoteRaw = remoteArg
	}
	metadata = metadata.WithDefaults("execute_command", remoteRaw, command)
	finishedAt := func() string { return time.Now().UTC().Format(time.RFC3339Nano) }

	invocationID := newInvocationID()
	wrappedCommand := wrapCommand(command, invocationID)

	// Get timeout
	timeout := e.config.DefaultTimeout
	if timeoutArg, ok := args["timeout"].(float64); ok && timeoutArg > 0 {
		timeout = time.Duration(timeoutArg) * time.Second
	}

	// Get shell
	shell := e.config.Shell
	if shellArg, ok := args["shell"].(string); ok && shellArg != "" {
		shell = shellArg
	}

	// Get capture_stderr option
	captureStderr := false
	if captureStderrArg, ok := args["capture_stderr"].(bool); ok {
		captureStderr = captureStderrArg
	}

	remoteSpec, err := remote.Parse(remoteRaw)
	if err != nil {
		return mcp.NewToolResultError(fmt.Sprintf("Invalid remote: %v", err)), nil
	}

	// Create context with timeout
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	// Execute command
	var cmd *exec.Cmd
	switch e.config.Platform {
	case "darwin", "linux":
		if remoteSpec.Raw != "" {
			sshArgs, err := remoteSpec.SSHArgs()
			if err != nil {
				return mcp.NewToolResultError(fmt.Sprintf("Invalid remote: %v", err)), nil
			}
			sshArgs = append(sshArgs, remoteSpec.Command(wrappedCommand))
			cmd = exec.CommandContext(ctx, "ssh", sshArgs...)
		} else {
			cmd = exec.CommandContext(ctx, shell, "-c", wrappedCommand)
		}
	default:
		return mcp.NewToolResultError(fmt.Sprintf("Platform %s not supported", e.config.Platform)), nil
	}

	// Set up environment variables
	cmd.Env = os.Environ() // Start with current environment
	if e.config.Display != "" {
		// Add or update DISPLAY variable
		cmd.Env = append(cmd.Env, "DISPLAY="+e.config.Display)
	}

	var stdout, stderr strings.Builder
	cmd.Stdout = &stdout

	if captureStderr {
		cmd.Stderr = &stderr
	} else {
		cmd.Stderr = &stdout
	}

	err = cmd.Run()

	commandStdout, commandExitCode, correlated := unwrapCommandOutput(stdout.String(), invocationID)
	if correlated && !captureStderr {
		stdout.Reset()
		stdout.WriteString(commandStdout)
	}

	executionMode := "local"
	target := ""
	remotePath := ""
	if remoteSpec.Raw != "" {
		executionMode = "remote"
		target = remoteSpec.Target
		remotePath = remoteSpec.Path
	}

	result := map[string]interface{}{
		"stdout":           stdout.String(),
		"stderr":           "",
		"exit_code":        0,
		"error":            "",
		"timed_out":        false,
		"platform":         e.config.Platform,
		"shell":            shell,
		"timeout_seconds":  timeout.Seconds(),
		"invocation_id":    invocationID,
		"execution_mode":   executionMode,
		"target":           target,
		"remote_path":      remotePath,
		"correlated":       correlated,
		"request_id":       metadata.RequestID,
		"tool_name":        metadata.ToolName,
		"requested_remote": metadata.RequestedRemote,
		"resolved_target":  target,
		"command_hash":     metadata.CommandHash,
		"started_at":       metadata.StartedAt.Format(time.RFC3339Nano),
		"finished_at":      finishedAt(),
	}

	if captureStderr {
		result["stderr"] = stderr.String()
		if correlated {
			result["stdout"] = commandStdout
		}
	}

	if correlated {
		result["exit_code"] = commandExitCode
	}

	if err != nil {
		result["error"] = err.Error()
		if !correlated {
			result["exit_code"] = -1
		}
		if ctx.Err() == context.DeadlineExceeded {
			result["timed_out"] = true
		}
		if exitErr, ok := err.(*exec.ExitError); ok {
			result["exit_code"] = exitErr.ExitCode()
		}
	}

	if !correlated {
		markerError := "command output did not contain matching MCP invocation markers"
		if result["error"] == "" {
			result["error"] = markerError
		} else {
			result["error"] = fmt.Sprintf("%s; %s", result["error"], markerError)
		}
	}

	location := "local"
	if remoteSpec.Raw != "" {
		location = "remote " + remoteSpec.Target
		if remoteSpec.Path != "" {
			location += " " + remoteSpec.Path
		}
	}
	fallbackText := fmt.Sprintf("Command executed on %s.\nRequest ID: %s\nTool: %s\nRequested Remote: %s\nResolved Target: %s\nCommand Hash: %s\nInvocation ID: %s\nExecution Mode: %s", location, metadata.RequestID, metadata.ToolName, metadata.RequestedRemote, target, metadata.CommandHash, invocationID, executionMode)
	if target != "" {
		fallbackText += fmt.Sprintf("\nTarget: %s", target)
	}
	fallbackText += fmt.Sprintf("\nOutput: %s", result["stdout"])
	if result["stderr"] != "" {
		fallbackText += fmt.Sprintf("\nStderr: %s", result["stderr"])
	}
	if result["error"] != "" {
		fallbackText += fmt.Sprintf("\nError: %s", result["error"])
	}
	fallbackText += fmt.Sprintf("\nExit Code: %v\nPlatform: %s\nShell: %s", result["exit_code"], result["platform"], result["shell"])

	toolResult := mcp.NewToolResultStructured(result, fallbackText)
	if !correlated {
		toolResult.IsError = true
	}
	return toolResult, nil
}
