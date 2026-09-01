use std::collections::HashSet;
use std::sync::Arc;
use std::time::{Duration, Instant};

use flash_plugin::QueryAnswer;

use crate::rates::{ExchangeRates, RatesStore, SnapshotRateHandler};

const MAX_QUERY_CHARS: usize = 256;
// One absolute budget covers the primary expression and every configured
// target conversion; adding currencies must never multiply hot-path latency.
const EVALUATION_BUDGET: Duration = Duration::from_millis(10);

struct Deadline(Instant);

impl fend_core::Interrupt for Deadline {
    fn should_interrupt(&self) -> bool {
        Instant::now() >= self.0
    }
}

pub(crate) fn evaluate(
    raw_query: &str,
    rates: &RatesStore,
    target_currencies: &[String],
) -> Vec<QueryAnswer> {
    let query = raw_query.trim();
    let query = query.strip_prefix('=').map(str::trim).unwrap_or(query);
    if !should_evaluate(query) {
        return Vec::new();
    }

    let snapshot = rates.snapshot();
    let mut context = fend_context(Arc::clone(&snapshot));
    let deadline = Deadline(Instant::now() + EVALUATION_BUDGET);
    let result = fend_core::evaluate_preview_with_interrupt(query, &context, &deadline);
    let mut primary = result.get_main_result().trim().to_string();
    // Preview suppresses identity-shaped output — a value that renders exactly
    // as it was typed — which otherwise drops a bare number like `12.5` or a
    // bare currency quantity like `10 euros`. Both are useful answers (a plain
    // number so it can be copied; a currency so target conversions derive from
    // it), so fall back to full evaluation for those. App-name-shaped queries
    // still error out of fend and stay out of the answer lane.
    if primary.is_empty()
        && (is_plain_number(query) || looks_like_currency_result(query, &snapshot))
    {
        if let Ok(result) = fend_core::evaluate_with_interrupt(query, &mut context, &deadline) {
            primary = result.get_main_result().trim().to_string();
        }
    }
    let primary = primary.trim();
    if primary.is_empty() {
        return Vec::new();
    }

    let mut seen = HashSet::new();
    let mut candidates = Vec::new();
    push_answer(&mut candidates, &mut seen, primary, query, None);

    if looks_like_currency_result(primary, &snapshot) && !snapshot.as_of.is_empty() {
        for target in target_currencies {
            let conversion = format!("({query}) to {target}");
            let result =
                fend_core::evaluate_preview_with_interrupt(&conversion, &context, &deadline);
            let converted = result.get_main_result().trim();
            if converted.is_empty() {
                continue;
            }
            let subtitle = format!("{query} -> {target} · ECB {}", snapshot.as_of);
            push_answer(&mut candidates, &mut seen, converted, query, Some(subtitle));
        }
    }

    candidates
}

fn fend_context(rates: Arc<ExchangeRates>) -> fend_core::Context {
    let mut context = fend_core::Context::new();
    context.set_exchange_rate_handler_v2(SnapshotRateHandler(rates));
    context
}

fn should_evaluate(query: &str) -> bool {
    !query.is_empty()
        && query.chars().count() <= MAX_QUERY_CHARS
        && query.chars().any(|character| character.is_ascii_digit())
        && !matches!(
            query.as_bytes().first(),
            Some(b'!') | Some(b'@') | Some(b':')
        )
}

/// A dimensionless numeric literal such as `123`, `12.5`, or `-0.5`. fend's
/// preview evaluator returns nothing for these (the rendered value equals the
/// input), so they need the full-evaluation fallback to surface as their own
/// copyable answer instead of collapsing the bar to "no matching app".
fn is_plain_number(query: &str) -> bool {
    let digits = query.strip_prefix(['+', '-']).unwrap_or(query);
    let mut seen_dot = false;
    let mut seen_digit = false;
    for character in digits.chars() {
        match character {
            '0'..='9' => seen_digit = true,
            '.' if !seen_dot => seen_dot = true,
            _ => return false,
        }
    }
    seen_digit
}

fn looks_like_currency_result(result: &str, rates: &ExchangeRates) -> bool {
    if result.contains(['$', '€', '£', '¥', '₹']) {
        return true;
    }
    let words = result
        .split(|character: char| !character.is_ascii_alphanumeric())
        .filter(|word| !word.is_empty())
        .collect::<Vec<_>>();
    if words.iter().any(|word| {
        matches!(
            word.to_ascii_lowercase().as_str(),
            "euro"
                | "euros"
                | "dollar"
                | "dollars"
                | "pound"
                | "pounds"
                | "yen"
                | "yuan"
                | "rupee"
                | "rupees"
        )
    }) {
        return true;
    }
    words
        .into_iter()
        .filter(|word| word.len() == 3)
        .map(str::to_ascii_uppercase)
        .any(|word| rates.currencies().any(|currency| currency == word))
}

fn push_answer(
    candidates: &mut Vec<QueryAnswer>,
    seen: &mut HashSet<String>,
    answer: &str,
    query: &str,
    subtitle: Option<String>,
) {
    let answer = format_answer(answer);
    if !seen.insert(answer.clone()) {
        return;
    }
    let subtitle = subtitle.unwrap_or_else(|| query.to_string());
    candidates.push(QueryAnswer::copy_text(answer, Some(subtitle)));
}

