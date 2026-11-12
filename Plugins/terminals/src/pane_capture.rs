//! A bounded tmux grid snapshot, never a terminal stream. Only printable
//! cells, SGR and OSC metadata are accepted; nothing is executed or replayed.
use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

const MAX_CAPTURE_BYTES: usize = 1024 * 1024;
const MAX_CONTROL_BYTES: usize = 8192;
const MAX_LINK_BYTES: usize = 1024 * 1024;

#[derive(Debug, PartialEq, Eq)]
pub struct Link {
    pub start: usize,
    pub end: usize,
    pub uri: String,
}

#[derive(Debug, Default, PartialEq, Eq)]
pub struct Line {
    pub text: String,
    pub links: Vec<Link>,
}

impl Line {
    pub fn column(&self, byte: usize) -> usize {
        self.text[..byte].width()
    }
}

pub fn http_uri(uri: &str) -> bool {
    let Some(rest) = uri
        .strip_prefix("https://")
        .or_else(|| uri.strip_prefix("http://"))
    else {
        return false;
    };
    !rest.split(['/', '?', '#']).next().unwrap_or("").is_empty()
        && !uri
            .chars()
            .any(|c| c.is_control() || c.is_whitespace() || c == '\\')
}

fn finish_link(
    line: &mut Line,
    start: &mut usize,
    uri: &Option<String>,
    link_bytes: &mut usize,
) -> Option<()> {
    if let Some(uri) = uri
        && *start < line.text.len()
    {
        *link_bytes = link_bytes.checked_add(uri.len())?;
        if *link_bytes > MAX_LINK_BYTES {
            return None;
        }
        line.links.push(Link {
            start: *start,
            end: line.text.len(),
            uri: uri.clone(),
        });
    }
    *start = line.text.len();
    Some(())
}

fn supported_cell_width(text: &str) -> bool {
    // unicode-width applies script ligatures that tmux does not necessarily
    // combine. Decline ambiguous rows rather than put a target on another cell.
    let script_ligatures = text.chars().any(|c| {
        matches!(c,
        '\u{0590}'..='\u{08ff}' | '\u{1780}'..='\u{17ff}' | '\u{1a00}'..='\u{1a1f}' |
        '\u{2d30}'..='\u{2d7f}' | '\u{a4d0}'..='\u{a4ff}' |
        '\u{10c00}'..='\u{10c4f}' | '\u{16d40}'..='\u{16d7f}')
    });
    !script_ligatures || text.width() == text.chars().map(|c| c.width().unwrap_or(0)).sum::<usize>()
}

