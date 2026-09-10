use crate::feed::{self, Article};
use flash_plugin::{escape_status_text, inline_status_popup};
use reqwest::Url;
use std::time::Duration;

pub(crate) struct State {
    label: String,
    articles: Vec<Article>,
    current_url: Option<String>,
    published: Option<String>,
}

impl State {
    pub(crate) fn new(label: String) -> Self {
        Self {
            label,
            articles: Vec::new(),
            current_url: None,
            published: None,
        }
    }

    pub(crate) fn refresh(
        &mut self,
        articles: Result<Vec<Article>, ()>,
        now: i64,
    ) -> Option<String> {
        if let Ok(articles) = articles {
            self.articles = articles;
        }
        self.update(now, false)
    }

    pub(crate) fn cycle(&mut self, now: i64) -> Option<String> {
        self.update(now, true)
    }

    pub(crate) fn expire(&mut self, now: i64) -> Option<String> {
        self.update(now, false)
    }

    pub(crate) fn expires_in(&self, now: i64) -> Option<Duration> {
        self.articles
            .iter()
            .find(|article| Some(&article.url) == self.current_url.as_ref())
            .map(|article| {
                Duration::from_secs(
                    (article.published_at + feed::WINDOW_SECONDS - now).max(0) as u64
                )
            })
    }

    fn update(&mut self, now: i64, advance: bool) -> Option<String> {
        self.articles
            .retain(|article| feed::is_recent(article.published_at, now));
        let previous = self
            .articles
            .iter()
            .position(|article| Some(&article.url) == self.current_url.as_ref());
        let index = previous
            .map(|index| (index + usize::from(advance)) % self.articles.len())
            .unwrap_or(0);
        let selected = self.articles.get(index);
        self.current_url = selected.map(|article| article.url.clone());
        let summary = selected
            .map(|article| render(article, &self.label))
            .unwrap_or_default();
        if self.published.as_ref() == Some(&summary) {
            None
        } else {
            self.published = Some(summary.clone());
            Some(summary)
        }
    }
}

pub(crate) fn render(article: &Article, label: &str) -> String {
    let original = Url::parse(&article.original_url).expect("validated article URL");
    let domain = original.host_str().unwrap_or_default();
    let domain = escape_status_text(domain.strip_prefix("www.").unwrap_or(domain));
    let mut origin = original.clone();
    origin.set_path("/");
    origin.set_query(None);
    origin.set_fragment(None);
    let title = escape_status_text(&feed::truncate(&article.title, 160));
    let title_link = format!(
        "#[fg=colour245]#[link={}]#[shrink]{}#[noshrink]#[nolink]",
        marker_url(&article.url),
        title,
    );
    let popup_title = title;
    let preview = &article.preview;
    let body = if preview.is_empty() {
        format!("#[fg=colour178,bold]{popup_title}#[default]")
    } else {
        format!("#[fg=colour178,bold]{popup_title}#[default]\n\n{preview}")
    };
    let label = escape_status_text(label);
    let row = format!(
        "#[fg=#EBCB8B]{label}#[fg=colour245] #[cyc]{} #[link={}]({})#[nolink] #[fg=colour178]#[link={}]↗#[nolink]#[fg=colour245]#[nocyc]",
        title_link,
        marker_url(origin.as_str()),
        domain,
        marker_url(&article.original_url),
    );
    inline_status_popup(&row, &body)
}

