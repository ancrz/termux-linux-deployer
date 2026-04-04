// csm — Code Server Manager
//
// A lightweight Go binary that manages the code-server lifecycle inside
// proot-distro Ubuntu on arm64 (Samsung Galaxy Tab S10 Ultra). It replaces
// manage-codeserver.sh with a statically-compiled, signal-safe process manager.
//
// Subcommands:
//   install   – Download and install code-server via the official install script.
//   config    – Write config.yaml and create all required directories.
//   start     – Start code-server as a detached background process.
//   stop      – Gracefully stop code-server (SIGTERM → SIGKILL after 5 s).
//   restart   – Stop then start.
//   status    – Report process state and health.
//   health    – HTTP health-check (exits 0=healthy / 1=unhealthy).
//   logs      – Print the last N lines of the log file (default 50).
//   purge     – Interactively remove all config/data/extension directories.
//   watchdog  – Background loop: restart code-server on repeated health failures.
package main

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// ---------------------------------------------------------------------------
// Configuration — all paths and tunables in one place.
// ---------------------------------------------------------------------------

var (
	home          = getEnv("HOME", "/root")
	configDir     = filepath.Join(home, ".config", "code-server")
	dataDir       = filepath.Join(home, ".local", "share", "code-server")
	extensionsDir = filepath.Join(home, ".local", "share", "vscode-extensions")
	workspaceDir  = getEnv("WORKSPACE_DIR", filepath.Join(home, "home", "Documents"))
	configFile    = filepath.Join(configDir, "config.yaml")
	pidFile       = filepath.Join(configDir, "code-server.pid")
	logFile       = filepath.Join(configDir, "code-server.log")
	port          = getEnv("CS_PORT", "8443")
	password      = os.Getenv("CS_PASSWORD")
	memoryLimit   = "4096" // MB for NODE_OPTIONS=--max-old-space-size
)

// Watchdog tuning constants.
const (
	watchdogInterval   = 30 * time.Second
	maxConsecFailures  = 3
	healthCheckTimeout = 5 * time.Second
	startupWaitSeconds = 5
)

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

func main() {
	if len(os.Args) < 2 {
		printUsage()
		os.Exit(1)
	}

	subcmd := os.Args[1]
	switch subcmd {
	case "install":
		cmdInstall()
	case "config":
		cmdConfig()
	case "start":
		cmdStart()
	case "stop":
		cmdStop()
	case "restart":
		cmdRestart()
	case "status":
		cmdStatus()
	case "health":
		cmdHealth()
	case "logs":
		n := 50
		if len(os.Args) >= 3 {
			if v, err := strconv.Atoi(os.Args[2]); err == nil && v > 0 {
				n = v
			}
		}
		cmdLogs(n)
	case "purge":
		cmdPurge()
	case "watchdog":
		cmdWatchdog()
	default:
		printError("unknown subcommand: " + subcmd)
		printUsage()
		os.Exit(1)
	}
}

func printUsage() {
	fmt.Fprintf(os.Stderr, `Usage: csm <subcommand> [args]

Subcommands:
  install          Download and install code-server
  config           Create directories and write config.yaml
  start            Start code-server in the background
  stop             Stop a running code-server process
  restart          Stop then start
  status           Show process state and health
  health           HTTP health-check (exit 0=ok, 1=fail)
  logs [N]         Print last N lines of log file (default 50)
  purge            Remove all code-server config/data (destructive)
  watchdog         Background watchdog loop

Environment variables:
  CS_PASSWORD      Password written into config.yaml
  CS_PORT          Bind port (default 8443)
  HOME             User home directory (default /root)
  WORKSPACE_DIR    Workspace directory opened by code-server
`)
}

// ---------------------------------------------------------------------------
// Subcommand implementations
// ---------------------------------------------------------------------------

// cmdInstall downloads and installs code-server via the official install script.
// It is idempotent: if code-server is already on PATH, it prints a notice and exits.
func cmdInstall() {
	if path, err := exec.LookPath("code-server"); err == nil {
		printInfo("code-server is already installed at " + path)
		printInfo("Run 'csm config' to (re)generate configuration.")
		return
	}

	printInfo("Installing code-server via official install script...")
	cmd := exec.Command("bash", "-c", "curl -fsSL https://code-server.dev/install.sh | sh")
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Stdin = os.Stdin
	if err := cmd.Run(); err != nil {
		printError("install failed: " + err.Error())
		os.Exit(1)
	}
	printSuccess("code-server installed successfully.")
}

