// Go port of the bundled spotify plugin (Plugins/spotify): thin command
// wrapper around the spotify_player CLI with per-plugin config/cache dirs
// under FLASH_PLUGIN_DATA_DIR. Compiled by the manifest's sandboxed
// third-party `install` step ("go build ..."), which is the point of this
// example — the full compile-at-install pipeline for a compiled language.
package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

func onCommand(params map[string]any) map[string]any {
	subcommand, _ := params["subcommand"].(string)
	var tail []string
	timeout := 120 * time.Second
	switch subcommand {
	case "login":
		tail, timeout = []string{"authenticate"}, 300*time.Second
	case "status":
		tail = []string{"--version"}
	case "pause":
		tail = []string{"playback", "pause"}
	case "play":
		tail = []string{"playback", "play"}
	case "toggle":
		tail = []string{"playback", "play-pause"}
	case "next":
		tail = []string{"playback", "next"}
	case "previous":
		tail = []string{"playback", "previous"}
	case "search":
		var query []string
		if args, ok := params["args"].([]any); ok {
			for _, a := range args {
				if s, ok := a.(string); ok {
					query = append(query, s)
				}
			}
		}
		tail = []string{"search", strings.Join(query, " ")}
	default:
		return map[string]any{"ok": false, "error": "unknown subcommand: " + subcommand}
	}

	dataDir := os.Getenv("FLASH_PLUGIN_DATA_DIR")
	config := filepath.Join(dataDir, "config", "spotify-player")
	cache := filepath.Join(dataDir, "cache", "spotify-player")
	os.MkdirAll(config, 0o755)
	os.MkdirAll(cache, 0o755)

	argv := append(
		[]string{"--config-folder", config, "--cache-folder", cache},
		tail...,
	)
	cmd := exec.Command("spotify_player", argv...)
	done := make(chan error, 1)
	var output []byte
	go func() {
		var err error
		output, err = cmd.CombinedOutput()
		done <- err
	}()
	select {
	case err := <-done:
		if err != nil {
			message := strings.TrimSpace(string(output))
			if message == "" {
				message = err.Error()
			}
			return map[string]any{"ok": false, "error": message}
		}
		return map[string]any{"ok": true, "stdout": strings.TrimSpace(string(output))}
	case <-time.After(timeout):
		if cmd.Process != nil {
			cmd.Process.Kill()
		}
		return map[string]any{"ok": false, "error": "spotify_player timed out"}
	}
}

func main() {
	newPlugin().serve(onCommand)
}
