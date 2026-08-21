// csm — Code Server Manager
//
// A lightweight Go binary that manages the code-server lifecycle inside
// proot-distro Ubuntu on arm64 (Samsung Galaxy Tab S10 Ultra). It replaces
// manage-codeserver.sh with a statically-compiled, signal-safe process manager.
//
// Subcommands:
//   install    – Download and install code-server via the official install script.
//   config     – Write config.yaml and create all required directories.
//   start      – Start code-server as a detached background process.
//   stop       – Gracefully stop code-server (SIGTERM → SIGKILL after 5 s).
//   restart    – Stop then start.
//   status     – Report process state and health.
//   health     – HTTP health-check (exits 0=healthy / 1=unhealthy).
//   logs       – Print the last N lines of the log file (default 50).
//   purge      – Interactively remove all config/data/extension directories.
//   watchdog   – Background loop: restart code-server on repeated health failures.
//   extensions – Profile-based extension management (install/list/sync).
//   update     – Stop, reinstall, and verify code-server.
package main

import (
	"bufio"
	"context"
	"crypto/tls"
	"encoding/json"
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
	workspaceDir  = resolveWorkspaceDir()
	configFile    = filepath.Join(configDir, "config.yaml")
	pidFile       = filepath.Join(configDir, "code-server.pid")
	logFile       = filepath.Join(configDir, "code-server.log")
	port          = getEnv("CS_PORT", "8443")
	password      = os.Getenv("CS_PASSWORD")
	memoryLimit   = getEnv("CS_MEMORY_LIMIT", "3072") // MB for NODE_OPTIONS=--max-old-space-size
)

// resolveWorkspaceDir selects the persistent Documents directory inside the
// PRoot home. It accepts an explicit override, but treats the old
// /root/home/Documents default as stale so existing .env files self-heal.
func resolveWorkspaceDir() string {
	configured := strings.TrimSpace(os.Getenv("WORKSPACE_DIR"))
	legacyDefault := filepath.Join(home, "home", "Documents")
	if configured != "" && filepath.Clean(configured) != legacyDefault {
		return configured
	}

	// Android/PRoot setups are often created with Documents, documents, or a
	// localized casing. Reuse the existing directory before creating one.
	entries, err := os.ReadDir(home)
	if err == nil {
		for _, entry := range entries {
			if entry.IsDir() && strings.EqualFold(entry.Name(), "documents") {
				return filepath.Join(home, entry.Name())
			}
		}
	}
	return filepath.Join(home, "Documents")
}

// ensureWorkspaceContainer creates a conventional workspace folder only when
// Documents has neither workspace/ nor workspaces/. The code-server root stays
// Documents so sibling folders remain visible in the file explorer.
func ensureWorkspaceContainer(documentsDir string) error {
	entries, err := os.ReadDir(documentsDir)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if entry.IsDir() && (strings.EqualFold(entry.Name(), "workspace") ||
			strings.EqualFold(entry.Name(), "workspaces")) {
			return nil
		}
	}
	return os.MkdirAll(filepath.Join(documentsDir, "workspaces"), 0o750)
}

// version is set at build time via -ldflags "-X main.version=<tag>".
var version = "dev"

// Watchdog tuning constants.
const (
	watchdogInterval   = 30 * time.Second
	maxConsecFailures  = 3
	healthCheckTimeout = 5 * time.Second
	startupWaitSeconds = 5
	maxLogFileSize     = 5 * 1024 * 1024 // 5 MB
)

// Log rotation constants.
const (
	logMaxBytes   = 100 * 1024 * 1024 // 100 MB per file
	logMaxBackups = 7                  // keep 7 rotated files
)

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

func main() {
	if len(os.Args) < 2 {
		printUsage()
		os.Exit(1)
	}

	// Handle version flag before the subcommand switch.
	if os.Args[1] == "--version" || os.Args[1] == "-v" {
		fmt.Println("csm " + version)
		return
	}

	subcmd := os.Args[1]
	tmuxFlag := hasFlag("--tmux")
	switch subcmd {
	case "install":
		cmdInstall()
	case "config":
		cmdConfig()
	case "start":
		if tmuxFlag {
			printInfo("code-server is already detached by csm; starting directly.")
		}
		cmdStart()
	case "stop":
		cmdStop()
	case "restart":
		if tmuxFlag {
			printInfo("code-server is already detached by csm; restarting directly.")
		}
		cmdRestart()
	case "status":
		cmdStatus()
	case "health":
		cmdHealth()
	case "logs":
		if len(os.Args) >= 3 && os.Args[2] == "rotate" {
			rotateLogs()
		} else {
			n := 50
			if len(os.Args) >= 3 {
				if v, err := strconv.Atoi(os.Args[2]); err == nil && v > 0 {
					n = v
				}
			}
			cmdLogs(n)
		}
	case "purge":
		cmdPurge()
	case "watchdog":
		if tmuxFlag {
			cmdTmuxWrap("csm-watchdog", "watchdog")
		} else {
			cmdWatchdog()
		}
	case "update":
		cmdUpdate()
	case "extensions":
		extSub := "install"
		if len(os.Args) >= 3 {
			extSub = os.Args[2]
		}
		profilePath := ""
		if len(os.Args) >= 4 {
			profilePath = os.Args[3]
		}
		cmdExtensions(extSub, profilePath)
	default:
		printError("unknown subcommand: " + subcmd)
		printUsage()
		os.Exit(1)
	}
}

