// Spotify playback controls backed by spotify_player, in Go (one of the
// six deliberately non-Rust official plugins exercising the
// language-agnostic wire protocol; see docs/plugin-protocol.md and
// AGENTS.md — Rust stays the default).
//
// Compiled by Scripts/build-plugins.sh like the Rust crates (go build,
// staged + signed with the same atomic-rename flow). Mirrors the Rust
// implementation: per-plugin config/cache dirs under
// FLASH_PLUGIN_DATA_DIR, and the plugin's bin/ dir prepended to PATH for
// the spotify_player lookup — the same convention the Rust SDK's
// run_command applies. Commands arrive as perform {kind: "command"}.
package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"flashplugin"
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
		tail = []string{"search", strings.Join(stringArgs(params), " ")}
	case "run":
		tail = stringArgs(params)
	default:
		return flashplugin.Fail("unknown subcommand: " + subcommand)
	}

	dataDir := flashplugin.DataDir()
	config := filepath.Join(dataDir, "config", "spotify-player")
	cache := filepath.Join(dataDir, "cache", "spotify-player")
	os.MkdirAll(config, 0o755)
	os.MkdirAll(cache, 0o755)

	argv := append(
		[]string{"--config-folder", config, "--cache-folder", cache},
		tail...,
	)
	cmd := exec.Command("spotify_player", argv...)
	// SDK run_command parity: the plugin's own bin/ dir wins the PATH
	// lookup so a plugin-managed spotify_player beats a global one.
	cmd.Env = append(os.Environ(),
		"PATH="+filepath.Join(dataDir, "bin")+":"+os.Getenv("PATH"))
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
			return flashplugin.Fail(message)
		}
		if message := strings.TrimSpace(string(output)); message != "" {
			return flashplugin.Ok(map[string]any{"message": message})
		}
		return flashplugin.Ok(nil)
	case <-time.After(timeout):
		if cmd.Process != nil {
			cmd.Process.Kill()
		}
		return flashplugin.Fail("spotify_player timed out")
	}
}

func stringArgs(params map[string]any) []string {
	var out []string
	if args, ok := params["args"].([]any); ok {
		for _, a := range args {
			if s, ok := a.(string); ok {
				out = append(out, s)
			}
		}
	}
	return out
}

func main() {
	flashplugin.New().Serve(flashplugin.Handlers{OnCommand: onCommand})
}
