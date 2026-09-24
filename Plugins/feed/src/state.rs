use crate::feed::{self, Article};
use flash_plugin::{
    Color, Markup, Preview, Published, StatusCarousel, StatusSegment, StatusValue, Style,
};
use reqwest::Url;
use std::time::Duration;

/// The articles inside the rolling window, published as one host-rotated
/// carousel: Flash owns the cadence and the visible line, the plugin only
/// republishes when the set changes.
pub(crate) struct State {
    label: String,
    cycle: Duration,
    articles: Vec<Article>,
    published: Published<Segments>,
}

/// The two segments the plugin owns. `summary` keeps the links and the inline
/// article preview; `label` is popup-free and link-free so a template binding
/// owns hover and clicks, exactly as the system monitors do. Publishing both
/// lets a configuration choose its own popup — a terminal running any reader —
/// without the plugin deciding what hovering a headline should show.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Segments {
    pub(crate) summary: StatusSegment,
    pub(crate) label: StatusSegment,
}

impl State {
    pub(crate) fn new(label: String, cycle: Duration) -> Self {
        Self {
            label,
            cycle,
            articles: Vec::new(),
            published: Published::new(),
        }
    }

    pub(crate) fn refresh(
        &mut self,
        articles: Result<Vec<Article>, ()>,
        now: i64,
    ) -> Option<Segments> {
        if let Ok(articles) = articles {
            self.articles = articles;
        }
        self.publish(now)
    }

    pub(crate) fn expire(&mut self, now: i64) -> Option<Segments> {
        self.publish(now)
    }

    /// Time until the oldest retained article leaves the window.
    pub(crate) fn expires_in(&self, now: i64) -> Option<Duration> {
        self.articles
            .iter()
            .map(|article| (article.published_at + feed::WINDOW_SECONDS - now).max(0) as u64)
            .min()
            .map(Duration::from_secs)
    }

    fn publish(&mut self, now: i64) -> Option<Segments> {
        self.articles
            .retain(|article| feed::is_recent(article.published_at, now));
        let segments = if self.articles.is_empty() {
            Segments {
                summary: StatusSegment::Value(StatusValue::empty()),
                label: StatusSegment::Value(StatusValue::empty()),
            }
        } else {
            Segments {
                summary: StatusSegment::Carousel(
                    StatusCarousel::new(self.articles.iter().map(render), self.cycle)
                        .with_prefix(prefix(&self.label)),
                ),
                label: StatusSegment::Carousel(
                    StatusCarousel::new(self.articles.iter().map(render_label), self.cycle)
                        .with_prefix(prefix(&self.label)),
                ),
            }
        };
        self.published.update(segments).cloned()
    }
}

/// The still label drawn before every line.
pub(crate) fn prefix(label: &str) -> Markup {
    Markup::raw(format!(
        "#[fg={title_color}]{label}#[fg={muted}] ",
        title_color = Color::TITLE,
        muted = Color::MUTED,
        label = Markup::text(label),
    ))
}

/// One carousel line: the elastic linked title, the origin domain, and the
/// outbound arrow, sharing one article preview.
pub(crate) fn render(article: &Article) -> StatusValue {
    let original = Url::parse(&article.original_url).expect("validated article URL");
    let domain = original.host_str().unwrap_or_default();
    let domain = Markup::text(domain.strip_prefix("www.").unwrap_or(domain));
    let mut origin = original.clone();
    origin.set_path("/");
    origin.set_query(None);
    origin.set_fragment(None);
    let title = Markup::text(feed::truncate(&article.title, 160));
    let mut preview = Preview::new().raw(Markup::styled(
        title.clone(),
        Style::fg(Color::ACCENT).bold(),
    ));
    if !article.preview.is_empty() {
        preview = preview.blank().raw(&article.preview);
    }
    let row = Markup::raw(format!(
        "{title} {source} #[fg={accent}]{outbound}#[fg={muted}]",
        muted = Color::MUTED,
        accent = Color::ACCENT,
        title = Markup::link(
            Markup::raw("#[shrink]") + title + "#[noshrink]",
            &article.url
        ),
        source = Markup::link(format!("({domain})"), origin.as_str()),
        outbound = Markup::link("↗", &article.original_url),
    ));
    StatusValue::text(row).with_preview(preview)
}

