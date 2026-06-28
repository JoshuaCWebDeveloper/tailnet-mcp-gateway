package remote

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// Spec describes a remote SSH target in the form [user@]host[:port][/path].
type Spec struct {
	Raw    string
	Target string
	Port   string
	Path   string
}

// Parse parses a remote SSH target in the form [user@]host[:port][/path].
func Parse(raw string) (Spec, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return Spec{}, nil
	}

	targetPart := raw
	remotePath := ""
	if pathStart := strings.Index(targetPart, "/"); pathStart >= 0 {
		remotePath = targetPart[pathStart:]
		targetPart = targetPart[:pathStart]
	}

	if targetPart == "" {
		return Spec{}, fmt.Errorf("remote host is required")
	}

	target := targetPart
	port := ""
	userHost := targetPart
	userPrefix := ""
	if at := strings.LastIndex(userHost, "@"); at >= 0 {
		userPrefix = userHost[:at+1]
		userHost = userHost[at+1:]
	}

	if colon := strings.LastIndex(userHost, ":"); colon >= 0 {
		maybePort := userHost[colon+1:]
		host := userHost[:colon]
		if host != "" && isDigits(maybePort) {
			port = maybePort
			target = userPrefix + host
		}
	}

	return Spec{
		Raw:    raw,
		Target: target,
		Port:   port,
		Path:   remotePath,
	}, nil
}

// SSHArgs returns arguments for invoking ssh for the remote target.
func (s Spec) SSHArgs() ([]string, error) {
	if s.Target == "" {
		return nil, fmt.Errorf("remote host is required")
	}

	knownHosts := os.Getenv("REMOTE_KNOWN_HOSTS")
	if knownHosts == "" {
		knownHosts = "/work/known_hosts"
	}
	if err := os.MkdirAll(filepath.Dir(knownHosts), 0o755); err != nil {
		return nil, fmt.Errorf("failed to create known_hosts directory: %w", err)
	}

	connectTimeout := os.Getenv("REMOTE_CONNECT_TIMEOUT")
	if connectTimeout == "" {
		connectTimeout = "10"
	}

	args := []string{
		"-o", "UserKnownHostsFile=" + knownHosts,
		"-o", "StrictHostKeyChecking=accept-new",
		"-o", "ConnectTimeout=" + connectTimeout,
	}
	if s.Port != "" {
		args = append(args, "-p", s.Port)
	}
	args = append(args, s.Target)

	return args, nil
}

// Command returns the command to run on the remote host, with a leading cd when a path was supplied.
func (s Spec) Command(command string) string {
	if s.Path == "" {
		return command
	}
	return "cd " + shellQuote(s.Path) + " && " + command
}

func isDigits(value string) bool {
	if value == "" {
		return false
	}
	for _, r := range value {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

func shellQuote(value string) string {
	return strconv.Quote(value)
}