pub fn parse(raw: &str, columns: usize, rows: usize) -> Option<Vec<Line>> {
    if raw.len() > MAX_CAPTURE_BYTES
        || !(1..=16_384).contains(&columns)
        || !(1..=16_384).contains(&rows)
    {
        return None;
    }
    let bytes = raw.as_bytes();
    let mut i = 0;
    let mut lines = Vec::new();
    let mut line = Line::default();
    let mut uri = None;
    let mut start = 0;
    let mut link_bytes = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'\n' => {
                finish_link(&mut line, &mut start, &uri, &mut link_bytes)?;
                if !supported_cell_width(&line.text)
                    || line.text.width() > columns
                    || lines.len() >= rows
                {
                    return None;
                }
                lines.push(line);
                line = Line::default();
                start = 0;
                i += 1;
            }
            0x1b => {
                let begin = i;
                i += 1;
                match *bytes.get(i)? {
                    b'[' => {
                        i += 1;
                        while (0x20..=0x3f).contains(bytes.get(i)?) {
                            i += 1;
                            if i - begin > MAX_CONTROL_BYTES {
                                return None;
                            }
                        }
                        if *bytes.get(i)? != b'm' {
                            return None;
                        }
                        i += 1;
                    }
                    b']' => {
                        i += 1;
                        let payload_start = i;
                        while !matches!(*bytes.get(i)?, 0x07 | 0x1b) {
                            if bytes[i].is_ascii_control() {
                                return None;
                            }
                            i += 1;
                            if i - begin > MAX_CONTROL_BYTES {
                                return None;
                            }
                        }
                        let payload = raw.get(payload_start..i)?;
                        if bytes[i] == 0x1b {
                            if *bytes.get(i + 1)? != b'\\' {
                                return None;
                            }
                            i += 2;
                        } else {
                            i += 1;
                        }
                        if let Some(link) = payload.strip_prefix("8;") {
                            let (_, target) = link.split_once(';')?;
                            finish_link(&mut line, &mut start, &uri, &mut link_bytes)?;
                            uri = (!target.is_empty()).then(|| target.to_string());
                        }
                    }
                    _ => return None,
                }
            }
            // tmux's capture may switch DEC character sets; these occupy no cells.
            0x0e | 0x0f => {
                i += 1;
            }
            0..=0x1f | 0x7f => return None,
            _ => {
                let character = raw.get(i..)?.chars().next()?;
                if character.is_control() {
                    return None;
                }
                line.text.push(character);
                i += character.len_utf8();
            }
        }
    }
    finish_link(&mut line, &mut start, &uri, &mut link_bytes)?;
    if !line.text.is_empty() || lines.is_empty() {
        if !supported_cell_width(&line.text) || line.text.width() > columns || lines.len() >= rows {
            return None;
        }
        lines.push(line);
    }
    Some(lines)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn osc8_tracks_wrapped_labels_and_both_terminators_without_style_width() {
        let lines = parse("界e\u{301} 👩‍💻 \x1b[4m\x1b]8;id=x;https://example.com\x07read\nmore\x1b]8;;\x1b\\\x1b[0m", 80, 2).unwrap();
        assert_eq!(lines[0].text, "界e\u{301} 👩‍💻 read");
        assert_eq!(lines[0].column(lines[0].links[0].start), 7);
        assert_eq!(lines[1].text, "more");
        assert_eq!(lines[1].links[0].uri, "https://example.com");
    }

    #[test]
    fn unknown_osc_is_metadata_only_and_unsafe_links_are_identifiable() {
        let lines = parse(
            "\x1b]52;c;secret\x07\x1b]8;;file:///tmp/a\x07https://example.com\x1b]8;;\x07",
            80,
            1,
        )
        .unwrap();
        assert_eq!(lines[0].text, "https://example.com");
        assert!(!http_uri(&lines[0].links[0].uri));
        for uri in [
            "javascript:alert(1)",
            "https:///path",
            "https://x\n.example",
            "https://x\\y",
        ] {
            assert!(!http_uri(uri), "{uri}");
        }
    }

    #[test]
    fn malformed_oversized_or_non_grid_controls_reject_the_capture() {
        for raw in [
            "\x1b]8;;unterminated",
            "\x1b[4",
            "\x1b[2Jhello",
            "a\tb",
            "\x1b]8;missing\x07",
            "\x1b]8;;a\n\x07",
        ] {
            assert!(parse(raw, 80, 24).is_none(), "{raw:?}");
        }
        assert!(parse(&"x".repeat(MAX_CAPTURE_BYTES + 1), MAX_CAPTURE_BYTES + 1, 1).is_none());
        assert!(parse("界", 1, 1).is_none());
        assert!(parse("a\nb", 80, 1).is_none());
    }

    #[test]
    fn repeated_destinations_cannot_amplify_a_small_capture_without_bound() {
        let uri = format!("https://example.com/{}", "x".repeat(4000));
        let raw = format!("\x1b]8;;{uri}\x07{}", "a\n".repeat(300));
        assert!(raw.len() < 8192);
        assert!(parse(&raw, 80, 300).is_none());
    }

    #[test]
    fn script_ligature_width_ambiguity_rejects_the_grid() {
        assert!(parse("لا https://example.com", 80, 1).is_none());
        assert!(parse("א\u{200d}ל https://example.com", 80, 1).is_none());
        assert!(parse("界 e\u{301} 👩‍💻 https://example.com", 80, 1).is_some());
    }
}