/// One popup-free carousel line: the elastic title and its origin domain form
/// a single link to the feed item, with no outbound arrow and no inline
/// preview. Only the click destination is data the plugin owns; hover belongs
/// to the surrounding template, so a configuration can point the segment at any
/// popup it likes. The still prefix stays outside the link, so a template link
/// wrapping the segment addresses the feed rather than any one item.
pub(crate) fn render_label(article: &Article) -> StatusValue {
    let original = Url::parse(&article.original_url).expect("validated article URL");
    let domain = original.host_str().unwrap_or_default();
    let domain = Markup::text(domain.strip_prefix("www.").unwrap_or(domain));
    let title = Markup::text(feed::truncate(&article.title, 160));
    let row = Markup::raw(format!("#[shrink]{title}#[noshrink] ({domain})"));
    StatusValue::text(Markup::raw(format!(
        "{item}#[fg={muted}]",
        muted = Color::MUTED,
        item = Markup::link(row, &article.url),
    )))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn article(name: &str, published_at: i64) -> Article {
        Article {
            title: name.into(),
            url: format!("https://aggr.example/{name}"),
            original_url: "https://www.source.example/original".into(),
            preview: "A preview".into(),
            published_at,
        }
    }

    fn carousel(segments: Option<Segments>) -> StatusCarousel {
        match segments.map(|segments| segments.summary) {
            Some(StatusSegment::Carousel(carousel)) => carousel,
            other => panic!("expected a carousel, got {other:?}"),
        }
    }

    fn label_carousel(segments: Option<Segments>) -> StatusCarousel {
        match segments.map(|segments| segments.label) {
            Some(StatusSegment::Carousel(carousel)) => carousel,
            other => panic!("expected a carousel, got {other:?}"),
        }
    }

    fn cleared() -> Option<Segments> {
        Some(Segments {
            summary: StatusSegment::Value(StatusValue::empty()),
            label: StatusSegment::Value(StatusValue::empty()),
        })
    }

    #[test]
    fn refresh_publishes_recent_articles_as_one_host_carousel_and_failures_keep_last_good() {
        let articles: Vec<_> = ["A", "B", "C"]
            .into_iter()
            .map(|name| article(name, 100))
            .collect();
        let mut state = State::new("AGGR".into(), Duration::from_secs(30));
        let published = carousel(state.refresh(Ok(articles.clone()), 101));
        assert_eq!(
            published.lines,
            articles.iter().map(render).collect::<Vec<_>>()
        );
        assert_eq!(published.cycle, Duration::from_secs(30));
        assert_eq!(published.prefix, prefix("AGGR"));
        assert_eq!(state.refresh(Ok(articles.clone()), 103), None);
        assert_eq!(state.refresh(Err(()), 104), None);
        let reordered: Vec<_> = articles.iter().rev().cloned().collect();
        assert_eq!(
            carousel(state.refresh(Ok(reordered.clone()), 105)).lines,
            reordered.iter().map(render).collect::<Vec<_>>()
        );
    }

    #[test]
    fn expiry_drops_old_articles_and_clears_when_none_remain() {
        let a = article("A", 100);
        let b = article("B", 200);
        let mut state = State::new("AGGR".into(), Duration::from_secs(30));
        state.refresh(Ok(vec![a, b.clone()]), 201);
        assert_eq!(
            state.expires_in(99 + feed::WINDOW_SECONDS),
            Some(Duration::from_secs(1))
        );
        assert_eq!(state.expire(99 + feed::WINDOW_SECONDS), None);
        assert_eq!(
            carousel(state.expire(100 + feed::WINDOW_SECONDS)).lines,
            vec![render(&b)]
        );
        assert_eq!(
            state.expires_in(100 + feed::WINDOW_SECONDS),
            Some(Duration::from_secs(100))
        );
        assert_eq!(
            state.refresh(Err(()), 200 + feed::WINDOW_SECONDS),
            cleared()
        );
        assert_eq!(state.expires_in(200 + feed::WINDOW_SECONDS), None);
        assert_eq!(state.expire(201 + feed::WINDOW_SECONDS), None);
    }

    #[test]
    fn valid_empty_refresh_clears_status() {
        let mut state = State::new("AGGR".into(), Duration::from_secs(30));
        state.refresh(Ok(vec![article("A", 100)]), 101);
        assert_eq!(state.refresh(Ok(vec![]), 102), cleared());
    }

    #[test]
    fn label_mirrors_the_summary_carousel_with_one_item_link_and_no_preview() {
        let articles: Vec<_> = ["A", "B"].into_iter().map(|n| article(n, 100)).collect();
        let mut state = State::new("AGGR".into(), Duration::from_secs(30));
        let published = state.refresh(Ok(articles.clone()), 101);
        let summary = carousel(published.clone());
        let label = label_carousel(published);
        assert_eq!(label.cycle, summary.cycle);
        assert_eq!(label.prefix, summary.prefix);
        assert_eq!(
            label.lines,
            articles.iter().map(render_label).collect::<Vec<_>>()
        );
        for (line, source) in label.lines.iter().zip(&articles) {
            let rendered = line.visible.as_str();
            // Title and domain share one link to the feed item; the arrow and
            // the inline preview are gone, so hover belongs to the template.
            assert_eq!(
                rendered.matches("#[link=").count(),
                1,
                "title and domain must form a single clickable link"
            );
            assert!(rendered.contains(&format!("#[link={}]", source.url)));
            assert!(!rendered.contains("\u{2197}"));
            assert!(line.preview.is_none());
        }
    }

    #[test]
    fn configured_label_is_escaped_in_the_still_prefix() {
        let label = prefix("#[bold]NEWS");
        assert_eq!(label.as_str(), "#[fg=#EBCB8B]##[bold]NEWS#[fg=colour245] ");
    }

    #[test]
    fn line_preserves_archive_source_links_popup_and_escaped_text() {
        let mut item = article("#[fg=red]Title", 100);
        item.url = "https://aggr.example/a,b]#[bold]".into();
        item.preview = crate::preview::render("Text #[bold]injection");
        let line = render(&item).render().unwrap();
        assert!(line.starts_with("#[popup=inline:"));
        assert!(line.ends_with("#[nopopup]"));
        assert!(line.contains("#[link=https://aggr.example/a%2Cb%5D#%5Bbold%5D]"));
        assert!(line.contains("#[shrink]##[fg=red]Title#[noshrink]"));
        assert!(line.contains("(source.example)"));
        assert!(line.contains("#[link=https://www.source.example/original]"));
        assert!(line.contains("↗"));
        assert!(line.contains("%23%23%5Bbold%5Dinjection"));
        assert!(
            !line.contains("AGGR"),
            "the label is the still prefix, not part of a line"
        );
    }

    #[test]
    fn line_preview_keeps_its_structure_after_the_title() {
        let mut item = article("Title", 100);
        item.preview = crate::preview::render(
            "<h2>Opening</h2><p>First paragraph.</p><p>Second paragraph.</p>",
        );
        let line = render(&item).render().unwrap();
        let (row, suffix) = line.split_once("#[nopopup]").unwrap();
        assert!(suffix.is_empty());
        assert!(row.contains("Title"));
        let (marker, _) = row.split_once(']').unwrap();
        assert!(marker.contains("Opening"));
        assert!(marker.contains("First"));
    }
}
