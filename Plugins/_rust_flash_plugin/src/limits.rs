//! SDK boundary limits: the `MAX_*` constants bounding what a plugin may
//! publish, plus catalog/query validation enforced at the wire boundary.

use std::collections::BTreeMap;

use serde::Serialize;

use crate::types::{Candidate, CandidateEffect, QueryAnswer};

pub(crate) const MAX_CATALOG_CANDIDATES: usize = 10_000;
pub(crate) const MAX_CATALOG_ENCODED_BYTES: usize = 4 * 1024 * 1024;
pub(crate) const MAX_QUERY_ANSWERS: usize = 16;
pub(crate) const MAX_QUERY_ENCODED_BYTES: usize = 256 * 1024;
pub(crate) const MAX_CANDIDATE_TITLE_BYTES: usize = 4 * 1024;
pub(crate) const MAX_CANDIDATE_URL_BYTES: usize = 16 * 1024;
pub(crate) const MAX_CANDIDATE_METADATA_ENTRIES: usize = 64;
pub(crate) const MAX_CANDIDATE_METADATA_KEY_BYTES: usize = 256;
pub(crate) const MAX_CANDIDATE_METADATA_VALUE_BYTES: usize = 64 * 1024;
pub(crate) const MAX_CANDIDATE_EFFECT_BYTES: usize = 64 * 1024;
pub(crate) const MAX_QUERY_FIELD_BYTES: usize = 16 * 1024;

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct BoundaryViolation {
    boundary: &'static str,
    rule: &'static str,
    item_index: Option<usize>,
    actual: usize,
    limit: usize,
}

impl BoundaryViolation {
    pub(crate) fn new(
        boundary: &'static str,
        rule: &'static str,
        item_index: Option<usize>,
        actual: usize,
        limit: usize,
    ) -> Self {
        Self {
            boundary,
            rule,
            item_index,
            actual,
            limit,
        }
    }

    pub(crate) fn log_fields(&self) -> BTreeMap<String, String> {
        let mut fields = BTreeMap::from([
            ("boundary".to_string(), self.boundary.to_string()),
            ("rule".to_string(), self.rule.to_string()),
            ("actual".to_string(), self.actual.to_string()),
            ("limit".to_string(), self.limit.to_string()),
        ]);
        if let Some(index) = self.item_index {
            fields.insert("item_index".to_string(), index.to_string());
        }
        fields
    }
}

#[derive(Serialize)]
struct CatalogCandidatesRef<'a> {
    candidates: &'a [Candidate],
}

#[derive(Serialize)]
struct QueryAnswersRef<'a> {
    answers: &'a [QueryAnswer],
}

fn reject_oversized_field(
    boundary: &'static str,
    rule: &'static str,
    item_index: usize,
    actual: usize,
    limit: usize,
) -> Result<(), BoundaryViolation> {
    if actual <= limit {
        Ok(())
    } else {
        Err(BoundaryViolation::new(
            boundary,
            rule,
            Some(item_index),
            actual,
            limit,
        ))
    }
}

fn add_aggregate_bytes(
    total: &mut usize,
    additional: usize,
    boundary: &'static str,
    item_index: usize,
    limit: usize,
) -> Result<(), BoundaryViolation> {
    *total = total.checked_add(additional).ok_or_else(|| {
        BoundaryViolation::new(
            boundary,
            "aggregate_string_bytes",
            Some(item_index),
            usize::MAX,
            limit,
        )
    })?;
    if *total > limit {
        return Err(BoundaryViolation::new(
            boundary,
            "aggregate_string_bytes",
            Some(item_index),
            *total,
            limit,
        ));
    }
    Ok(())
}

pub(crate) fn validate_catalog_candidates(
    candidates: &[Candidate],
) -> Result<(), BoundaryViolation> {
    if candidates.len() > MAX_CATALOG_CANDIDATES {
        return Err(BoundaryViolation::new(
            "catalog",
            "candidate_count",
            None,
            candidates.len(),
            MAX_CATALOG_CANDIDATES,
        ));
    }

    let mut aggregate_string_bytes = 0usize;
    for (index, candidate) in candidates.iter().enumerate() {
        reject_oversized_field(
            "catalog",
            "title_bytes",
            index,
            candidate.title.len(),
            MAX_CANDIDATE_TITLE_BYTES,
        )?;
        add_aggregate_bytes(
            &mut aggregate_string_bytes,
            candidate.title.len(),
            "catalog",
            index,
            MAX_CATALOG_ENCODED_BYTES,
        )?;

        if let Some(url) = &candidate.url {
            reject_oversized_field(
                "catalog",
                "url_bytes",
                index,
                url.len(),
                MAX_CANDIDATE_URL_BYTES,
            )?;
            add_aggregate_bytes(
                &mut aggregate_string_bytes,
                url.len(),
                "catalog",
                index,
                MAX_CATALOG_ENCODED_BYTES,
            )?;
        }

        if candidate.metadata.len() > MAX_CANDIDATE_METADATA_ENTRIES {
            return Err(BoundaryViolation::new(
                "catalog",
                "metadata_entries",
                Some(index),
                candidate.metadata.len(),
                MAX_CANDIDATE_METADATA_ENTRIES,
            ));
        }
        for (key, value) in &candidate.metadata {
            reject_oversized_field(
                "catalog",
                "metadata_key_bytes",
                index,
                key.len(),
                MAX_CANDIDATE_METADATA_KEY_BYTES,
            )?;
            reject_oversized_field(
                "catalog",
                "metadata_value_bytes",
                index,
                value.len(),
                MAX_CANDIDATE_METADATA_VALUE_BYTES,
            )?;
            add_aggregate_bytes(
                &mut aggregate_string_bytes,
                key.len(),
                "catalog",
                index,
                MAX_CATALOG_ENCODED_BYTES,
            )?;
            add_aggregate_bytes(
                &mut aggregate_string_bytes,
                value.len(),
                "catalog",
                index,
                MAX_CATALOG_ENCODED_BYTES,
            )?;
        }

        if let Some(CandidateEffect::CopyText { text }) = &candidate.effect {
            reject_oversized_field(
                "catalog",
                "effect_text_bytes",
                index,
                text.len(),
                MAX_CANDIDATE_EFFECT_BYTES,
            )?;
            add_aggregate_bytes(
                &mut aggregate_string_bytes,
                text.len(),
                "catalog",
                index,
                MAX_CATALOG_ENCODED_BYTES,
            )?;
        }
    }

    let encoded = serde_json::to_vec(&CatalogCandidatesRef { candidates })
        .map_err(|_| BoundaryViolation::new("catalog", "json_encoding", None, 1, 0))?;
    if encoded.len() > MAX_CATALOG_ENCODED_BYTES {
        return Err(BoundaryViolation::new(
            "catalog",
            "encoded_bytes",
            None,
            encoded.len(),
            MAX_CATALOG_ENCODED_BYTES,
        ));
    }
    Ok(())
}

