use std::collections::HashSet;

use chrono::DateTime;
use reqwest::Url;
use roxmltree::{Document, Node, ParsingOptions};

pub(crate) const MAX_BYTES: usize = 2 * 1024 * 1024;
const MAX_ITEMS: usize = 2000;
pub(crate) const WINDOW_SECONDS: i64 = 24 * 60 * 60;

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct Article {
    pub title: String,
    pub url: String,
    pub original_url: String,
    // Rich status text with external content already escaped by preview::render.
    pub preview: String,
    pub published_at: i64,
}

pub(crate) fn parse(xml: &str, now: i64) -> Result<Vec<Article>, &'static str> {
    if xml.len() > MAX_BYTES {
        return Err("feed exceeds byte limit");
    }
    let doc = Document::parse_with_options(
        xml,
        ParsingOptions {
            nodes_limit: 100_000,
            ..ParsingOptions::default()
        },
    )
    .map_err(|_| "invalid feed XML")?;
    let root = doc.root_element();
    if !root.has_tag_name("rss") {
        return Err("expected RSS feed");
    }
    let channel = root
        .children()
        .find(|node| node.has_tag_name("channel"))
        .ok_or("missing RSS channel")?;
    let items: Vec<_> = channel
        .children()
        .filter(|node| node.has_tag_name("item"))
        .collect();
    if items.len() > MAX_ITEMS {
        return Err("feed exceeds item limit");
    }
    let mut articles: Vec<_> = items
        .into_iter()
        .filter_map(|node| parse_item(node, now))
        .collect();
    articles.sort_by(|a, b| {
        b.published_at
            .cmp(&a.published_at)
            .then_with(|| a.url.cmp(&b.url))
            .then_with(|| a.title.cmp(&b.title))
    });
    let mut seen = HashSet::new();
    articles.retain(|article| seen.insert(article.url.clone()));
    Ok(articles)
}

fn child_text<'a>(node: Node<'a, '_>, tag: &str) -> Option<&'a str> {
    node.children()
        .find(|child| child.has_tag_name(tag))?
        .text()
}

fn parse_item(node: Node<'_, '_>, now: i64) -> Option<Article> {
    let published_at = DateTime::parse_from_rfc2822(child_text(node, "pubDate")?.trim())
        .ok()?
        .timestamp();
    if !is_recent(published_at, now) {
        return None;
    }
    let title = truncate(
        &child_text(node, "title")?
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" "),
        1000,
    );
    if title.is_empty() {
        return None;
    }
    let url = web_url(child_text(node, "link")?)?.to_string();
    let original_url = node
        .children()
        .filter(|child| child.has_tag_name(("http://www.w3.org/2005/Atom", "link")))
        .find(|child| child.attribute("rel") == Some("via"))
        .and_then(|child| child.attribute("href"))
        .and_then(web_url)
        .map(|url| url.to_string())
        .unwrap_or_else(|| url.clone());
    let content = node
        .children()
        .find(|child| child.has_tag_name(("http://purl.org/rss/1.0/modules/content/", "encoded")))
        .and_then(|child| child.text());
    let mut preview = crate::preview::render(content.unwrap_or_default());
    if preview.is_empty() {
        preview = crate::preview::render(child_text(node, "description").unwrap_or_default());
    }
    Some(Article {
        title,
        url,
        original_url,
        preview,
        published_at,
    })
}

pub(crate) fn is_recent(published_at: i64, now: i64) -> bool {
    published_at <= now && published_at > now.saturating_sub(WINDOW_SECONDS)
}

pub(crate) fn web_url(value: &str) -> Option<Url> {
    let url = Url::parse(value.trim()).ok()?;
    (matches!(url.scheme(), "https" | "http")
        && url.host_str().is_some()
        && url.username().is_empty()
        && url.password().is_none())
    .then_some(url)
}

