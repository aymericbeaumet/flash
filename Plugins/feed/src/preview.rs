use flash_plugin::escape_status_text;
use scraper::{Html, Node};

const MAX_CHARS: usize = 900;
const MAX_LINES: usize = 12;
const MAX_MARKUP_BYTES: usize = 4000;

#[derive(Clone, Copy, Default, Eq, PartialEq)]
struct Style {
    bold: bool,
    italics: bool,
    heading: bool,
    code: bool,
}

pub(crate) fn render(html: &str) -> String {
    let fragment = Html::parse_fragment(html);
    let mut excerpt = Excerpt::default();
    let mut pending = vec![(fragment.tree.root(), false, Style::default(), false)];
    while let Some((node, exiting, mut style, mut preformatted)) = pending.pop() {
        if excerpt.truncated {
            break;
        }
        match node.value() {
            Node::Text(text) => excerpt.text(text, style, preformatted),
            Node::Element(element) => {
                let name = element.name();
                if matches!(name, "script" | "style" | "template" | "noscript") {
                    continue;
                }
                let breaks = match name {
                    "p" | "div" | "section" | "article" | "h1" | "h2" | "h3" | "h4" | "h5"
                    | "h6" | "ul" | "ol" | "blockquote" | "pre" | "hr" => 2,
                    "li" | "br" | "tr" => 1,
                    _ => 0,
                };
                let starts_prefixed_paragraph = !exiting
                    && name == "p"
                    && node
                        .parent()
                        .and_then(|parent| parent.value().as_element())
                        .is_some_and(|parent| matches!(parent.name(), "li" | "blockquote"))
                    && !node.prev_siblings().any(|sibling| match sibling.value() {
                        Node::Text(text) => !text.trim().is_empty(),
                        Node::Element(_) => true,
                        _ => false,
                    });
                if !starts_prefixed_paragraph {
                    excerpt.line_break(breaks);
                }
                if exiting {
                    continue;
                }
                match name {
                    "h1" | "h2" | "h3" | "h4" | "h5" | "h6" => {
                        style.bold = true;
                        style.heading = true;
                    }
                    "strong" | "b" => style.bold = true,
                    "em" | "i" => style.italics = true,
                    "code" | "pre" => style.code = true,
                    _ => {}
                }
                preformatted |= name == "pre";
                if name == "li" {
                    let parent = node.parent().and_then(|parent| parent.value().as_element());
                    let prefix = if let Some(parent) = parent.filter(|parent| parent.name() == "ol")
                    {
                        let start = parent
                            .attr("start")
                            .and_then(|n| n.parse::<i64>().ok())
                            .unwrap_or(1);
                        let preceding = node
                            .prev_siblings()
                            .filter(|sibling| {
                                sibling
                                    .value()
                                    .as_element()
                                    .is_some_and(|element| element.name() == "li")
                            })
                            .count() as i64;
                        format!("{}. ", start.saturating_add(preceding))
                    } else {
                        "• ".to_string()
                    };
                    excerpt.text(&prefix, style, false);
                } else if name == "blockquote" {
                    style.italics = true;
                    excerpt.text("│ ", style, false);
                }
                pending.push((node, true, style, preformatted));
                pending.extend(
                    node.children()
                        .collect::<Vec<_>>()
                        .into_iter()
                        .rev()
                        .map(|child| (child, false, style, preformatted)),
                );
            }
            _ => pending.extend(
                node.children()
                    .collect::<Vec<_>>()
                    .into_iter()
                    .rev()
                    .map(|child| (child, false, style, preformatted)),
            ),
        }
    }
    excerpt.finish()
}

#[derive(Default)]
struct Excerpt {
    chars: Vec<(char, Style)>,
    newlines: usize,
    pending_breaks: usize,
    pending_space: bool,
    truncated: bool,
}

impl Excerpt {
    fn line_break(&mut self, count: usize) {
        self.pending_breaks = self.pending_breaks.max(count);
    }

    fn push(&mut self, ch: char, style: Style) {
        if self.chars.len() >= MAX_CHARS || (ch == '\n' && self.newlines >= MAX_LINES - 1) {
            self.truncated = true;
        } else if !self.truncated {
            self.newlines += usize::from(ch == '\n');
            self.chars.push((ch, style));
        }
    }

    fn text(&mut self, text: &str, style: Style, preformatted: bool) {
        for ch in text.chars() {
            if self.truncated {
                return;
            }
            if !preformatted && ch.is_whitespace() {
                self.pending_space = true;
                continue;
            }
            if ch.is_control() && !(preformatted && matches!(ch, '\n' | '\t')) {
                continue;
            }
            if !self.chars.is_empty() {
                if self.pending_breaks > 0 {
                    let existing = self
                        .chars
                        .iter()
                        .rev()
                        .take_while(|(ch, _)| *ch == '\n')
                        .count();
                    for _ in existing..self.pending_breaks {
                        self.push('\n', Style::default());
                    }
                } else if self.pending_space {
                    self.push(' ', style);
                }
            }
            self.pending_breaks = 0;
            self.pending_space = false;
            if ch == '\t' {
                for _ in 0..4 {
                    self.push(' ', style);
                }
            } else {
                self.push(ch, style);
            }
        }
    }