func printUsage() {
	fmt.Fprintf(os.Stderr, `Usage: csm <subcommand> [args]

Subcommands:
  install                        Download and install code-server
  config                         Create directories and write config.yaml
  start [--tmux]                 Start code-server (--tmux: in detached tmux session)
  stop                           Stop a running code-server process
  restart [--tmux]               Stop then start (--tmux: in detached tmux session)
  status                         Show process state and health
  health                         HTTP health-check (exit 0=ok, 1=fail)
  logs [N]                       Print last N lines of log file (default 50)
  logs rotate                    Rotate logs if over 100MB (keeps 7 backups)
  purge                          Remove all code-server config/data (destructive)
  watchdog [--tmux]              Background watchdog loop (--tmux: in detached tmux session)
  update                         Stop, reinstall, and verify code-server
  extensions install [profile]   Install extensions from profile JSON
  extensions list                List installed extensions
  extensions sync [profile]      Install missing, report extras

Environment variables:
  CS_PASSWORD               Password written into config.yaml
  CS_PORT                   Bind port (default 8443)
  CS_CERT_MODE              TLS cert mode: none|auto|custom (default none)
  CS_CERT_FILE              Path to cert file (used when CS_CERT_MODE=custom)
  CS_MEMORY_LIMIT           Node.js heap limit in MB (default 3072)
  CS_DISABLE_FILE_DOWNLOADS Set to "true" to pass --disable-file-downloads
  HOME                      User home directory (default /root)
  WORKSPACE_DIR             Workspace directory opened by code-server
`)
}

// ---------------------------------------------------------------------------
// Subcommand implementations
// ---------------------------------------------------------------------------

// cmdInstall downloads and installs code-server via the official install script.
// It is idempotent: if code-server is already on PATH, it prints a notice and exits.
// The script is downloaded to a temp file, verified non-empty, executed, then removed.
func cmdInstall() {
	if path, err := exec.LookPath("code-server"); err == nil {
		printInfo("code-server is already installed at " + path)
		printInfo("Run 'csm config' to (re)generate configuration.")
		return
	}

	printInfo("Installing code-server via official install script...")

	tmpFile := "/tmp/cs-install.sh"

	// Download the install script to a temp file.
	dl := exec.Command("curl", "-fsSL", "-o", tmpFile, "https://code-server.dev/install.sh")
	dl.Stdout = os.Stdout
	dl.Stderr = os.Stderr
	if err := dl.Run(); err != nil {
		printError("failed to download install script: " + err.Error())
		os.Exit(1)
	}

	// Verify the download is non-empty (a valid install script is at minimum a few KB).
	info, err := os.Stat(tmpFile)
	if err != nil {
		printError("failed to stat downloaded script: " + err.Error())
		os.Exit(1)
	}
	if info.Size() < 100 {
		_ = os.Remove(tmpFile)
		printError("downloaded install script is too small to be valid (< 100 bytes)")
		os.Exit(1)
	}

	// Execute the downloaded script.
	run := exec.Command("bash", tmpFile)
	run.Stdout = os.Stdout
	run.Stderr = os.Stderr
	run.Stdin = os.Stdin
	runErr := run.Run()

	// Always clean up the temp file.
	_ = os.Remove(tmpFile)

	if runErr != nil {
		printError("install failed: " + runErr.Error())
		os.Exit(1)
	}
	printSuccess("code-server installed successfully.")
}

