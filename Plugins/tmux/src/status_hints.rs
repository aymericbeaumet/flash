use unicode_width::UnicodeWidthChar;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum StatusHintKind {
    User,
    Window,
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct StatusHintSpan {
    pub kind: StatusHintKind,
    pub index: u32,
    pub column: usize,
    pub width: usize,
    pub label: String,
}

/// Parse a tmux-expanded status-format row whose layout is entirely left-aligned.
/// Unsupported layout controls and overflowing rows return no geometry: tmux's
/// list scrolling, padding and alignment must never become guessed click points.
pub(crate) fn parse_status_hints(line: &str, client_columns: usize) -> Option<Vec<StatusHintSpan>> {
    let mut parser = StatusParser {
        limit: client_columns,
        column: 0,
        current: None,
        spans: vec![],
    };
    let mut chars = line.chars().peekable();
    while let Some(character) = chars.next() {
        if character != '#' {
            parser.append(character)?;
            continue;
        }

        let mut hashes: usize = 1;
        while chars.peek() == Some(&'#') {
            chars.next();
            hashes += 1;
        }
        let style_follows = hashes % 2 == 1 && chars.peek() == Some(&'[');
        for _ in 0..if style_follows {
            hashes / 2
        } else {
            hashes.div_ceil(2)
        } {
            parser.append('#')?;
        }
        if style_follows {
            chars.next();
            let mut style = String::new();
            loop {
                match chars.next()? {
                    ']' => break,
                    character => style.push(character),
                }
            }
            parser.apply_style(&style)?;
        }
    }
    parser.finish_range();
    Some(parser.spans)
}

struct StatusParser {
    limit: usize,
    column: usize,
    current: Option<StatusHintSpan>,
    spans: Vec<StatusHintSpan>,
}

impl StatusParser {
    fn append(&mut self, character: char) -> Option<()> {
        if character.is_control() {
            return None;
        }
        let width = UnicodeWidthChar::width(character)?;
        self.column = self.column.checked_add(width)?;
        if self.column > self.limit {
            return None;
        }
        if let Some(span) = &mut self.current {
            span.width += width;
            span.label.push(character);
        }
        Some(())
    }

    fn finish_range(&mut self) {
        if let Some(span) = self.current.take()
            && span.width > 0
        {
            self.spans.push(span);
        }
    }

    fn apply_style(&mut self, style: &str) -> Option<()> {
        for token in style.split([',', ' ']).filter(|token| !token.is_empty()) {
            let token = token.to_ascii_lowercase();
            if token == "norange" {
                self.finish_range();
            } else if let Some(range) = token.strip_prefix("range=") {
                let (kind, index) = range.split_once('|')?;
                let kind = match kind {
                    "user" => StatusHintKind::User,
                    "window" => StatusHintKind::Window,
                    _ => return None,
                };
                if index.is_empty() || !index.bytes().all(|byte| byte.is_ascii_digit()) {
                    return None;
                }
                let index = index.parse().ok()?;
                if self
                    .current
                    .as_ref()
                    .is_some_and(|span| span.kind == kind && span.index == index)
                {
                    continue;
                }
                self.finish_range();
                self.current = Some(StatusHintSpan {
                    kind,
                    index,
                    column: self.column,
                    width: 0,
                    label: String::new(),
                });
            } else if !matches!(
                token.as_str(),
                "align=left" | "noalign" | "nolist" | "noignore"
            ) && !is_visual_style(&token)
            {
                return None;
            }
        }
        Some(())
    }
}

fn is_visual_style(token: &str) -> bool {
    if matches!(
        token,
        "default" | "push-default" | "pop-default" | "set-default" | "none"
    ) {
        return true;
    }
    if let Some((key, value)) = token.split_once('=') {
        return matches!(key, "fg" | "bg" | "us" | "fill") && is_color(value);
    }
    matches!(
        token.strip_prefix("no").unwrap_or(token),
        "bold"
            | "bright"
            | "dim"
            | "underscore"
            | "blink"
            | "reverse"
            | "hidden"
            | "italics"
            | "strikethrough"
            | "double-underscore"
            | "curly-underscore"
            | "dotted-underscore"
            | "dashed-underscore"
            | "overline"
    )
}

fn is_color(value: &str) -> bool {
    if let Some(hex) = value.strip_prefix('#') {
        return hex.len() == 6 && hex.bytes().all(|byte| byte.is_ascii_hexdigit());
    }
    if let Some(index) = value
        .strip_prefix("colour")
        .or_else(|| value.strip_prefix("color"))
    {
        return index.parse::<u8>().is_ok();
    }
    matches!(
        value,
        "default"
            | "terminal"
            | "black"
            | "red"
            | "green"
            | "yellow"
            | "blue"
            | "magenta"
            | "cyan"
            | "white"
            | "brightblack"
            | "brightred"
            | "brightgreen"
            | "brightyellow"
            | "brightblue"
            | "brightmagenta"
            | "brightcyan"
            | "brightwhite"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_custom_window_tabs_across_color_changes() {
        let line = "#[align=left] [scratch@macbook]  #[range=user|1 fg=colour245]1:flash#[norange]  #[range=user|2]2:#[fg=colour0 bg=colour178 bold]notes#[bg=default nobold]#[norange]  ";
        assert_eq!(
            parse_status_hints(line, 80),
            Some(vec![
                StatusHintSpan {
                    kind: StatusHintKind::User,
                    index: 1,
                    column: 20,
                    width: 7,
                    label: "1:flash".into(),
                },
                StatusHintSpan {
                    kind: StatusHintKind::User,
                    index: 2,
                    column: 29,
                    width: 7,
                    label: "2:notes".into(),
                },
            ])
        );
    }

    #[test]
    fn uses_cell_columns_for_wide_and_combining_characters() {
        let spans =
            parse_status_hints("界e\u{301} #[range=window|3]3:文e\u{301}#[norange]", 40).unwrap();
        assert_eq!(spans[0].kind, StatusHintKind::Window);
        assert_eq!(spans[0].index, 3);
        assert_eq!(spans[0].column, 4);
        assert_eq!(spans[0].width, 5);
        assert_eq!(spans[0].label, "3:文e\u{301}");
    }

    #[test]
    fn handles_escaped_hashes_and_style_looking_literal_text() {
        let spans = parse_status_hints(
            "##[range=user|8] ### #[range=window|2]###[bold]2:#x#[norange]",
            80,
        )
        .unwrap();
        assert_eq!(spans.len(), 1);
        assert_eq!(spans[0].column, 19);
        assert_eq!(spans[0].width, 5);
        assert_eq!(spans[0].label, "#2:#x");
    }

    #[test]
    fn range_transition_and_end_of_line_close_spans() {
        let spans =
            parse_status_hints("#[range=window|1]one#[range=window|2]two#[default]2", 10).unwrap();
        assert_eq!(spans.len(), 2);
        assert_eq!((spans[0].column, spans[0].width), (0, 3));
        assert_eq!((spans[1].column, spans[1].width), (3, 4));
        assert_eq!(spans[1].label, "two2");
    }

    #[test]
    fn rejects_layouts_whose_rendered_positions_are_not_known() {
        for prefix in [
            "#[align=right]",
            "#[align=centre]",
            "#[align=absolute-centre]",
            "#[list=on]",
            "#[list=focus]",
            "#[list=left-marker]",
            "#[width=10]",
            "#[pad=2]",
            "#[ignore]",
            "#[range=left]",
            "#[range=right]",
            "#[range=session|$0]",
        ] {
            assert_eq!(
                parse_status_hints(&format!("{prefix}#[range=window|1]one"), 80),
                None,
                "{prefix}"
            );
        }
        assert_eq!(parse_status_hints("#[range=window|1]too long", 7), None);
    }

    #[test]
    fn rejects_malformed_styles_ranges_and_control_characters() {
        for line in [
            "#[range=window|1",
            "#[range=window|@1]one",
            "#[range=user|name]one",
            "#[range=window|-1]one",
            "#[range=window|1]one\ntwo",
            "#[range=window|1]one\ttwo",
            "#[range=window|1]one\0two",
            "#[unknown-style]#[range=window|1]one",
        ] {
            assert_eq!(parse_status_hints(line, 80), None, "{line:?}");
        }
    }

    #[test]
    fn empty_and_non_tab_lines_have_no_targets() {
        assert_eq!(parse_status_hints("", 80), Some(vec![]));
        assert_eq!(parse_status_hints("#[fg=red]plain", 80), Some(vec![]));
        assert_eq!(
            parse_status_hints("#[range=user|1]#[norange]", 80),
            Some(vec![])
        );
        assert_eq!(parse_status_hints("#[range=user|1]one", 0), None);
    }
}