fn marker_url(url: &str) -> String {
    url.replace('[', "%5B")
        .replace(']', "%5D")
        .replace(',', "%2C")
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

    #[test]
    fn refresh_preserves_rotation_and_failures_keep_last_good() {
        let articles: Vec<_> = ["A", "B", "C"]
            .into_iter()
            .map(|name| article(name, 100))
            .collect();
        let mut state = State::new("AGGR".into());
        assert_eq!(
            state.refresh(Ok(articles.clone()), 101),
            Some(render(&articles[0], "AGGR"))
        );
        assert_eq!(state.cycle(102), Some(render(&articles[1], "AGGR")));
        assert_eq!(state.refresh(Ok(articles.clone()), 103), None);
        assert_eq!(state.refresh(Err(()), 104), None);
        assert_eq!(state.cycle(105), Some(render(&articles[2], "AGGR")));
        assert_eq!(state.cycle(106), Some(render(&articles[0], "AGGR")));
    }

    #[test]
    fn cycling_expires_last_good_even_after_fetch_failure() {
        let a = article("A", 100);
        let b = article("B", 200);
        let mut state = State::new("AGGR".into());
        state.refresh(Ok(vec![a, b.clone()]), 201);
        assert_eq!(
            state.refresh(Err(()), 100 + feed::WINDOW_SECONDS),
            Some(render(&b, "AGGR"))
        );
        assert_eq!(state.cycle(200 + feed::WINDOW_SECONDS), Some(String::new()));
        assert_eq!(state.cycle(201 + feed::WINDOW_SECONDS), None);
    }

    #[test]
    fn valid_empty_refresh_clears_status() {
        let mut state = State::new("AGGR".into());
        state.refresh(Ok(vec![article("A", 100)]), 101);
        assert_eq!(state.refresh(Ok(vec![]), 102), Some(String::new()));
    }

    #[test]
    fn expiry_can_wake_before_next_cycle_without_advancing_a_fresh_title() {
        let a = article("A", 100);
        let b = article("B", 200);
        let mut state = State::new("AGGR".into());
        state.refresh(Ok(vec![a, b.clone()]), 201);
        assert_eq!(
            state.expires_in(99 + feed::WINDOW_SECONDS),
            Some(Duration::from_secs(1))
        );
        assert_eq!(state.expire(99 + feed::WINDOW_SECONDS), None);
        assert_eq!(
            state.expire(100 + feed::WINDOW_SECONDS),
            Some(render(&b, "AGGR"))
        );
        assert_eq!(
            state.expires_in(100 + feed::WINDOW_SECONDS),
            Some(Duration::from_secs(100))
        );
    }

    #[test]
    fn configured_label_is_escaped_and_stays_inside_whole_row_popup() {
        let mut state = State::new("#[bold]NEWS".into());
        let summary = state.refresh(Ok(vec![article("Title", 100)]), 101).unwrap();
        assert!(summary.starts_with("#[popup=inline:"));
        assert!(summary.contains("#[fg=#EBCB8B]##[bold]NEWS#[fg=colour245] "));
        assert!(summary.ends_with("#[nopopup]"));
        assert!(!summary.contains("AGGR"));
    }

    #[test]
    fn status_preserves_archive_source_links_popup_and_escaped_text() {
        let mut item = article("#[fg=red]Title", 100);
        item.url = "https://aggr.example/a,b]#[bold]".into();
        item.preview = crate::preview::render("Text #[bold]injection");
        let summary = render(&item, "AGGR");
        assert!(summary.contains("#[link=https://aggr.example/a%2Cb%5D#%5Bbold%5D]"));
        assert!(summary.contains("#[shrink]##[fg=red]Title#[noshrink]"));
        assert!(summary.contains("(source.example)"));
        assert!(summary.contains("#[link=https://www.source.example/original]"));
        assert!(summary.contains("↗"));
        assert!(summary.contains("%23%23%5Bbold%5Dinjection"));
    }

    #[test]
    fn whole_article_row_shares_one_terminal_preview_and_preserves_links() {
        let mut item = article("Title", 100);
        item.preview = crate::preview::render(
            "<h2>Opening</h2><p>First paragraph.</p><p>Second paragraph.</p>",
        );
        let summary = render(&item, "AGGR");
        let (row, suffix) = summary.split_once("#[nopopup]").unwrap();
        assert!(row.starts_with("#[popup=inline:"));
        assert!(row.contains("#[fg=#EBCB8B]AGGR#[fg=colour245] "));
        assert!(row.contains("#[link=https://aggr.example/Title]"));
        assert!(row.contains("First%20paragraph."));
        assert!(row.contains("Second%20paragraph."));
        assert!(row.contains("%0A%0A"));
        assert!(row.contains("#[link=https://www.source.example/](source.example)#[nolink]"));
        assert!(row.contains("#[link=https://www.source.example/original]↗#[nolink]"));
        assert!(suffix.is_empty());
        assert_eq!(summary.matches("#[popup=").count(), 1);
    }

    #[test]
    fn long_unicode_articles_keep_the_inline_preview_within_the_wire_limit() {
        let mut item = article("Title", 100);
        item.title = "🦀".repeat(1000);
        item.preview = crate::preview::render(&format!("<p>{}</p>", "🌍".repeat(1000)));
        let summary = render(&item, "AGGR");
        let encoded = summary
            .split_once("#[popup=inline:")
            .unwrap()
            .1
            .split_once(']')
            .unwrap()
            .0;
        assert!(encoded.len() <= 16_384);
        assert!(summary.contains("#[nopopup]"));
    }

    #[test]
    fn carousel_marks_article_content_only_and_repeated_refresh_does_not_rotate() {
        let mut state = State::new("NEWS".into());
        let a = article("Latest", 200);
        let b = article("Earlier", 100);
        let initial = state.refresh(Ok(vec![a.clone(), b.clone()]), 201).unwrap();
        assert!(initial.contains("#[fg=#EBCB8B]NEWS#[fg=colour245] #[cyc]"));
        assert!(initial.ends_with("#[nocyc]#[nopopup]"));
        assert_eq!(initial.matches("#[cyc]").count(), 1);
        assert_eq!(state.refresh(Ok(vec![a.clone(), b.clone()]), 202), None);
        assert_eq!(state.cycle(211), Some(render(&b, "NEWS")));
        assert_eq!(state.cycle(221), Some(render(&a, "NEWS")));
        assert_eq!(state.refresh(Ok(vec![a]), 222), None);
        assert_eq!(state.cycle(231), None);
    }
}
