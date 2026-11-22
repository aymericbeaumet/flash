//! Link extraction from pane text: plain URL/path matches and OSC 8 spans.

use std::sync::OnceLock;

use regex::Regex;

use crate::pane_capture;

fn link_pattern() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        // Quoted shell-style paths (which may contain spaces / Unicode) · URLs ·
        // $VAR / ${VAR} shell-style env-prefixed paths · ~/ and / paths · ./ ../
        // relative paths · dotted host/path tokens · bare file.ext names · E####
        // error codes (Rust/cargo, etc.). The trailing `:LINE[:COL]` editor-jump
        // suffix is folded into the unquoted path-shaped alternatives.
        //
        // The bare `host.ext` alternative requires the final segment to start
        // with a letter and be 2+ chars (`\.[a-zA-Z][\w-]+`) so noise tokens —
        // file sizes (`8.2k`), abbreviations (`e.g`), versions (`v0.1.0`) —
        // don't masquerade as links, while real filenames/domains (`Cargo.toml`,
        // `README.md`, `beside.com`, `t.io`) still match. URLs and slash-paths
        // are unaffected.
        let pattern = r#""(?:/|~/|\./|\.\./|\$\w+/|\$\{\w+\}/)[^"\r\n]+"|'(?:/|~/|\./|\.\./|\$\w+/|\$\{\w+\}/)[^'\r\n]+'|https?://[\w./\-?&=@%+:~#!$,;*()]+[\w/]|\$\{?\w+\}?(?:/[\w./\-]+)+|(?:~|/)[^\s\]\r\n][^\s\]\r\n]*\.[\w-]+(?:/[^\s\]\r\n]+)*(?::\d+(?::\d+)?)?|(?:\.{1,2}/)[^\s\]\r\n][^\s\]\r\n]*\.[\w-]+(?:/[^\s\]\r\n]+)*(?::\d+(?::\d+)?)?|[\w.@\-]+(?:/[^\s\]\r\n][^\s\]\r\n]*)+\.[\w-]+(?:/[^\s\]\r\n]+)*(?::\d+(?::\d+)?)?|[\w.@\-]+\.[a-zA-Z][\w-]+(?::\d+(?::\d+)?)?|(?-u:\b)E\d{4}(?-u:\b)"#;
        Regex::new(pattern).expect("tmux link regex")
    })
}

/// A bare `Type.lowerCamelMember` is source syntax, not a file or host. Slash
/// paths remain path-shaped regardless of their final component, and ordinary
/// lowercase extensions (`.swift`, `.toml`, `.com`) are unaffected.
fn is_dotted_code_identifier(text: &str) -> bool {
    if text.contains('/') {
        return false;
    }
    let Some((owner, member)) = text.rsplit_once('.') else {
        return false;
    };
    if owner.is_empty() || member.is_empty() {
        return false;
    }

    let mut chars = member.chars();
    chars.next().is_some_and(|first| first.is_ascii_lowercase())
        && chars.any(|character| character.is_ascii_uppercase())
}

/// A real clickable URL, as opposed to a path, dotted host or error code.
pub(crate) fn is_url(text: &str) -> bool {
    text.starts_with("http://") || text.starts_with("https://")
}

/// Yield `(column, text)` for each link match on a line, bounded by `max_cols`
/// columns. Columns use display cells, including wide and combining text.
fn extract_links(line: &str, max_cols: usize) -> Vec<(usize, String)> {
    use unicode_width::UnicodeWidthStr;
    let mut out = Vec::new();
    for m in link_pattern().find_iter(line) {
        let raw = m.as_str();
        let (leading_quote_cols, raw) = if let Some(inner) = raw
            .strip_prefix('"')
            .and_then(|text| text.strip_suffix('"'))
        {
            (1, inner)
        } else if let Some(inner) = raw
            .strip_prefix('\'')
            .and_then(|text| text.strip_suffix('\''))
        {
            (1, inner)
        } else {
            (0, raw)
        };
        let col = line[..m.start()].width() + leading_quote_cols;
        if col >= max_cols {
            continue;
        }
        let text = raw.trim_end_matches(['.', ',', ';', ':', ')', ']', '}', '>']);
        if text.is_empty() || is_dotted_code_identifier(text) {
            continue;
        }
        out.push((col, text.to_string()));
    }
    out
}

