//! Static HTTP status-code catalog.

use flash_plugin::{run, Candidate, Context};

const SOURCE: &str = "httpstatus.codes";
const MAX_STATUSES: usize = 128;
const STATUSES_TSV: &str = include_str!("../statuses.tsv");

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct Status<'a> {
    code: &'a str,
    reason: &'a str,
    category: &'a str,
}

fn parse_statuses(input: &str) -> Vec<Status<'_>> {
    input
        .lines()
        .filter_map(|raw| {
            let line = raw.trim_matches(|character| character == ' ' || character == '\r');
            if line.is_empty() || line.starts_with('#') {
                return None;
            }
            let mut fields = line.split('\t');
            Some(Status {
                code: fields.next()?,
                reason: fields.next()?,
                category: fields.next()?,
            })
        })
        .take(MAX_STATUSES)
        .collect()
}

fn candidate(status: Status<'_>) -> Candidate {
    Candidate::new(SOURCE, format!("{} {}", status.code, status.reason))
        .url(format!(
            "https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Status/{}",
            status.code
        ))
        .kind("http_status")
        .subtitle(format!("HTTP {}", status.category))
        .payload(status.code)
}

fn build_candidates(input: &str) -> Vec<Candidate> {
    parse_statuses(input).into_iter().map(candidate).collect()
}

struct HttpStatus;

flash_plugin::plugin!(HttpStatus);

impl FlashPlugin for HttpStatus {
    async fn on_start(&self, ctx: Context) {
        ctx.publish(build_candidates(STATUSES_TSV));
        ctx.log("info", "[httpstatus] status table published");
    }
}

fn main() {
    run(HttpStatus);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parser_skips_comments_and_malformed_rows_without_reordering() {
        let statuses = parse_statuses(
            " # comment\r\n200\tOK\tsuccess\textra\nmissing\tcategory\n 418\tI'm a Teapot\tclient error\r",
        );

        assert_eq!(
            statuses,
            [
                Status {
                    code: "200",
                    reason: "OK",
                    category: "success",
                },
                Status {
                    code: "418",
                    reason: "I'm a Teapot",
                    category: "client error",
                },
            ]
        );
    }

    #[test]
    fn candidates_preserve_the_catalog_contract() {
        let row = candidate(Status {
            code: "418",
            reason: "I'm a Teapot",
            category: "client error",
        });

        assert_eq!(row.source, SOURCE);
        assert_eq!(row.title, "418 I'm a Teapot");
        assert_eq!(
            row.url.as_deref(),
            Some("https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Status/418")
        );
        assert_eq!(row.meta("kind"), Some("http_status"));
        assert_eq!(row.meta("subtitle"), Some("HTTP client error"));
        assert_eq!(row.payload_str(), Some("418"));
        assert!(row.effect.is_none());
    }

    #[test]
    fn embedded_table_is_complete_and_ordered() {
        let statuses = parse_statuses(STATUSES_TSV);
        assert_eq!(statuses.len(), 61);
        assert_eq!(statuses.first().map(|status| status.code), Some("100"));
        assert_eq!(statuses.last().map(|status| status.code), Some("511"));
    }
}