fn format_answer(answer: &str) -> String {
    answer
        .strip_prefix("approx. ")
        .map(|value| format!("≈ {value}"))
        .unwrap_or_else(|| answer.to_string())
}

#[cfg(test)]
mod tests {
    use super::evaluate;
    use crate::rates::{parse_ecb_xml, RatesStore};

    #[test]
    fn evaluates_arithmetic_and_copies_answer() {
        let candidates = evaluate("1+1", &RatesStore::default(), &["USD".to_string()]);
        assert_eq!(candidates.len(), 1);
        assert_eq!(candidates[0].title, "2");
        assert_eq!(
            serde_json::to_value(&candidates[0]).unwrap()["effect"]["type"],
            "copy_text"
        );
        assert_eq!(
            serde_json::to_value(&candidates[0]).unwrap()["effect"]["text"],
            "2"
        );
    }

    #[test]
    fn equals_marker_is_calculator_owned_syntax() {
        let candidates = evaluate("= 10 * 10", &RatesStore::default(), &[]);
        assert_eq!(candidates[0].title, "100");
    }

    #[test]
    fn ignores_plain_catalog_queries_and_explicit_sigil_syntax() {
        let rates = RatesStore::default();
        assert!(evaluate("Safari", &rates, &[]).is_empty());
        assert!(evaluate("!google 1+1", &rates, &[]).is_empty());
        assert!(evaluate("@apps 1+1", &rates, &[]).is_empty());
    }

    #[test]
    fn echoes_bare_numbers_so_they_are_copyable() {
        // A bare number renders identically to its input, so fend's preview
        // returns nothing. The full-evaluation fallback surfaces it as its own
        // copyable answer instead of the bar collapsing to "no matching app".
        let rates = RatesStore::default();
        for query in ["12.5", "123", "0.5", "-3"] {
            let candidates = evaluate(query, &rates, &[]);
            assert_eq!(candidates.len(), 1, "{query}: {candidates:?}");
            assert_eq!(candidates[0].title, query, "{candidates:?}");
            assert_eq!(
                serde_json::to_value(&candidates[0]).unwrap()["effect"]["text"],
                query
            );
        }
    }

    #[test]
    fn supports_units_without_external_state() {
        let candidates = evaluate("2 km to m", &RatesStore::default(), &[]);
        assert_eq!(candidates[0].title, "2000 m");
    }

    #[test]
    fn supports_natural_language_unit_conversions_and_marks_approximations() {
        let candidates = evaluate("25397 hours in days", &RatesStore::default(), &[]);
        assert_eq!(candidates[0].title, "≈ 1058.2083333333 days");
        assert_eq!(
            serde_json::to_value(&candidates[0]).unwrap()["effect"]["text"],
            "≈ 1058.2083333333 days"
        );
    }

    #[test]
    fn replaces_fend_approximation_label_with_symbol() {
        let candidates = evaluate("sqrt 2", &RatesStore::default(), &[]);
        assert_eq!(candidates[0].title, "≈ 1.4142135624");
    }

    #[test]
    fn evaluates_currency_arithmetic_and_warm_target_conversion() {
        let rates = parse_ecb_xml(
            r#"<Cube><Cube time="2026-07-17">
                <Cube currency="USD" rate="1.2"/>
            </Cube></Cube>"#,
        )
        .unwrap();
        let candidates = evaluate(
            "10 euros + 10 euros",
            &RatesStore::from_rates(rates),
            &["USD".to_string()],
        );

        assert!(candidates.len() >= 2, "{candidates:?}");
        assert!(candidates[0].title.contains("20"), "{candidates:?}");
        assert!(
            candidates
                .iter()
                .any(|candidate| candidate.title.contains('$') || candidate.title.contains("USD")),
            "{candidates:?}"
        );
        assert!(
            candidates.iter().any(|candidate| candidate
                .subtitle
                .as_deref()
                .is_some_and(|value| { value.contains("USD") && value.contains("2026-07-17") })),
            "{candidates:?}"
        );
    }

    #[test]
    fn evaluates_bare_euros_with_primary_and_usd_answers() {
        let rates = parse_ecb_xml(
            r#"<Cube><Cube time="2026-07-17">
                <Cube currency="USD" rate="1.2"/>
            </Cube></Cube>"#,
        )
        .unwrap();
        let candidates = evaluate(
            "10 euros",
            &RatesStore::from_rates(rates),
            &["USD".to_string()],
        );

        assert!(candidates.len() >= 2, "{candidates:?}");
        assert!(candidates[0].title.contains("10"), "{candidates:?}");
        assert!(
            candidates
                .iter()
                .any(|candidate| candidate.title.contains('$') || candidate.title.contains("USD")),
            "{candidates:?}"
        );
        for candidate in candidates {
            let encoded = serde_json::to_value(&candidate).unwrap();
            assert_eq!(encoded["effect"]["text"], candidate.title);
        }
    }

    #[test]
    fn supports_natural_language_currency_conversions() {
        let rates = parse_ecb_xml(
            r#"<Cube><Cube time="2026-07-17">
                <Cube currency="USD" rate="1.2"/>
            </Cube></Cube>"#,
        )
        .unwrap();
        let candidates = evaluate("1234 euros in dollars", &RatesStore::from_rates(rates), &[]);

        assert_eq!(candidates.len(), 1, "{candidates:?}");
        assert_eq!(candidates[0].title, "1480.8 dollars");
    }
}