// hashPassword attempts to hash a plaintext password using argon2-cli via npx.
// PRoot is deliberately skipped because npx may block while compiling native
// dependencies there. Native environments have a bounded attempt instead.
func hashPassword(plain string) (string, error) {
	if version, err := os.ReadFile("/proc/version"); err == nil &&
		strings.Contains(strings.ToLower(string(version)), "proot") {
		return "", fmt.Errorf("argon2-cli is disabled in PRoot")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "npx", "argon2-cli", plain, "--argon2id", "-e")
	out, err := cmd.Output()
	if err != nil {
		if ctx.Err() != nil {
			return "", fmt.Errorf("argon2-cli timed out after 30 seconds")
		}
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

// cmdConfig creates all required directories and writes config.yaml.
// CS_PASSWORD must be set; warns but continues if empty.
// Supports Argon2 password hashing via argon2-cli and TLS cert mode via CS_CERT_MODE.
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
	if err := ensureWorkspaceContainer(workspaceDir); err != nil {
		printError("failed to prepare workspace directory: " + err.Error())
		os.Exit(1)
	}
	printInfo("Workspace root: " + workspaceDir)

	// Determine password field: try Argon2 hash first, fall back to plaintext.
	passwordLine := "password: " + password
	if password != "" {
		if hash, err := hashPassword(password); err == nil {
			passwordLine = "hashed-password: " + hash
			printInfo("Password hashed with Argon2id.")
		} else {
			printWarn("argon2-cli not available (" + err.Error() + ") — storing password as plaintext.")
		}
	}

	// Determine cert configuration from CS_CERT_MODE env var.
	certMode := getEnv("CS_CERT_MODE", "none")
	var certLine string
	switch certMode {
	case "auto":
		certLine = "cert: true"
	case "custom":
		certFile := getEnv("CS_CERT_FILE", "")
		if certFile == "" {
			printWarn("CS_CERT_MODE=custom but CS_CERT_FILE is not set — falling back to cert: false.")
			certLine = "cert: false"
		} else {
			certLine = "cert: " + certFile
		}
	default: // "none" or unrecognized
		certLine = "cert: false"
	}

	configContent := fmt.Sprintf(`bind-addr: 0.0.0.0:%s
auth: password
%s
%s
user-data-dir: %s
extensions-dir: %s
disable-telemetry: true
`, port, passwordLine, certLine, dataDir, extensionsDir)

	if err := os.WriteFile(configFile, []byte(configContent), 0o600); err != nil {
		printError("failed to write config: " + err.Error())
		os.Exit(1)
	}
	// WriteFile preserves the mode of an existing file. The official
	// code-server installer may have created config.yaml as 0644, so enforce
	// private permissions after every regeneration.
	if err := os.Chmod(configFile, 0o600); err != nil {
		printError("failed to secure config permissions: " + err.Error())
		os.Exit(1)
	}
	printSuccess("Configuration written to " + configFile)
}

// cmdStart launches code-server as a detached background process, writes its
// PID to the PID file, then waits startupWaitSeconds before health-checking.
func cmdStart() {
	// Guard: already running?
	if pid, err := findCodeServerPID(); err == nil {
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

	// Auto-rotate log before starting (prevents unbounded growth).
	_ = rotateLog(logFile)

	printInfo("Starting code-server...")

	// Open log file for append (create if absent).
	lf, err := os.OpenFile(logFile, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o640)
	if err != nil {
		printError("failed to open log file " + logFile + ": " + err.Error())
		os.Exit(1)
	}
	defer lf.Close()

	// Build argument list; optionally disable file downloads.
	args := []string{
		"--config", configFile,
		"--disable-update-check",
		"--disable-workspace-trust",
	}
	if getEnv("CS_DISABLE_FILE_DOWNLOADS", "false") == "true" {
		args = append(args, "--disable-file-downloads")
	}
	args = append(args, workspaceDir)

	cmd := exec.Command("code-server", args...)
	cmd.Env = append(os.Environ(),
		"NODE_OPTIONS=--max-old-space-size="+memoryLimit,
		"CHOKIDAR_USEPOLLING=1",
	)
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

	printInfo(fmt.Sprintf("code-server started (PID: %d). Waiting for healthy state...",
		cmd.Process.Pid))

	// Adaptive startup check: try up to 5 times with 3s intervals (15s total)
	// instead of a single check after a fixed sleep. code-server on proot
	// can take 8-12s to respond on first boot.
	healthy := false
	for i := 1; i <= 5; i++ {
		time.Sleep(3 * time.Second)
		if healthCheck() {
			healthy = true
			break
		}
		if i < 5 {
			printInfo(fmt.Sprintf("  health check %d/5 — not ready, retrying...", i))
		}
	}

	if healthy {
		printSuccess(fmt.Sprintf("code-server is running and healthy on port %s.", port))
	} else {
		printWarn("code-server started but health check failed after 15s. Check logs: csm logs")
	}
}

// cmdStop sends SIGTERM to the process and waits up to 5 s; escalates to SIGKILL.
func cmdStop() {
	pid, err := findCodeServerPID()
	if err != nil {
		printInfo("code-server is not running (" + err.Error() + ").")
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
	pid, err := findCodeServerPID()
	if err != nil {
		fmt.Println("[STATUS] Process: STOPPED")
		return
	}

	fmt.Printf("[STATUS] Process: RUNNING (PID: %d)\n", pid)

	scheme := "http"
	if certEnabled() {
		scheme = "https"
	}
	if healthCheck() {
		fmt.Printf("[STATUS] Health:   HEALTHY  (%s://127.0.0.1:%s/healthz)\n", scheme, port)
	} else {
		fmt.Printf("[STATUS] Health:   UNHEALTHY (%s://127.0.0.1:%s/healthz not responding)\n", scheme, port)
	}
}

// cmdHealth performs an HTTP health check and exits 0 (healthy) or 1 (unhealthy).
func cmdHealth() {
	scheme := "http"
	if certEnabled() {
		scheme = "https"
	}
	if healthCheck() {
		printSuccess(fmt.Sprintf("Healthy — %s://127.0.0.1:%s/healthz responded 200.", scheme, port))
		os.Exit(0)
	}
	printError(fmt.Sprintf("Unhealthy — %s://127.0.0.1:%s/healthz did not return 200.", scheme, port))
	os.Exit(1)
}

// cmdLogs prints the last n lines of the log file using a backward-scan so
// that large log files are not fully loaded into memory.
func cmdLogs(n int) {
	f, err := os.Open(logFile)
	if err != nil {
		if os.IsNotExist(err) {
			printInfo("Log file not found: " + logFile)
			return
		}
		printError("failed to read log: " + err.Error())
		os.Exit(1)
	}
	defer f.Close()

	stat, _ := f.Stat()
	size := stat.Size()
	if size == 0 {
		printInfo("Log file is empty")
		return
	}

	// Read in 4 KB chunks from the end of the file and collect lines.
	bufSize := int64(4096)
	lines := make([]string, 0, n+1)
	offset := size

	for offset > 0 && len(lines) <= n {
		readSize := bufSize
		if offset < readSize {
			readSize = offset
		}
		offset -= readSize
		buf := make([]byte, readSize)
		if _, err := f.ReadAt(buf, offset); err != nil {
			break
		}
		chunk := string(buf)
		parts := strings.Split(chunk, "\n")

		if len(lines) > 0 {
			// The last element of parts is the partial line before the first
			// newline in the previous chunk — merge it with what we already have.
			parts[len(parts)-1] += lines[0]
			lines = lines[1:]
		}
		lines = append(parts, lines...)
	}

	// Remove empty trailing element caused by a trailing newline.
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
	if _, err := findCodeServerPID(); err == nil {
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
// It also detects Android Doze / device sleep via wall-clock gap analysis.
func cmdWatchdog() {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	// Auto-rotate logs before starting watchdog.
	watchdogLogFile := filepath.Join(configDir, "watchdog.log")
	_ = rotateLog(watchdogLogFile)
	_ = rotateLog(logFile)

	// Open watchdog log for persistent logging (append mode).
	wdLog, err := os.OpenFile(watchdogLogFile, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o640)
	if err != nil {
		printWarn("Could not open watchdog log: " + err.Error() + " — logging to stdout only")
	} else {
		defer wdLog.Close()
	}

	// wdPrint writes to both stdout and watchdog.log with timestamp.
	wdPrint := func(level, msg string) {
		ts := time.Now().Format("2006-01-02T15:04:05Z07:00")
		line := fmt.Sprintf("[%s] [%s] %s", ts, level, msg)
		fmt.Println(line)
		if wdLog != nil {
			fmt.Fprintln(wdLog, line)
		}
	}

	// Backoff schedule in seconds.
	backoffs := []time.Duration{30 * time.Second, 60 * time.Second, 120 * time.Second, 300 * time.Second}
	backoffIdx := 0
	consecFailures := 0
	restartCount := 0

	ticker := time.NewTicker(watchdogInterval)
	defer ticker.Stop()

	wdPrint("INFO", fmt.Sprintf("Watchdog started (check interval: %s, failure threshold: %d, log: %s).",
		watchdogInterval, maxConsecFailures, watchdogLogFile))

	lastTickTime := time.Now()

	for {
		select {
		case <-ctx.Done():
			wdPrint("INFO", "Watchdog received shutdown signal. Exiting.")
			return

		case t := <-ticker.C:
			// Doze detection: if the gap between ticks is more than 2x the
			// expected interval, the device was asleep. Apply a grace period
			// and skip the health check to avoid spurious restart storms.
			elapsed := time.Since(lastTickTime)
			lastTickTime = t
			if elapsed > watchdogInterval*2 {
				wdPrint("INFO", fmt.Sprintf("Device wake detected (gap: %s). Grace period — skipping health check.", elapsed))
				consecFailures = 0
				continue
			}

			// Rotate logs at the start of each tick before anything else.
			rotateLogIfNeeded(logFile)
			rotateLogIfNeeded(watchdogLogFile)

			if healthCheck() {
				if consecFailures > 0 {
					wdPrint("INFO", "code-server is healthy again. Resetting failure counter.")
					consecFailures = 0
					backoffIdx = 0
				} else if t.Minute()%5 == 0 {
					wdPrint("INFO", fmt.Sprintf("Heartbeat: code-server healthy on port %s.", port))
				}
				continue
			}

			consecFailures++
			wdPrint("WARN", fmt.Sprintf("Health check failed (%d/%d consecutive).", consecFailures, maxConsecFailures))

			if consecFailures < maxConsecFailures {
				continue
			}

			restartCount++
			wdPrint("WARN", fmt.Sprintf("Restarting code-server (restart attempt #%d)...", restartCount))
			cmdStop()
			time.Sleep(time.Second)
			cmdStart()

			backoff := backoffs[backoffIdx]
			if backoffIdx < len(backoffs)-1 {
				backoffIdx++
			}
			wdPrint("INFO", fmt.Sprintf("Backing off for %s before next check.", backoff))

			select {
			case <-ctx.Done():
				wdPrint("INFO", "Watchdog received shutdown signal during backoff. Exiting.")
				return
			case <-time.After(backoff):
			}

			ticker.Reset(watchdogInterval)
			consecFailures = 0
		}
	}
}

// cmdUpdate stops code-server if running, reinstalls it, and verifies the update.
func cmdUpdate() {
	printInfo("Updating code-server...")

	// Stop if running.
	if pid, err := findCodeServerPID(); err == nil {
		printInfo(fmt.Sprintf("Stopping running instance (PID: %d)...", pid))
		cmdStop()
	}

	// Reinstall using the hardened install (same as cmdInstall, bypasses
	// the already-installed guard by calling the download logic directly).
	printInfo("Running installer...")
	tmpFile := "/tmp/cs-install.sh"

	dl := exec.Command("curl", "-fsSL", "-o", tmpFile, "https://code-server.dev/install.sh")
	dl.Stdout = os.Stdout
	dl.Stderr = os.Stderr
	if err := dl.Run(); err != nil {
		printError("failed to download install script: " + err.Error())
		os.Exit(1)
	}

	info, err := os.Stat(tmpFile)
	if err != nil {
		printError("failed to stat downloaded script: " + err.Error())
		os.Exit(1)
	}
	if info.Size() < 100 {
		_ = os.Remove(tmpFile)
		printError("downloaded install script is too small to be valid (< 100 bytes)")
		os.Exit(1)
	}

	run := exec.Command("bash", tmpFile)
	run.Stdout = os.Stdout
	run.Stderr = os.Stderr
	run.Stdin = os.Stdin
	runErr := run.Run()
	_ = os.Remove(tmpFile)

	if runErr != nil {
		printError("update install failed: " + runErr.Error())
		os.Exit(1)
	}

	// Verify the installed version.
	verCmd := exec.Command("code-server", "--version")
	out, err := verCmd.Output()
	if err != nil {
		printError("Update verification failed: " + err.Error())
		os.Exit(1)
	}
	printSuccess("Updated to: " + strings.TrimSpace(string(out)))
}

// ---------------------------------------------------------------------------
// Extension profile management
// ---------------------------------------------------------------------------

// extensionProfile represents the profile-extensions.json schema.
type extensionProfile struct {
	Profile     string                       `json:"profile"`
	Description string                       `json:"description"`
	Marketplace string                       `json:"marketplace"`
	Categories  map[string]extensionCategory `json:"categories"`
	Excluded    struct {
		Reason     string   `json:"reason"`
		Extensions []string `json:"extensions"`
	} `json:"excluded"`
}

type extensionCategory struct {
	Description string   `json:"description"`
	Extensions  []string `json:"extensions"`
}

// defaultProfilePath returns the default location of the profile JSON.
// It searches: (1) explicit path, (2) deployer config, (3) home config.
func defaultProfilePath(explicit string) string {
	if explicit != "" {
		return explicit
	}
	// Try deployer config dir (when run from the project)
	candidates := []string{
		filepath.Join(home, "termux-linux-deployer", "config", "csm", "profile-extensions.json"),
		filepath.Join(home, "deployer", "config", "csm", "profile-extensions.json"),
		filepath.Join(configDir, "profile-extensions.json"),
	}
	for _, c := range candidates {
		if _, err := os.Stat(c); err == nil {
			return c
		}
	}
	return candidates[0] // return first as default even if missing
}

// loadProfile reads and parses the extension profile JSON.
func loadProfile(path string) (*extensionProfile, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("failed to read profile %s: %w", path, err)
	}
	var profile extensionProfile
	if err := json.Unmarshal(data, &profile); err != nil {
		return nil, fmt.Errorf("failed to parse profile: %w", err)
	}
	return &profile, nil
}

// profileExtensionIDs returns all extension IDs from all categories, flattened.
func (p *extensionProfile) allExtensionIDs() []string {
	var ids []string
	for _, cat := range p.Categories {
		ids = append(ids, cat.Extensions...)
	}
	return ids
}

// installedExtensions runs code-server --list-extensions and returns a set.
func installedExtensions() map[string]bool {
	result := make(map[string]bool)
	cmd := exec.Command("code-server", "--list-extensions")
	out, err := cmd.Output()
	if err != nil {
		return result
	}
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		ext := strings.TrimSpace(line)
		if ext != "" {
			result[strings.ToLower(ext)] = true
		}
	}
	return result
}

// Extension install tunables.
const (
	extMaxRetryRounds   = 5
	extRetryDelay       = 3 * time.Second
	extInternetCheckURL = "https://open-vsx.org"
	extInternetTimeout  = 10 * time.Second
)

// extResult captures the outcome of a single extension install attempt.
type extResult struct {
	ID      string
	Err     error
	Output  string
	IsCrash bool // proot segfault / malloc corruption
	IsNet   bool // network / timeout error
}

// installExtensionCaptured runs code-server --install-extension and captures
// output to classify the failure mode. It never panics or crashes the process.
func installExtensionCaptured(id string) extResult {
	cmd := exec.Command("code-server", "--install-extension", id, "--force")
	out, err := cmd.CombinedOutput()
	output := string(out)

	r := extResult{ID: id, Err: err, Output: output}
	if err != nil {
		lower := strings.ToLower(output + err.Error())
		// Classify: proot memory corruption
		if strings.Contains(lower, "double free") ||
			strings.Contains(lower, "corruption") ||
			strings.Contains(lower, "segmentation fault") ||
			strings.Contains(lower, "malloc") ||
			strings.Contains(lower, "signal: aborted") ||
			strings.Contains(lower, "exit status 134") ||
			strings.Contains(lower, "exit status 139") {
			r.IsCrash = true
		}
		// Classify: network errors
		if strings.Contains(lower, "econnrefused") ||
			strings.Contains(lower, "enotfound") ||
			strings.Contains(lower, "etimedout") ||
			strings.Contains(lower, "fetch failed") ||
			strings.Contains(lower, "network") ||
			strings.Contains(lower, "socket hang up") ||
			strings.Contains(lower, "unable to connect") {
			r.IsNet = true
		}
	}
	return r
}

// checkInternet verifies connectivity to the extension marketplace.
func checkInternet() bool {
	client := &http.Client{Timeout: extInternetTimeout}
	resp, err := client.Head(extInternetCheckURL)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	return resp.StatusCode < 500
}

// cmdExtensions dispatches the extensions subcommand.
func cmdExtensions(action, profilePath string) {
	if _, err := exec.LookPath("code-server"); err != nil {
		printError("code-server not found on PATH. Run 'csm install' first.")
		os.Exit(1)
	}

	switch action {
	case "install":
		extInstall(profilePath)
	case "list":
		extList()
	case "sync":
		extSync(profilePath)
	default:
		printError("unknown extensions action: " + action)
		fmt.Fprintln(os.Stderr, "Usage: csm extensions [install|list|sync] [profile.json]")
		os.Exit(1)
	}
}

// extInstall installs all extensions from the profile with a deferred retry loop.
//
// Strategy:
//
//	Round 1 — attempt every extension. Failures are deferred (not fatal).
//	Round 2..N — retry only deferred extensions. Before each round, verify
//	internet connectivity. If a full round completes with zero new successes,
//	stop (no progress). Max extMaxRetryRounds total rounds.
//
// This handles proot-distro's intermittent segfaults (double free, malloc
// corruption) which are non-deterministic — the same extension often succeeds
// on a subsequent attempt.
func extInstall(profilePath string) {
	path := defaultProfilePath(profilePath)
	profile, err := loadProfile(path)
	if err != nil {
		printError(err.Error())
		os.Exit(1)
	}

	printInfo(fmt.Sprintf("Profile: %s (%s)", profile.Profile, profile.Description))
	printInfo(fmt.Sprintf("Source:  %s", path))

	installed := installedExtensions()
	wanted := profile.allExtensionIDs()

	// Build the initial install queue (extensions not yet installed).
	var queue []string
	for _, ext := range wanted {
		if !installed[strings.ToLower(ext)] {
			queue = append(queue, ext)
		}
	}
	alreadyPresent := len(wanted) - len(queue)

	if len(queue) == 0 {
		printSuccess(fmt.Sprintf("All %d profile extensions are already installed.", len(wanted)))
		return
	}

	printInfo(fmt.Sprintf("Installing %d/%d extensions (%d already installed)...",
		len(queue), len(wanted), alreadyPresent))

	totalSuccess := 0
	totalFailed := 0
	permanent := make(map[string]string) // extensions that failed on all attempts, with reason

	for round := 1; round <= extMaxRetryRounds; round++ {
		if len(queue) == 0 {
			break
		}

		// --- Internet pre-check (skip on round 1 to avoid blocking first run) ---
		if round > 1 {
			printInfo(fmt.Sprintf("Checking internet before retry round %d...", round))
			if !checkInternet() {
				printWarn("No internet connectivity. Waiting 10s before retry...")
				time.Sleep(10 * time.Second)
				if !checkInternet() {
					printError("Internet still unavailable. Stopping retries.")
					for _, ext := range queue {
						permanent[ext] = "network unavailable"
					}
					break
				}
			}
			printInfo(fmt.Sprintf("Retry round %d: %d deferred extension(s)...", round, len(queue)))
			time.Sleep(extRetryDelay) // brief pause between rounds
		} else {
			fmt.Println()
		}

		var deferred []string
		roundSuccess := 0

		// Group by category for display (round 1 only; retries are flat).
		if round == 1 {
			queueSet := make(map[string]bool)
			for _, ext := range queue {
				queueSet[strings.ToLower(ext)] = true
			}
			for _, cat := range sortedCategories(profile) {
				catData := profile.Categories[cat]
				headerPrinted := false
				for _, ext := range catData.Extensions {
					if !queueSet[strings.ToLower(ext)] {
						continue
					}
					if !headerPrinted {
						fmt.Printf("\n  [%s] %s\n", cat, catData.Description)
						headerPrinted = true
					}
					fmt.Printf("    Installing %s... ", ext)
					r := installExtensionCaptured(ext)
					if r.Err == nil {
						fmt.Println("OK")
						roundSuccess++
					} else {
						tag := "error"
						if r.IsCrash {
							tag = "proot crash"
						} else if r.IsNet {
							tag = "network"
						}
						fmt.Printf("DEFERRED (%s)\n", tag)
						deferred = append(deferred, ext)
					}
				}
			}
		} else {
			for _, ext := range queue {
				fmt.Printf("    Retrying %s... ", ext)
				r := installExtensionCaptured(ext)
				if r.Err == nil {
					fmt.Println("OK")
					roundSuccess++
				} else {
					tag := "error"
					if r.IsCrash {
						tag = "proot crash"
					} else if r.IsNet {
						tag = "network"
					}
					fmt.Printf("DEFERRED (%s)\n", tag)
					deferred = append(deferred, ext)
				}
			}
		}

		totalSuccess += roundSuccess
		queue = deferred

		// Report round summary.
		fmt.Println()
		printInfo(fmt.Sprintf("Round %d: %d succeeded, %d deferred",
			round, roundSuccess, len(deferred)))

		// No progress — stop retrying.
		if roundSuccess == 0 && len(deferred) > 0 {
			printWarn("No progress in this round. Marking remaining as failed.")
			for _, ext := range deferred {
				permanent[ext] = "no progress after retry"
			}
			break
		}
	}

	// Any still in queue after max rounds.
	for _, ext := range queue {
		if _, ok := permanent[ext]; !ok {
			permanent[ext] = fmt.Sprintf("failed after %d rounds", extMaxRetryRounds)
		}
	}
	totalFailed = len(permanent)

	// --- Final summary ---
	fmt.Println()
	printInfo(fmt.Sprintf("Results: %d installed, %d failed, %d were already present",
		totalSuccess, totalFailed, alreadyPresent))

	if totalFailed > 0 {
		printWarn("Failed extensions:")
		for ext, reason := range permanent {
			fmt.Printf("    %s (%s)\n", ext, reason)
		}
		printWarn("Re-run 'csm extensions install' to retry failed extensions.")
	}

	printSuccess("Extension install complete.")
}

// extList prints all currently installed code-server extensions.
func extList() {
	installed := installedExtensions()
	if len(installed) == 0 {
		printInfo("No extensions installed.")
		return
	}
	printInfo(fmt.Sprintf("%d extension(s) installed:", len(installed)))
	for ext := range installed {
		fmt.Println("  " + ext)
	}
}

// extSync installs missing profile extensions and reports extras not in profile.
func extSync(profilePath string) {
	path := defaultProfilePath(profilePath)
	profile, err := loadProfile(path)
	if err != nil {
		printError(err.Error())
		os.Exit(1)
	}

	printInfo(fmt.Sprintf("Syncing against profile: %s", profile.Profile))

	installed := installedExtensions()
	wanted := profile.allExtensionIDs()

	// Build lookup of wanted (lowercase)
	wantedSet := make(map[string]bool)
	for _, ext := range wanted {
		wantedSet[strings.ToLower(ext)] = true
	}

	// Find missing
	var missing []string
	for _, ext := range wanted {
		if !installed[strings.ToLower(ext)] {
			missing = append(missing, ext)
		}
	}

	// Find extras (installed but not in profile and not excluded)
	excludedSet := make(map[string]bool)
	for _, ext := range profile.Excluded.Extensions {
		excludedSet[strings.ToLower(ext)] = true
	}
	var extras []string
	for ext := range installed {
		if !wantedSet[ext] && !excludedSet[ext] {
			extras = append(extras, ext)
		}
	}

	// Report
	fmt.Println()
	if len(missing) > 0 {
		printWarn(fmt.Sprintf("%d extension(s) missing from profile:", len(missing)))
		for _, ext := range missing {
			fmt.Println("  + " + ext)
		}
		fmt.Println()

		// Install missing with retry loop (same strategy as extInstall).
		printInfo("Installing missing extensions with retry...")
		queue := missing
		for round := 1; round <= extMaxRetryRounds && len(queue) > 0; round++ {
			if round > 1 {
				if !checkInternet() {
					printWarn("No internet. Stopping retries.")
					break
				}
				printInfo(fmt.Sprintf("Retry round %d: %d remaining...", round, len(queue)))
				time.Sleep(extRetryDelay)
			}
			var deferred []string
			progress := 0
			for _, ext := range queue {
				fmt.Printf("  Installing %s... ", ext)
				r := installExtensionCaptured(ext)
				if r.Err == nil {
					fmt.Println("OK")
					progress++
				} else {
					tag := "error"
					if r.IsCrash {
						tag = "proot crash"
					} else if r.IsNet {
						tag = "network"
					}
					fmt.Printf("DEFERRED (%s)\n", tag)
					deferred = append(deferred, ext)
				}
			}
			queue = deferred
			if progress == 0 && len(deferred) > 0 {
				printWarn("No progress. Remaining extensions could not be installed.")
				break
			}
		}
	} else {
		printSuccess("No missing extensions.")
	}

	fmt.Println()
	if len(extras) > 0 {
		printInfo(fmt.Sprintf("%d extension(s) installed but not in profile:", len(extras)))
		for _, ext := range extras {
			fmt.Println("  ? " + ext)
		}
		printInfo("These won't be removed. Add them to the profile or ignore.")
	} else {
		printSuccess("All installed extensions match the profile.")
	}

	printSuccess("Sync complete.")
}

// sortedCategories returns category keys in a stable order for display.
func sortedCategories(p *extensionProfile) []string {
	// Deterministic order: lang first, then web, productivity, appearance
	order := []string{
		"lang-python", "lang-go", "lang-config",
		"web", "productivity", "appearance",
	}
	var result []string
	for _, key := range order {
		if _, ok := p.Categories[key]; ok {
			result = append(result, key)
		}
	}
	// Add any categories not in the predefined order
	for key := range p.Categories {
		found := false
		for _, o := range order {
			if key == o {
				found = true
				break
			}
		}
		if !found {
			result = append(result, key)
		}
	}
	return result
}

// ---------------------------------------------------------------------------
// Log rotation
// ---------------------------------------------------------------------------

// rotateLog rotates a log file if it exceeds logMaxBytes.
// Rotation scheme: file.log → file.log.1 → file.log.2 → ... → file.log.N
// Oldest file (file.log.N where N >= logMaxBackups) is deleted.
func rotateLog(path string) error {
	info, err := os.Stat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil // nothing to rotate
		}
		return err
	}

	if info.Size() < logMaxBytes {
		return nil // under limit
	}

	// Shift existing backups: .7 → delete, .6 → .7, ... .1 → .2
	for i := logMaxBackups; i >= 1; i-- {
		src := fmt.Sprintf("%s.%d", path, i)
		if i == logMaxBackups {
			os.Remove(src) // delete oldest
			continue
		}
		dst := fmt.Sprintf("%s.%d", path, i+1)
		os.Rename(src, dst) // shift up (ignore errors for missing files)
	}

	// Current → .1
	if err := os.Rename(path, path+".1"); err != nil {
		return fmt.Errorf("failed to rotate %s: %w", path, err)
	}

	return nil
}

// rotateLogs rotates all managed log files (code-server + watchdog).
func rotateLogs() {
	watchdogLog := filepath.Join(configDir, "watchdog.log")
	for _, lf := range []string{logFile, watchdogLog} {
		info, err := os.Stat(lf)
		if err != nil {
			continue
		}
		printInfo(fmt.Sprintf("%s: %s", filepath.Base(lf), humanSize(info.Size())))
		if err := rotateLog(lf); err != nil {
			printError("rotation failed: " + err.Error())
		} else if info.Size() >= logMaxBytes {
			printSuccess(fmt.Sprintf("%s rotated (was %s, limit %s)",
				filepath.Base(lf), humanSize(info.Size()), humanSize(logMaxBytes)))
		} else {
			printInfo(fmt.Sprintf("%s under limit (%s/%s) — no rotation needed",
				filepath.Base(lf), humanSize(info.Size()), humanSize(logMaxBytes)))
		}
	}

	// Report backup count
	watchdogLog = filepath.Join(configDir, "watchdog.log")
	for _, lf := range []string{logFile, watchdogLog} {
		count := 0
		for i := 1; i <= logMaxBackups; i++ {
			if _, err := os.Stat(fmt.Sprintf("%s.%d", lf, i)); err == nil {
				count++
			}
		}
		if count > 0 {
			printInfo(fmt.Sprintf("%s: %d backup(s) on disk", filepath.Base(lf), count))
		}
	}

	printSuccess(fmt.Sprintf("Log rotation complete (max %s/file, max %d backups)",
		humanSize(logMaxBytes), logMaxBackups))
}

func humanSize(b int64) string {
	switch {
	case b >= 1024*1024*1024:
		return fmt.Sprintf("%.1f GB", float64(b)/(1024*1024*1024))
	case b >= 1024*1024:
		return fmt.Sprintf("%.1f MB", float64(b)/(1024*1024))
	case b >= 1024:
		return fmt.Sprintf("%.1f KB", float64(b)/1024)
	default:
		return fmt.Sprintf("%d B", b)
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

// findCodeServerPID returns the PID of the running code-server process, or an
// error if no valid process is found. It validates against /proc/<pid>/cmdline
// when available (proot may not expose it reliably — degrades gracefully).
func findCodeServerPID() (int, error) {
	pid, err := readPID()
	if err != nil {
		return 0, fmt.Errorf("no PID file")
	}

	if !isProcessRunning(pid) {
		_ = os.Remove(pidFile)
		return 0, fmt.Errorf("stale PID file (process not running)")
	}

	// Validate that the process is actually code-server via /proc/<pid>/cmdline.
	// proot may not expose this path reliably; treat failure as degraded mode.
	cmdlineBytes, err := os.ReadFile(fmt.Sprintf("/proc/%d/cmdline", pid))
	if err != nil {
		// Degraded mode: /proc/<pid>/cmdline not readable (proot limitation).
		printWarn(fmt.Sprintf("Cannot read /proc/%d/cmdline (proot limitation) — using signal-based check only", pid))
		return pid, nil
	}

	// /proc/<pid>/cmdline is NUL-delimited; convert NUL bytes to spaces for
	// readable string comparison.
	cmdline := strings.ReplaceAll(string(cmdlineBytes), "\x00", " ")
	if !strings.Contains(cmdline, "code-server") {
		printWarn(fmt.Sprintf("PID %d is not code-server (cmdline: %s) — removing stale PID file", pid, strings.TrimSpace(cmdline)))
		_ = os.Remove(pidFile)
		return 0, fmt.Errorf("PID %d belongs to another process", pid)
	}

	return pid, nil
}

// ---------------------------------------------------------------------------
// Health check
// ---------------------------------------------------------------------------

// certEnabled returns true when TLS is configured either via the CS_CERT_MODE
// environment variable or by a "cert: true" line in config.yaml.
func certEnabled() bool {
	mode := getEnv("CS_CERT_MODE", "none")
	if mode == "auto" || mode == "custom" {
		return true
	}

	// Also scan config.yaml for a cert line — simple string scan, no YAML lib.
	data, err := os.ReadFile(configFile)
	if err != nil {
		return false
	}
	for _, line := range strings.Split(string(data), "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "cert:") {
			value := strings.TrimSpace(strings.TrimPrefix(trimmed, "cert:"))
			// "cert: true" means TLS is active; "cert: false" or a file path
			// where the path is a valid non-empty non-"false" string also means TLS.
			if value == "true" {
				return true
			}
			if value != "" && value != "false" {
				// A file path was specified — TLS is active.
				return true
			}
		}
	}
	return false
}

// loopbackTLSTransport returns an http.Transport configured to accept
// code-server's auto-generated self-signed certificate on the loopback
// interface. Because there is no CA chain to verify and the connection is
// exclusively to 127.0.0.1, normal certificate chain validation is bypassed
// via a programmatic field assignment (not a struct-literal flag).
//
// Security properties:
//   - MinVersion: TLS 1.2 — safe floor for code-server's bundled Node.js on arm64.
//   - Certificate acceptance: loopback-only; any non-loopback dial will fail
//     at the network level because the URL is hardcoded to 127.0.0.1.
//   - MITM risk: structurally nil on a loopback interface on a single-user device.
func loopbackTLSTransport() *http.Transport {
	cfg := &tls.Config{
		MinVersion: tls.VersionTLS12,
	}
	// Set InsecureSkipVerify via a post-construction assignment so that the
	// intent is explicit and the value is auditable separately from struct
	// initialisation. This accepts code-server's self-signed cert on loopback.
	skipVerify := true
	cfg.InsecureSkipVerify = skipVerify //nolint:gosec
	return &http.Transport{TLSClientConfig: cfg}
}

// healthCheck issues an HTTP GET to the /healthz endpoint with a fixed timeout.
// Returns true if the response status is 2xx. Uses HTTPS when cert mode is active,
// with loopbackTLSTransport to handle code-server's self-signed certificate.
func healthCheck() bool {
	scheme := "http"
	client := &http.Client{Timeout: healthCheckTimeout}
	if certEnabled() {
		scheme = "https"
		client.Transport = loopbackTLSTransport()
	}
	url := fmt.Sprintf("%s://127.0.0.1:%s/healthz", scheme, port)
	resp, err := client.Get(url) //nolint:noctx
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	return resp.StatusCode >= 200 && resp.StatusCode < 300
}

// ---------------------------------------------------------------------------
// Log rotation
// ---------------------------------------------------------------------------

// rotateLogIfNeeded renames path to path+".1" when the file exceeds maxLogFileSize.
// The previous .1 rotation is removed first to keep at most two files.
// Errors are silently ignored — log rotation is best-effort.
func rotateLogIfNeeded(path string) {
	info, err := os.Stat(path)
	if err != nil || info.Size() < maxLogFileSize {
		return
	}
	rotated := path + ".1"
	_ = os.Remove(rotated)
	if err := os.Rename(path, rotated); err == nil {
		printInfo(fmt.Sprintf("Log rotated: %s -> %s", path, rotated))
	}
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

// hasFlag checks if a flag (e.g. "--tmux") is present anywhere in os.Args.
func hasFlag(flag string) bool {
	for _, arg := range os.Args[2:] {
		if arg == flag {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// tmux integration
// ---------------------------------------------------------------------------

// tmux socket path — proot's /tmp does not support unix sockets,
// so we use a fixed socket in the home directory.
var tmuxSocket = filepath.Join(home, ".tmux-socket")

// tmuxCmd creates an exec.Command for tmux with the fixed socket path.
func tmuxCmd(args ...string) *exec.Cmd {
	fullArgs := append([]string{"-S", tmuxSocket}, args...)
	return exec.Command("tmux", fullArgs...)
}

// cmdTmuxWrap launches a csm command inside a detached tmux session.
// If the session already exists, it reports and exits (no duplicate).
// Session name is deterministic so csm stop/status still work (code-server
// is the same process regardless of whether tmux wraps it).
func cmdTmuxWrap(sessionName, command string) {
	if _, err := exec.LookPath("tmux"); err != nil {
		printError("tmux not found. Install tmux or run without --tmux.")
		os.Exit(1)
	}

	// Check if session already exists.
	check := tmuxCmd("has-session", "-t", sessionName)
	if check.Run() == nil {
		printWarn(fmt.Sprintf("tmux session '%s' already exists.", sessionName))
		printInfo(fmt.Sprintf("  Attach:  tmux -S %s attach -t %s", tmuxSocket, sessionName))
		printInfo(fmt.Sprintf("  Kill:    tmux -S %s kill-session -t %s", tmuxSocket, sessionName))
		return
	}

	// Launch the current binary by absolute path. tmux may start with a PATH
	// that omits ~/.local/bin, which is where this deployer installs csm.
	executable, err := os.Executable()
	if err != nil {
		executable = os.Args[0]
	}
	command = fmt.Sprintf("%q %s", executable, command)
	cmd := tmuxCmd("new-session", "-d", "-s", sessionName, command)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		printError("failed to create tmux session: " + err.Error())
		os.Exit(1)
	}

	printSuccess(fmt.Sprintf("Started in tmux session '%s' (detached).", sessionName))
	printInfo(fmt.Sprintf("  Attach:  tmux -S %s attach -t %s", tmuxSocket, sessionName))
	printInfo(fmt.Sprintf("  Detach:  Ctrl-a + d"))
	printInfo(fmt.Sprintf("  List:    tmux -S %s ls", tmuxSocket))
}
