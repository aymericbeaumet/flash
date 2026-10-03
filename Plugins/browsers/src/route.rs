//! `flash-browser://tab?pid=<pid>&url=<url>` — or `&title=<title>` for a tab
//! that exposes no URL — is the durable location every tab row carries
//! (`navigation_url`) and every tab pick returns. Movement history restores
//! it through `perform {kind: "navigate"}`, dispatched here by the manifest's
//! `navigation` scheme. The URL identity survives title changes; the pid
//! scopes it to one browser process, so a restarted browser's stale routes
//! fail instead of landing in another edition.

const PREFIX: &str = "flash-browser://tab?";

/// What identifies the tab inside its browser.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TabTarget {
    Url(String),
    Title(String),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TabRoute {
    pub pid: i64,
    pub target: TabTarget,
}

impl TabRoute {
    /// The route for a tab: its URL when known, else its title. `None`
    /// without either, or without a real pid.
    pub fn new(pid: i64, url: &str, title: &str) -> Option<Self> {
        if pid <= 0 {
            return None;
        }
        let target = if !url.is_empty() {
            TabTarget::Url(url.to_string())
        } else if !title.is_empty() {
            TabTarget::Title(title.to_string())
        } else {
            return None;
        };
        Some(Self { pid, target })
    }

    /// Every byte outside RFC 3986's unreserved set is percent-encoded, so
    /// the host's URL parser round-trips the route unchanged.
    pub fn to_url(&self) -> String {
        let (key, value) = match &self.target {
            TabTarget::Url(url) => ("url", url),
            TabTarget::Title(title) => ("title", title),
        };
        format!("{PREFIX}pid={}&{key}={}", self.pid, percent_encode(value))
    }

    /// Strict inverse of [`to_url`](Self::to_url): a positive pid and
    /// exactly one non-empty `url` or `title`. Unknown or repeated keys
    /// reject the route.
    pub fn parse(raw: &str) -> Option<Self> {
        let query = raw.strip_prefix(PREFIX)?;
        let mut pid = None;
        let mut target = None;
        for pair in query.split('&') {
            let (key, value) = pair.split_once('=')?;
            let value = percent_decode(value)?;
            match key {
                "pid" if pid.is_none() => pid = Some(value.parse::<i64>().ok()?),
                "url" if target.is_none() && !value.is_empty() => {
                    target = Some(TabTarget::Url(value))
                }
                "title" if target.is_none() && !value.is_empty() => {
                    target = Some(TabTarget::Title(value))
                }
                _ => return None,
            }
        }
        Some(Self {
            pid: pid.filter(|pid| *pid > 0)?,
            target: target?,
        })
    }
}

fn percent_encode(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    for byte in raw.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                out.push(byte as char)
            }
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

/// `None` for a malformed escape or a decoding that is not UTF-8.
fn percent_decode(raw: &str) -> Option<String> {
    let bytes = raw.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hex = std::str::from_utf8(bytes.get(i + 1..i + 3)?).ok()?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn url_routes_round_trip_and_ignore_title_changes() {
        let url = "https://example.com/a b?q=1&r=é#frag";
        let route = TabRoute::new(99, url, "Page").unwrap();
        let raw = route.to_url();
        assert!(raw.starts_with("flash-browser://tab?pid=99&url=https%3A%2F%2Fexample.com"));
        assert_eq!(TabRoute::parse(&raw), Some(route));
        assert_eq!(raw, TabRoute::new(99, url, "Page (1)").unwrap().to_url());
    }

    #[test]
    fn title_routes_cover_tabs_without_urls() {
        let route = TabRoute::new(7, "", "Inbox — Mail").unwrap();
        assert_eq!(route.target, TabTarget::Title("Inbox — Mail".into()));
        assert_eq!(TabRoute::parse(&route.to_url()), Some(route));
        assert_eq!(TabRoute::new(7, "", ""), None);
        assert_eq!(TabRoute::new(0, "https://example.com/", ""), None);
    }

    #[test]
    fn parse_rejects_anything_but_one_pid_and_one_identity() {
        for raw in [
            "flash-browser://tab?pid=0&url=https%3A%2F%2Fexample.com",
            "flash-browser://tab?pid=-4&title=Same",
            "flash-browser://tab?pid=99",
            "flash-browser://tab?pid=99&title=",
            "flash-browser://tab?pid=99&url=https%3A%2F%2Fexample.com&title=Same",
            "flash-browser://tab?pid=99&pid=98&title=Same",
            "flash-browser://tab?pid=99&id=11",
            "flash-browser://tab?pid=99&title=%E9",
            "flash-browser://tab?pid=99&title=%4",
            "flash-browser://window?pid=99&title=Same",
            "flash-firefox://tab?pid=99&title=Same",
        ] {
            assert_eq!(TabRoute::parse(raw), None, "{raw}");
        }
    }
}
