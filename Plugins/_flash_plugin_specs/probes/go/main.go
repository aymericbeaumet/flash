// Conformance probe, in Go. See ../README.md — the normative behavior
// contract all seven per-language probes follow. Test fixture only: driven
// by Scripts/plugin-protocol-spec.py --probes, never shipped.
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"flashplugin"
)

const (
	sourceName = "conformance.items"
	targetPID  = 4242
)

// lastEvent needs no lock: OnEvent and OnCommand both run on the Serve
// dispatch goroutine.
var lastEvent = ""

// j is the message-field encoder: compact JSON (encoding/json keeps
// non-ASCII raw; it escapes <, >, & — specs never assert on those).
func j(value any) string {
	raw, err := json.Marshal(value)
	if err != nil {
		return "{}"
	}
	return string(raw)
}

func conformanceConfig() map[string]any {
	section, _ := flashplugin.Config()["conformance"].(map[string]any)
	return section
}

func catalog() []map[string]any {
	conf := conformanceConfig()
	if conf["empty_catalog"] == true {
		return []map[string]any{}
	}
	if count, isNumber := conf["catalog_rows"].(float64); isNumber {
		padBytes, _ := conf["row_pad"].(float64)
		pad := strings.Repeat("x", int(padBytes))
		rows := make([]map[string]any, 0, int(count))
		for i := 1; i <= int(count); i++ {
			rows = append(rows, map[string]any{
				"source": sourceName,
				"title":  fmt.Sprintf("row-%d%s", i, pad),
			})
		}
		return rows
	}
	return []map[string]any{
		{"source": sourceName, "title": "alpha", "metadata": map[string]any{"k": "v1"}},
		{"source": sourceName, "title": "béta ⚡ 名前"},
		{
			"source": sourceName,
			"title":  "gamma",
			"url":    "https://example.com/g",
			"effect": map[string]any{"type": "open", "url": "https://example.com/g"},
		},
	}
}

func answer(title string, subtitle string) map[string]any {
	out := map[string]any{
		"title":  title,
		"effect": map[string]any{"type": "copy_text", "text": title},
	}
	if subtitle != "" {
		out["subtitle"] = subtitle
	}
	return out
}

func stringArgs(params map[string]any) []string {
	raw, _ := params["args"].([]any)
	args := make([]string, 0, len(raw))
	for _, item := range raw {
		args = append(args, fmt.Sprint(item))
	}
	return args
}

func arg(args []string, index int, fallback string) string {
	if index < len(args) {
		return args[index]
	}
	return fallback
}

func intArg(args []string, index, fallback int) int {
	parsed, err := strconv.Atoi(arg(args, index, ""))
	if err != nil {
		return fallback
	}
	return parsed
}

type hostArm struct {
	method string
	params func(args []string) map[string]any
}

var hostArms = map[string]hostArm{
	"ping":  {"host.ping", func([]string) map[string]any { return map[string]any{} }},
	"fetch": {"host.fetch", func(a []string) map[string]any { return map[string]any{"url": arg(a, 0, "")} }},
	"open":  {"host.open", func(a []string) map[string]any { return map[string]any{"url": arg(a, 0, "")} }},
	"clipboard": {"host.clipboard_write",
		func(a []string) map[string]any { return map[string]any{"text": arg(a, 0, "")} }},
	"notify": {"host.notify",
		func(a []string) map[string]any { return map[string]any{"message": arg(a, 0, "")} }},
	"storage-set": {"host.storage_set",
		func(a []string) map[string]any { return map[string]any{"key": arg(a, 0, ""), "value": arg(a, 1, "")} }},
	"storage-get": {"host.storage_get",
		func(a []string) map[string]any { return map[string]any{"key": arg(a, 0, "")} }},
	"media": {"host.post_media_key",
		func(a []string) map[string]any { return map[string]any{"key_code": intArg(a, 0, 16)} }},
	"ps": {"host.process_table", func([]string) map[string]any { return map[string]any{} }},
	"signal": {"host.signal",
		func(a []string) map[string]any { return map[string]any{"pid": intArg(a, 0, targetPID)} }},
	"keys": {"host.post_keys", func([]string) map[string]any {
		return map[string]any{
			"pid":  targetPID,
			"keys": []any{map[string]any{"key_code": 4, "modifiers": []any{"command"}}},
		}
	}},
	"global-key": {"host.post_global_key", func([]string) map[string]any {
		return map[string]any{"key_code": 4, "modifiers": []any{"command"}}
	}},
	"ax-snapshot": {"host.ax_snapshot", func([]string) map[string]any {
		return map[string]any{"pid": targetPID, "roots": "app"}
	}},
	"activate": {"host.activate",
		func([]string) map[string]any { return map[string]any{"pid": targetPID} }},
	"normal-mode-target": {"host.normal_mode_target",
		func([]string) map[string]any { return map[string]any{} }},
}