// cmdConfig creates all required directories and writes config.yaml.
// CS_PASSWORD must be set; warns but continues if empty.
func cmdConfig() {
	if password == "" {
		printWarn("CS_PASSWORD is not set — config.yaml will have an empty password.")
		printWarn("Set CS_PASSWORD and re-run 'csm config' to fix this.")
	}

	printInfo("Creating directories...")
	for _, dir := range []string{configDir, dataDir, extensionsDir, workspaceDir} {
		if err := os.MkdirAll(dir, 0o750); err != nil {
			printError("failed to create " + dir + ": " + err.Error())
			os.Exit(1)
		}
		printInfo("  " + dir)
	}

	configContent := fmt.Sprintf(`bind-addr: 0.0.0.0:%s
auth: password
password: %s
cert: false
user-data-dir: %s
extensions-dir: %s
disable-telemetry: true
`, port, password, dataDir, extensionsDir)

	if err := os.WriteFile(configFile, []byte(configContent), 0o600); err != nil {
		printError("failed to write config: " + err.Error())
		os.Exit(1)
	}
	printSuccess("Configuration written to " + configFile)
}

// cmdStart launches code-server as a detached background process, writes its
// PID to the PID file, then waits startupWaitSeconds before health-checking.
func cmdStart() {
	// Guard: already running?
	if pid, err := readPID(); err == nil && isProcessRunning(pid) {
		printWarn(fmt.Sprintf("code-server is already running (PID: %d).", pid))
		return
	}

	// Guard: binary on PATH?
	if _, err := exec.LookPath("code-server"); err != nil {
		printError("code-server not found on PATH. Run 'csm install' first.")
		os.Exit(1)
	}

	// Guard: config exists?
	if _, err := os.Stat(configFile); os.IsNotExist(err) {
		printError("config.yaml not found. Run 'csm config' first.")
		os.Exit(1)
	}

	printInfo("Starting code-server...")

	// Open log file for append (create if absent).
	lf, err := os.OpenFile(logFile, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o640)
	if err != nil {
		printError("failed to open log file " + logFile + ": " + err.Error())
		os.Exit(1)
	}
	defer lf.Close()

	cmd := exec.Command(
		"code-server",
		"--config", configFile,
		"--disable-update-check",
		"--disable-workspace-trust",
		workspaceDir,
	)
	cmd.Env = append(os.Environ(), "NODE_OPTIONS=--max-old-space-size="+memoryLimit)
	cmd.Stdout = lf
	cmd.Stderr = lf
	// Setsid detaches from the controlling terminal — equivalent to nohup + &.
	// Without this, code-server receives SIGHUP when the shell session ends.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}

	if err := cmd.Start(); err != nil {
		printError("failed to start code-server: " + err.Error())
		os.Exit(1)
	}

	if err := writePID(cmd.Process.Pid); err != nil {
		printError("failed to write PID file: " + err.Error())
		// Process is running; don't kill it, just warn.
		printWarn("code-server started but PID file could not be written.")
	}

	printInfo(fmt.Sprintf("code-server started (PID: %d). Waiting %ds for startup...",
		cmd.Process.Pid, startupWaitSeconds))
	time.Sleep(startupWaitSeconds * time.Second)

	if healthCheck() {
		printSuccess(fmt.Sprintf("code-server is running and healthy on port %s.", port))
	} else {
		printWarn("code-server started but health check failed. Check logs: csm logs")
	}
}

// cmdStop sends SIGTERM to the process and waits up to 5 s; escalates to SIGKILL.
func cmdStop() {
	pid, err := readPID()
	if err != nil {
		printInfo("code-server is not running (no PID file).")
		return
	}

	if !isProcessRunning(pid) {
		printInfo("code-server is not running (stale PID file removed).")
		_ = os.Remove(pidFile)
		return
	}

	printInfo(fmt.Sprintf("Stopping code-server (PID: %d)...", pid))

	// SIGTERM — graceful shutdown.
	if err := syscall.Kill(pid, syscall.SIGTERM); err != nil {
		printError("failed to send SIGTERM: " + err.Error())
		os.Exit(1)
	}

	// Poll for up to 5 s.
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		time.Sleep(500 * time.Millisecond)
		if !isProcessRunning(pid) {
			_ = os.Remove(pidFile)
			printSuccess("code-server stopped.")
			return
		}
	}

	// SIGKILL — force stop.
	printWarn("Process did not exit after SIGTERM; sending SIGKILL...")
	if err := syscall.Kill(pid, syscall.SIGKILL); err != nil {
		printError("failed to send SIGKILL: " + err.Error())
		os.Exit(1)
	}
	time.Sleep(500 * time.Millisecond)
	_ = os.Remove(pidFile)
	printSuccess("code-server killed.")
}