    fn finish(mut self) -> String {
        while self.chars.last().is_some_and(|(ch, _)| ch.is_whitespace()) {
            self.chars.pop();
        }
        if self.truncated {
            if self.chars.len() == MAX_CHARS {
                self.chars.pop();
            }
            let style = self
                .chars
                .last()
                .map(|(_, style)| *style)
                .unwrap_or_default();
            self.chars.push(('…', style));
        }
        // Serialize only the bounded excerpt, so truncation cannot split a marker.
        let mut output = String::new();
        let mut current = Style::default();
        for &(ch, style) in &self.chars {
            if style != current {
                if current != Style::default() {
                    output.push_str("#[default]");
                }
                let mut attrs = Vec::new();
                if style.bold {
                    attrs.push("bold");
                }
                if style.italics {
                    attrs.push("italics");
                }
                if style.heading {
                    attrs.push("fg=colour178");
                } else if style.code {
                    attrs.push("fg=colour246");
                }
                if !attrs.is_empty() {
                    output.push_str(&format!("#[{}]", attrs.join(",")));
                }
                current = style;
            }
            output.push_str(&escape_status_text(&ch.to_string()));
        }
        if current != Style::default() {
            output.push_str("#[default]");
        }
        // Keep percent-encoded inline bodies below the host's marker limit,
        // even when an article alternates styling on every character.
        if output.len() > MAX_MARKUP_BYTES {
            escape_status_text(&self.chars.iter().map(|(ch, _)| ch).collect::<String>())
        } else {
            output
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn visible(markup: &str) -> String {
        let mut chars = markup.chars().peekable();
        let mut text = String::new();
        while let Some(ch) = chars.next() {
            if ch == '#' && chars.peek() == Some(&'#') {
                chars.next();
                text.push('#');
            } else if ch == '#' && chars.peek() == Some(&'[') {
                for ch in chars.by_ref() {
                    if ch == ']' {
                        break;
                    }
                }
            } else {
                text.push(ch);
            }
        }
        text
    }

    #[test]
    fn opening_paragraphs_headings_lists_and_quotes_remain_readable() {
        let html = "<h2>Opening</h2><p>First <strong>important</strong> paragraph.</p><p>Second <em>thought</em>.</p><ul><li>One</li><li>Two</li></ul><blockquote>A quote</blockquote>";
        let markup = render(html);
        assert_eq!(
            visible(&markup),
            "Opening\n\nFirst important paragraph.\n\nSecond thought.\n\n• One\n• Two\n\n│ A quote"
        );
        assert!(markup.contains("bold"));
        assert!(markup.contains("italics"));
    }

    #[test]
    fn preformatted_code_retains_indentation_and_line_breaks() {
        assert_eq!(visible(&render("<p>Example <code>x &lt; y</code>:</p><pre><code>fn main() {\n    run();\n}</code></pre>")), "Example x < y:\n\nfn main() {\n    run();\n}");
    }

    #[test]
    fn whitespace_entities_and_hidden_content_are_normalized() {
        assert_eq!(
            render("<style>bad</style><script>bad</script><template><p>bad</p></template>"),
            ""
        );
        assert_eq!(
            visible(&render(
                "<p> Hello&nbsp;\n world &amp; <span>friends</span>! </p><div> Next<br>line </div>"
            )),
            "Hello world & friends!\n\nNext\nline"
        );
    }

    #[test]
    fn ordered_lists_use_their_start_number() {
        assert_eq!(
            visible(&render("<ol start=3><li>Third</li><li>Fourth</li></ol>")),
            "3. Third\n4. Fourth"
        );
    }

    #[test]
    fn paragraphs_inside_lists_and_quotes_stay_with_their_prefix() {
        assert_eq!(
            visible(&render(
                "<ul><li><p>Item</p></li></ul><blockquote><p>Quote</p></blockquote>"
            )),
            "• Item\n\n│ Quote"
        );
    }

    #[test]
    fn deeply_nested_html_is_walked_without_recursion() {
        assert_eq!(
            render(&format!(
                "{}Opening{}",
                "<div>".repeat(4000),
                "</div>".repeat(4000)
            )),
            "Opening"
        );
    }

    #[test]
    fn pathological_styling_stays_within_inline_popup_byte_budget() {
        let markup = render(&"<b>🦀</b>x".repeat(450));
        assert!(markup.len() <= MAX_MARKUP_BYTES);
        assert_eq!(visible(&markup), "🦀x".repeat(450));
    }

    #[test]
    fn truncation_is_unicode_safe_and_closes_styles() {
        let markup = render(&format!("<strong>{}</strong>", "é".repeat(1000)));
        let text = visible(&markup);
        assert_eq!(text.chars().count(), 900);
        assert!(text.ends_with('…'));
        assert!(markup.ends_with("#[default]"));
        assert_eq!(visible(&render(&"é".repeat(900))), "é".repeat(900));
    }

    #[test]
    fn excerpt_has_at_most_twelve_lines_and_marks_omitted_content() {
        let markup = render(&"<p>A paragraph.</p>".repeat(20));
        let text = visible(&markup);
        assert!(text.lines().count() <= 12);
        assert!(text.ends_with('…'));
        assert_eq!(render("<p>Complete.</p>"), "Complete.");
    }

    #[test]
    fn external_markup_and_terminal_controls_cannot_escape_text() {
        let markup = render("<p>#[bold] #{E:secret} #(command) \u{1b}[31mred\u{7}\u{9b}hide</p>");
        assert!(markup.contains("##[bold] ##{E:secret} ##(command)"));
        assert!(!markup.chars().any(|ch| ch.is_control() && ch != '\n'));
        assert!(visible(&markup).contains("#[bold] #{E:secret} #(command)"));
    }

    #[test]
    fn nested_emphasis_restores_the_outer_style() {
        let markup = render("<strong>Bold <em>both</em> still bold</strong> plain");
        assert_eq!(visible(&markup), "Bold both still bold plain");
        assert!(markup.contains("#[default]#[bold] still bold"));
    }
}
