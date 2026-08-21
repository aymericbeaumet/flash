// Local network addresses, in Go (one of the deliberately non-Rust official
// plugins exercising the language-agnostic wire protocol; see
// docs/plugin-protocol.md and AGENTS.md — Rust stays the default).
//
// Publishes every interface address plus the hostname as the catalog right
// after initialize is answered, each row copyable. Interfaces cannot be
// watched from userspace without privileged sockets, so a 30-second poll
// keeps the store fresh — publish IS the invalidation: the loop republishes
// only when the rows actually changed and stays silent otherwise (the host
// keeps the last-good catalog by construction).
package main

import (
	"fmt"
	"net"
	"os"
	"sort"
	"strconv"
	"time"

	"flashplugin"
)

const (
	sourceName  = "netinfo.addresses"
	pollSeconds = 30
)

func row(title, subtitle, copyText string) map[string]any {
	return map[string]any{
		"source": sourceName,
		"title":  title,
		"metadata": map[string]any{
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

	// refresh publishes the catalog iff it changed since the last publish —
	// no separate invalidation step exists in the protocol.
	refresh := func() {
		rows := catalog()
		fingerprint := fmt.Sprint(rows)
		if fingerprint == lastFingerprint {
			return
		}
		lastFingerprint = fingerprint
		plugin.Publish(rows)
		plugin.Log("debug", "[netinfo] publish", map[string]string{
			"outcome": map[bool]string{true: "empty", false: "ok"}[len(rows) == 0],
			"rows":    strconv.Itoa(len(rows)),
		})
	}

	plugin.Serve(flashplugin.Handlers{
		// OnStart runs after the initialize reply: the first publish lands
		// as soon as the catalog is built, then the poll loop takes over on
		// its own goroutine for the process lifetime.
		OnStart: func() {
			refresh()
			go func() {
				ticker := time.NewTicker(pollSeconds * time.Second)
				defer ticker.Stop()
				for range ticker.C {
					refresh()
				}
			}()
		},
	})
}