// cmdRestart stops then starts code-server.
func cmdRestart() {
	cmdStop()
	time.Sleep(time.Second)
	cmdStart()
}

// cmdStatus prints process state and health endpoint status.
func cmdStatus() {
	pid, err := readPID()
	if err != nil || !isProcessRunning(pid) {
		// Clean up stale PID file if present.
		if err == nil {
			_ = os.Remove(pidFile)
		}
		fmt.Println("[STATUS] Process: STOPPED")
		return
	}

	fmt.Printf("[STATUS] Process: RUNNING (PID: %d)\n", pid)

	if healthCheck() {
		fmt.Printf("[STATUS] Health:   HEALTHY  (http://127.0.0.1:%s/healthz)\n", port)
	} else {
		fmt.Printf("[STATUS] Health:   UNHEALTHY (http://127.0.0.1:%s/healthz not responding)\n", port)
	}
}

// cmdHealth performs an HTTP health check and exits 0 (healthy) or 1 (unhealthy).
func cmdHealth() {
	if healthCheck() {
		printSuccess(fmt.Sprintf("Healthy — http://127.0.0.1:%s/healthz responded 200.", port))
		os.Exit(0)
	}
	printError(fmt.Sprintf("Unhealthy — http://127.0.0.1:%s/healthz did not return 200.", port))
	os.Exit(1)
}

// cmdLogs prints the last n lines of the log file.
func cmdLogs(n int) {
	data, err := os.ReadFile(logFile)
	if err != nil {
		if os.IsNotExist(err) {
			printInfo("Log file not found: " + logFile)
			return
		}
		printError("failed to read log file: " + err.Error())
		os.Exit(1)
	}

	lines := strings.Split(string(data), "\n")
	// Remove trailing empty element from final newline.
	if len(lines) > 0 && lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}

	start := 0
	if len(lines) > n {
		start = len(lines) - n
	}

	fmt.Printf("--- last %d lines of %s ---\n", n, logFile)
	for _, line := range lines[start:] {
		fmt.Println(line)
	}
	fmt.Println("---")
}

// cmdPurge interactively confirms then removes all code-server directories.
func cmdPurge() {
	fmt.Println("[ALERT] This is a destructive operation.")
	fmt.Println("        The following directories will be permanently removed:")
	fmt.Println("          " + configDir)
	fmt.Println("          " + dataDir)
	fmt.Println("          " + extensionsDir)
	fmt.Print("Are you absolutely sure you want to continue? [y/N]: ")

	reader := bufio.NewReader(os.Stdin)
	answer, err := reader.ReadString('\n')
	if err != nil && err != io.EOF {
		printError("failed to read confirmation: " + err.Error())
		os.Exit(1)
	}
	answer = strings.TrimSpace(strings.ToLower(answer))

	if answer != "y" && answer != "yes" {
		printInfo("Purge cancelled.")
		return
	}

	// Stop if running.
	if pid, err := readPID(); err == nil && isProcessRunning(pid) {
		printInfo("Stopping code-server before purge...")
		cmdStop()
	}

	printInfo("Removing directories...")
	for _, dir := range []string{configDir, dataDir, extensionsDir} {
		if err := os.RemoveAll(dir); err != nil {
			printError("failed to remove " + dir + ": " + err.Error())
			os.Exit(1)
		}
		printInfo("  Removed: " + dir)
	}
	printSuccess("Purged all code-server data.")
	printInfo("Run 'csm config' then 'csm start' to set up fresh.")
}

