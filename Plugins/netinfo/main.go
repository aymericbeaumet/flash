// Local network addresses, in Go (one of the deliberately non-Rust official
// plugins exercising the language-agnostic wire protocol; see
// docs/plugin-protocol.md and AGENTS.md — Rust stays the default).
//
// Publishes every interface address plus the hostname as the canonical
// `plugin:netinfo` warm catalog before initialize is answered (the
// readiness gate), each row copyable. Interfaces cannot be watched from
// userspace without privileged sockets, so a 30-second poll keeps the
// store fresh, invalidating only when the rows actually changed.
package main

import (
	"fmt"
	"net"
	"os"
	"sort"
	"time"

	"flashplugin"
)

const (
	sourceID    = "plugin:netinfo"
	sourceName  = "netinfo.addresses"
	pollSeconds = 30
)

func row(title, subtitle, copyText string) map[string]any {
	return map[string]any{
		"title": title,
		"metadata": map[string]any{
			"source":   sourceName,
			"kind":     "network_address",
			"subtitle": subtitle,
			"payload":  copyText,
		},
		"effect": map[string]any{"type": "copy_text", "text": copyText},
	}
}

// catalog builds the complete row set: per-interface unicast addresses
// (IPv4 first, loopback last so lo0 never outranks en0) plus the hostname.
func catalog() []map[string]any {
	rows := []map[string]any{}
	if hostname, err := os.Hostname(); err == nil && hostname != "" {
		rows = append(rows, row("hostname "+hostname, "local hostname", hostname))
	}
	interfaces, err := net.Interfaces()
	if err != nil {
		return rows
	}
	type entry struct {
		sortKey string
		row     map[string]any
	}
	entries := []entry{}
	for _, iface := range interfaces {
		if iface.Flags&net.FlagUp == 0 {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, addr := range addrs {
			ipNet, ok := addr.(*net.IPNet)
			if !ok || ipNet.IP.IsLinkLocalUnicast() {
				continue
			}
			family := "IPv6"
			if ipNet.IP.To4() != nil {
				family = "IPv4"
			}
			loopback := "0"
			if ipNet.IP.IsLoopback() {
				loopback = "1"
			}
			ip := ipNet.IP.String()
			entries = append(entries, entry{
				sortKey: loopback + family + iface.Name + ip,
				row:     row(iface.Name+" "+ip, family+" — "+iface.Name, ip),
			})
		}
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].sortKey < entries[j].sortKey })
	for _, e := range entries {
		rows = append(rows, e.row)
	}
	return rows
}

func main() {
	plugin := flashplugin.New()
	lastFingerprint := ""

	refresh := func() bool {
		rows := catalog()
		fingerprint := fmt.Sprint(rows)
		if fingerprint == lastFingerprint {
			return false
		}
		lastFingerprint = fingerprint
		plugin.SetLocations(sourceID, rows)
		plugin.Log("debug", fmt.Sprintf(
			"[netinfo] warm refresh outcome=%s candidates=%d",
			map[bool]string{true: "empty", false: "ok"}[len(rows) == 0], len(rows)))
		return true
	}

	plugin.Serve(flashplugin.Handlers{
		OnStart: func() {
			refresh() // warm store exists before initialize replies
			go func() {
				ticker := time.NewTicker(pollSeconds * time.Second)
				for range ticker.C {
					if refresh() {
						plugin.InvalidateSources()
					}
				}
			}()
		},
	})
}