func main() {
	plugin := flashplugin.New()

	plugin.Serve(flashplugin.Handlers{
		OnStart: func() {
			if conformanceConfig()["skip_publish"] == true {
				return
			}
			plugin.Publish(catalog())
		},
		OnEvent: func(name string, _ map[string]any) {
			lastEvent = name
		},
		OnEvaluate: func(params map[string]any) []map[string]any {
			switch params["query"] {
			case "conf:one":
				return []map[string]any{answer("one", "s")}
			case "conf:unicode":
				return []map[string]any{answer("héllo ⚡ 世界", "")}
			case "conf:many":
				answers := make([]map[string]any, 0, 17)
				for i := 1; i <= 17; i++ {
					answers = append(answers, answer(fmt.Sprintf("a%d", i), ""))
				}
				return answers
			}
			return []map[string]any{}
		},
		OnSearch: func(params map[string]any) []map[string]any {
			query, _ := params["query"].(string)
			rows := []map[string]any{}
			for _, row := range catalog() {
				if title, _ := row["title"].(string); strings.Contains(title, query) {
					rows = append(rows, row)
				}
			}
			return rows
		},
		OnHints: func(map[string]any) ([]map[string]any, int) {
			return []map[string]any{
				{
					"id":    "t1",
					"frame": map[string]any{"x": -10.5, "y": 20, "width": 30, "height": 40},
					"role":  "AXLink",
					"label": "one",
				},
				{
					"id":    "t2",
					"frame": map[string]any{"x": 0, "y": 0, "width": 10, "height": 10},
					"role":  "FlashTerminalLink",
					"label": "two",
				},
			}, 0
		},
		OnResolve: func(params map[string]any) map[string]any {
			row, _ := params["row"].(map[string]any)
			if row["title"] == "alpha" {
				return flashplugin.Ok(map[string]any{"target_pid": targetPID})
			}
			return flashplugin.Unhandled()
		},
		OnAction: func(params map[string]any) map[string]any {
			switch params["name"] {
			case "conf_performed":
				return flashplugin.Ok(map[string]any{"target_pid": targetPID})
			case "conf_failed":
				return flashplugin.Fail("conformance failure probe")
			}
			return flashplugin.Unhandled()
		},
		OnNavigate: func(params map[string]any) map[string]any {
			if params["url"] == "conformance://ok" {
				return flashplugin.Ok(nil)
			}
			return flashplugin.Unhandled()
		},
		OnCommand: func(params map[string]any) map[string]any {
			subcommand, _ := params["subcommand"].(string)
			args := stringArgs(params)
			switch subcommand {
			case "echo":
				raw, _ := params["raw"].(string)
				return flashplugin.Ok(map[string]any{
					"message": j(map[string]any{"args": args, "raw": raw}),
				})
			case "env":
				env := map[string]string{}
				for _, entry := range os.Environ() {
					key, value, _ := strings.Cut(entry, "=")
					env[key] = value
				}
				return flashplugin.Ok(map[string]any{"message": j(env)})
			case "env-has":
				if _, present := os.LookupEnv(arg(args, 0, "")); present {
					return flashplugin.Ok(map[string]any{"message": "present"})
				}
				return flashplugin.Ok(map[string]any{"message": "absent"})
			case "config":
				return flashplugin.Ok(map[string]any{"message": j(flashplugin.Config())})
			case "state":
				return flashplugin.Ok(map[string]any{"message": lastEvent})
			case "target-pid":
				return flashplugin.Ok(map[string]any{"target_pid": targetPID})
			case "toast":
				return flashplugin.Ok(map[string]any{"message": "hello from conformance"})
			case "sleep":
				time.Sleep(time.Duration(intArg(args, 0, 0)) * time.Millisecond)
				return flashplugin.Ok(nil)
			case "crash":
				os.Exit(intArg(args, 0, 1))
			case "exit-after-reply":
				code := intArg(args, 0, 0)
				go func() {
					time.Sleep(250 * time.Millisecond)
					os.Exit(code)
				}()
				return flashplugin.Ok(nil)
			case "stderr":
				os.Stderr.Write(bytes.Repeat([]byte("x"), intArg(args, 0, 0)*1024))
				return flashplugin.Ok(nil)
			case "log":
				rest := ""
				if len(args) > 1 {
					rest = strings.Join(args[1:], " ")
				}
				plugin.Log(arg(args, 0, "info"), rest, nil)
				return flashplugin.Ok(nil)
			case "status":
				plugin.Status(map[string]string{arg(args, 0, ""): arg(args, 1, "")})
				return flashplugin.Ok(nil)
			case "publish-extra":
				plugin.Publish(append(catalog(), map[string]any{"source": sourceName, "title": "delta"}))
				return flashplugin.Ok(nil)
			}
			if armed, known := hostArms[subcommand]; known {
				result := plugin.CallHost(armed.method, armed.params(args))
				return flashplugin.Ok(map[string]any{"message": j(result)})
			}
			return flashplugin.Fail("unsupported subcommand: " + subcommand)
		},
		OnShutdown: func() {
			plugin.Log("info", "conformance shutdown", nil)
		},
	})
}