// cmdWatchdog runs a background health-check loop. It catches SIGTERM/SIGINT
// for clean shutdown. On 3 consecutive health failures it restarts code-server
// with exponential backoff (30 s → 60 s → 120 s → 300 s max).
func cmdWatchdog() {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	// Backoff schedule in seconds.
	backoffs := []time.Duration{30 * time.Second, 60 * time.Second, 120 * time.Second, 300 * time.Second}
	backoffIdx := 0
	consecFailures := 0
	restartCount := 0

	ticker := time.NewTicker(watchdogInterval)
	defer ticker.Stop()

	printInfo(fmt.Sprintf("Watchdog started (check interval: %s, failure threshold: %d).",
		watchdogInterval, maxConsecFailures))

	for {
		select {
		case <-ctx.Done():
			printInfo("Watchdog received shutdown signal. Exiting.")
			return

		case t := <-ticker.C:
			if healthCheck() {
				// Reset failure state on a healthy tick.
				if consecFailures > 0 {
					printInfo("code-server is healthy again. Resetting failure counter.")
					consecFailures = 0
					backoffIdx = 0
				} else {
					// Periodic heartbeat — only every 5th tick to reduce noise.
					// We use the minute of the tick to spread the log entries.
					if t.Minute()%5 == 0 {
						printInfo(fmt.Sprintf("Heartbeat: code-server healthy on port %s.", port))
					}
				}
				continue
			}

			// Health check failed.
			consecFailures++
			printWarn(fmt.Sprintf("Health check failed (%d/%d consecutive).", consecFailures, maxConsecFailures))

			if consecFailures < maxConsecFailures {
				continue
			}

			// Threshold reached — restart.
			restartCount++
			printWarn(fmt.Sprintf("Restarting code-server (restart attempt #%d)...", restartCount))
			cmdStop()
			time.Sleep(time.Second)
			cmdStart()

			// Apply backoff before resuming checks.
			backoff := backoffs[backoffIdx]
			if backoffIdx < len(backoffs)-1 {
				backoffIdx++
			}
			printInfo(fmt.Sprintf("Backing off for %s before next check.", backoff))

			// Wait for backoff duration, but still honour shutdown signals.
			select {
			case <-ctx.Done():
				printInfo("Watchdog received shutdown signal during backoff. Exiting.")
				return
			case <-time.After(backoff):
			}

			// Reset ticker and failure counter after backoff.
			ticker.Reset(watchdogInterval)
			consecFailures = 0
		}
	}
}

// ---------------------------------------------------------------------------
// PID file management
// ---------------------------------------------------------------------------

// readPID reads and parses the PID file. Returns an error if the file does
// not exist or contains a non-integer value.
func readPID() (int, error) {
	data, err := os.ReadFile(pidFile)
	if err != nil {
		return 0, err
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil {
		return 0, fmt.Errorf("invalid PID in file: %w", err)
	}
	return pid, nil
}

// writePID creates (or truncates) the PID file and writes the given PID.
func writePID(pid int) error {
	return os.WriteFile(pidFile, []byte(strconv.Itoa(pid)+"\n"), 0o640)
}

// ---------------------------------------------------------------------------
// Process probe
// ---------------------------------------------------------------------------

// isProcessRunning sends signal 0 to pid. If the kernel acknowledges the
// process exists (no ESRCH), the process is alive. EPERM means it exists
// but is owned by another user — treat as running.
func isProcessRunning(pid int) bool {
	err := syscall.Kill(pid, 0)
	return err == nil || err == syscall.EPERM
}

// ---------------------------------------------------------------------------
// Health check
// ---------------------------------------------------------------------------

// healthCheck issues an HTTP GET to the /healthz endpoint with a fixed timeout.
// Returns true if the response status is 2xx.
func healthCheck() bool {
	client := &http.Client{Timeout: healthCheckTimeout}
	url := fmt.Sprintf("http://127.0.0.1:%s/healthz", port)
	resp, err := client.Get(url) //nolint:noctx
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	return resp.StatusCode >= 200 && resp.StatusCode < 300
}

// ---------------------------------------------------------------------------
// Logging helpers
// ---------------------------------------------------------------------------

func printInfo(msg string)    { fmt.Printf("[INFO]    %s\n", msg) }
func printSuccess(msg string) { fmt.Printf("[OK]      %s\n", msg) }
func printWarn(msg string)    { fmt.Printf("[WARN]    %s\n", msg) }
func printError(msg string)   { fmt.Fprintf(os.Stderr, "[ERROR]   %s\n", msg) }

// ---------------------------------------------------------------------------
// Utility
// ---------------------------------------------------------------------------

// getEnv returns the value of the environment variable key, or fallback if
// the variable is unset or empty.
func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