pub(crate) fn validate_query_answers(answers: &[QueryAnswer]) -> Result<(), BoundaryViolation> {
    if answers.len() > MAX_QUERY_ANSWERS {
        return Err(BoundaryViolation::new(
            "query",
            "answer_count",
            None,
            answers.len(),
            MAX_QUERY_ANSWERS,
        ));
    }

    let mut aggregate_string_bytes = 0usize;
    for (index, answer) in answers.iter().enumerate() {
        for (rule, value) in [
            ("title_bytes", answer.title.as_str()),
            (
                "effect_text_bytes",
                match &answer.effect {
                    CandidateEffect::CopyText { text }
                    | CandidateEffect::InsertText { text } => text.as_str(),
                    // Query answers cannot carry open effects (the host
                    // rejects them); size their fields as empty here so the
                    // host-side rejection stays the single authority.
                    CandidateEffect::Open { .. } => "",
                },
            ),
        ] {
            reject_oversized_field("query", rule, index, value.len(), MAX_QUERY_FIELD_BYTES)?;
            add_aggregate_bytes(
                &mut aggregate_string_bytes,
                value.len(),
                "query",
                index,
                MAX_QUERY_ENCODED_BYTES,
            )?;
        }
        if let Some(subtitle) = &answer.subtitle {
            reject_oversized_field(
                "query",
                "subtitle_bytes",
                index,
                subtitle.len(),
                MAX_QUERY_FIELD_BYTES,
            )?;
            add_aggregate_bytes(
                &mut aggregate_string_bytes,
                subtitle.len(),
                "query",
                index,
                MAX_QUERY_ENCODED_BYTES,
            )?;
        }
    }

    let encoded = serde_json::to_vec(&QueryAnswersRef { answers })
        .map_err(|_| BoundaryViolation::new("query", "json_encoding", None, 1, 0))?;
    if encoded.len() > MAX_QUERY_ENCODED_BYTES {
        return Err(BoundaryViolation::new(
            "query",
            "encoded_bytes",
            None,
            encoded.len(),
            MAX_QUERY_ENCODED_BYTES,
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn catalog_boundary_rejects_counts_fields_and_aggregate_bytes() {
        let too_many = vec![Candidate::new("x"); MAX_CATALOG_CANDIDATES + 1];
        assert_eq!(
            validate_catalog_candidates(&too_many).unwrap_err().rule,
            "candidate_count"
        );

        let oversized_title = vec![Candidate::new("x".repeat(MAX_CANDIDATE_TITLE_BYTES + 1))];
        assert_eq!(
            validate_catalog_candidates(&oversized_title)
                .unwrap_err()
                .rule,
            "title_bytes"
        );

        let aggregate = (0..65)
            .map(|index| {
                Candidate::new(format!("candidate {index}"))
                    .metadata("payload", "x".repeat(MAX_CANDIDATE_METADATA_VALUE_BYTES))
            })
            .collect::<Vec<_>>();
        assert_eq!(
            validate_catalog_candidates(&aggregate).unwrap_err().rule,
            "aggregate_string_bytes"
        );
    }

    #[test]
    fn query_boundary_rejects_counts_fields_and_aggregate_bytes() {
        let too_many = vec![QueryAnswer::copy_text("1", None::<String>); MAX_QUERY_ANSWERS + 1];
        assert_eq!(
            validate_query_answers(&too_many).unwrap_err().rule,
            "answer_count"
        );

        let oversized =
            QueryAnswer::copy_text("x".repeat(MAX_QUERY_FIELD_BYTES + 1), None::<String>);
        assert_eq!(
            validate_query_answers(&[oversized]).unwrap_err().rule,
            "title_bytes"
        );

        let aggregate = (0..MAX_QUERY_ANSWERS)
            .map(|_| QueryAnswer::copy_text("x".repeat(10 * 1024), None::<String>))
            .collect::<Vec<_>>();
        assert_eq!(
            validate_query_answers(&aggregate).unwrap_err().rule,
            "aggregate_string_bytes"
        );
    }
}