pub(crate) fn truncate(value: &str, max_chars: usize) -> String {
    if value.chars().count() <= max_chars {
        value.to_string()
    } else {
        let mut result: String = value.chars().take(max_chars.saturating_sub(1)).collect();
        result.push('…');
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_783_598_400; // 2026-07-09 12:00 UTC

    fn document(items: &str) -> String {
        format!(
            r#"<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom" xmlns:content="http://purl.org/rss/1.0/modules/content/"><channel><title>Feed</title>{items}</channel></rss>"#
        )
    }

    fn item(title: &str, url: &str, at: i64, extra: &str) -> String {
        let date = chrono::DateTime::from_timestamp(at, 0)
            .unwrap()
            .to_rfc2822();
        format!(
            "<item><title>{title}</title><link>{url}</link><pubDate>{date}</pubDate>{extra}</item>"
        )
    }

    #[test]
    fn rss_extracts_archive_original_and_html_preview() {
        let xml = document(&item(
            "Rust &amp; RSS",
            "https://aggr.example/article",
            NOW - 1,
            r#"<description>Fallback</description><content:encoded><![CDATA[<style>hide me</style><p>Read <b>this</b> &amp; that.</p><script>bad()</script>]]></content:encoded><atom:link rel="via" href="https://www.example.com/article"/>"#,
        ));
        let articles = parse(&xml, NOW).unwrap();
        assert_eq!(
            articles,
            vec![Article {
                title: "Rust & RSS".into(),
                url: "https://aggr.example/article".into(),
                original_url: "https://www.example.com/article".into(),
                preview: crate::preview::render("<p>Read <b>this</b> &amp; that.</p>"),
                published_at: NOW - 1,
            }]
        );
    }

    #[test]
    fn last_day_window_excludes_expired_and_future_items_and_sorts_ties() {
        let xml = document(
            &[
                item("Old", "https://example.com/old", NOW - 86400, ""),
                item("Future", "https://example.com/future", NOW + 1, ""),
                item("B", "https://example.com/b", NOW, ""),
                item("Edge", "https://example.com/edge", NOW - 86399, ""),
                item("A", "https://example.com/a", NOW, ""),
                item("A", "https://example.com/a", NOW, ""),
            ]
            .concat(),
        );
        assert_eq!(
            parse(&xml, NOW)
                .unwrap()
                .iter()
                .map(|a| a.title.as_str())
                .collect::<Vec<_>>(),
            ["A", "B", "Edge"]
        );
    }

    #[test]
    fn missing_dates_and_unsafe_urls_are_skipped_description_is_fallback() {
        let xml = document(
            &[
                "<item><title>No date</title><link>https://example.com</link></item>".into(),
                item("Unsafe", "javascript:alert(1)", NOW, ""),
                item(
                    "OK",
                    "https://example.com/item",
                    NOW,
                    "<description><![CDATA[<p>Hello&nbsp;world</p>]]></description>",
                ),
            ]
            .concat(),
        );
        let articles = parse(&xml, NOW).unwrap();
        assert_eq!(articles.len(), 1);
        assert_eq!(articles[0].preview, "Hello world");
        assert_eq!(articles[0].original_url, articles[0].url);
    }

    #[test]
    fn malformed_xml_and_html_are_failures_valid_empty_rss_is_authoritative() {
        assert!(parse("<rss><channel>", NOW).is_err());
        assert!(parse("<html><body>Not a feed</body></html>", NOW).is_err());
        assert!(parse(&document(""), NOW).unwrap().is_empty());
    }

    #[test]
    fn title_is_plain_xml_text_and_html_preview_preserves_unicode() {
        let xml = document(&item(
            "Rust Vec&lt;T&gt; &amp; C#",
            "https://example.com/a",
            NOW,
            &format!(
                "<description><![CDATA[<p>{}</p>]]></description>",
                "é".repeat(4000)
            ),
        ));
        let articles = parse(&xml, NOW).unwrap();
        assert_eq!(articles[0].title, "Rust Vec<T> & C#");
        assert!(articles[0].preview.contains('é'));
        assert!(articles[0].preview.contains('…'));
        assert!(!articles[0].preview.contains('�'));
    }

    #[test]
    fn parser_rejects_oversized_input_and_excess_items() {
        assert!(parse(&" ".repeat(MAX_BYTES + 1), NOW).is_err());
        assert!(parse(&document(&"<item/>".repeat(MAX_ITEMS + 1)), NOW).is_err());
    }
}