pub(crate) fn captured_links(
    content: &pane_capture::Line,
    columns: usize,
) -> Vec<(usize, String, Option<String>)> {
    use unicode_width::UnicodeWidthStr;
    let mut links: Vec<_> = content
        .links
        .iter()
        .filter(|link| pane_capture::http_uri(&link.uri))
        .map(|link| {
            (
                content.column(link.start),
                content.text[link.start..link.end].to_string(),
                Some(link.uri.clone()),
            )
        })
        .collect();
    for (col, text) in extract_links(&content.text, columns) {
        // An OSC span owns its label, including an unsafe destination whose
        // URL-shaped label must not masquerade as an ordinary clickable URL.
        if content.links.iter().any(|link| {
            col < content.column(link.end) && col + text.width() > content.column(link.start)
        }) {
            continue;
        }
        links.push((col, text, None));
    }
    links
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plain_link_columns_follow_terminal_cells() {
        assert_eq!(
            extract_links("界 e\u{301} 👩‍💻 https://example.com", 80),
            vec![(8, "https://example.com".into())]
        );
    }

    #[test]
    fn extract_links_keeps_port_and_path() {
        let only = |s: &str| extract_links(s, 1000).into_iter().next().map(|(_, t)| t);
        assert_eq!(
            only("https://admin.test.com:1234").as_deref(),
            Some("https://admin.test.com:1234")
        );
        assert_eq!(
            only("https://google.com:443/test/a/b/c").as_deref(),
            Some("https://google.com:443/test/a/b/c")
        );
        assert_eq!(
            only("open https://admin.test.com:1234/x?y=1 now").as_deref(),
            Some("https://admin.test.com:1234/x?y=1")
        );
    }

    #[test]
    fn extract_links_keeps_quoted_unicode_and_relative_paths() {
        assert_eq!(
            extract_links(r#""/Applications/Flash 🧪.app""#, 1000),
            vec![(1, "/Applications/Flash 🧪.app".to_string())]
        );
        assert_eq!(
            extract_links(r#""/Applications/Flash 🧪.app/Contents/MacOS/flash""#, 1000),
            vec![(
                1,
                "/Applications/Flash 🧪.app/Contents/MacOS/flash".to_string()
            )]
        );
        assert_eq!(
            extract_links("edit Sources/FlashCore/JumpTarget.swift", 1000),
            vec![(5, "Sources/FlashCore/JumpTarget.swift".to_string())]
        );
        assert_eq!(
            extract_links(r#""Sources/FlashCore/JumpTarget.swift""#, 1000),
            vec![(1, "Sources/FlashCore/JumpTarget.swift".to_string())]
        );
        assert_eq!(
            extract_links("open ~/.dotfiles/setup.sh", 1000),
            vec![(5, "~/.dotfiles/setup.sh".to_string())]
        );
    }

    #[test]
    fn extract_links_drops_dotted_code_identifiers() {
        assert!(extract_links("JumpTarget.isTextInput", 1000).is_empty());
        assert!(extract_links("SomeType.someHTTPHandler", 1000).is_empty());

        assert_eq!(
            extract_links("JumpTarget.swift", 1000),
            vec![(0, "JumpTarget.swift".to_string())]
        );
    }

    #[test]
    fn extract_links_drops_size_abbrev_version_noise() {
        let has = |line: &str, want: &str| extract_links(line, 1000).iter().any(|(_, t)| t == want);
        // Real filenames / domains / URLs are kept.
        assert!(has("see Cargo.toml here", "Cargo.toml"));
        assert!(has("open README.md now", "README.md"));
        assert!(has("ship config.default.toml ok", "config.default.toml"));
        assert!(has("host beside.com is up", "beside.com"));
        assert!(has(
            "go to https://app.beside.com x",
            "https://app.beside.com"
        ));
        assert!(has("edit src/main.rs:42 fast", "src/main.rs:42"));
        // Noise must NOT be matched as links.
        for (line, junk) in [
            ("size 8.2k total", "8.2k"),
            ("for e.g. this", "e.g"),
            ("tag v0.1.0 rc", "v0.1.0"),
        ] {
            assert!(!has(line, junk), "expected {junk:?} to be dropped");
        }
    }
}
