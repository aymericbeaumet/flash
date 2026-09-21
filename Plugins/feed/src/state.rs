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
    published: Published<StatusSegment>,
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
    ) -> Option<StatusSegment> {
        if let Ok(articles) = articles {
            self.articles = articles;
        }
        self.publish(now)
    }

    pub(crate) fn expire(&mut self, now: i64) -> Option<StatusSegment> {
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

    fn publish(&mut self, now: i64) -> Option<StatusSegment> {
        self.articles
            .retain(|article| feed::is_recent(article.published_at, now));
        let segment = if self.articles.is_empty() {
            StatusSegment::Value(StatusValue::empty())
        } else {
            StatusSegment::Carousel(
                StatusCarousel::new(self.articles.iter().map(render), self.cycle)
                    .with_prefix(prefix(&self.label)),
            )
        };
        self.published.update(segment).cloned()
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

    fn carousel(segment: Option<StatusSegment>) -> StatusCarousel {
        match segment {
            Some(StatusSegment::Carousel(carousel)) => carousel,
            other => panic!("expected a carousel, got {other:?}"),
        }
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
            Some(StatusSegment::Value(StatusValue::empty()))
        );
        assert_eq!(state.expires_in(200 + feed::WINDOW_SECONDS), None);
        assert_eq!(state.expire(201 + feed::WINDOW_SECONDS), None);
    }

    #[test]
    fn valid_empty_refresh_clears_status() {
        let mut state = State::new("AGGR".into(), Duration::from_secs(30));
        state.refresh(Ok(vec![article("A", 100)]), 101);
        assert_eq!(
            state.refresh(Ok(vec![]), 102),
            Some(StatusSegment::Value(StatusValue::empty()))
        );
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
