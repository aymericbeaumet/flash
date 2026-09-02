use std::collections::{BTreeMap, HashMap, HashSet};

use flash_plugin::{run, Context, EvaluateRequest, EvaluateResponse, QueryAnswer};
use jiff::tz::{TimeZone, TimeZoneDatabase};
use jiff::Timestamp;

const MAX_ANSWERS: usize = 4;

struct Timezones {
    aliases: BTreeMap<String, String>,
    zones: HashMap<String, TimeZone>,
    local_zone: TimeZone,
}

impl Timezones {
    fn new() -> Self {
        Self::from_database(TimeZoneDatabase::bundled(), TimeZone::system())
    }

    fn from_database(database: TimeZoneDatabase, local_zone: TimeZone) -> Self {
        assert!(
            !database.is_definitively_empty(),
            "timezones requires Jiff's bundled IANA database"
        );
        let mut names: Vec<String> = database.available().map(|name| name.to_string()).collect();
        names.sort();

        let mut aliases = BTreeMap::new();
        let mut zones = HashMap::new();
        for name in names {
            if (name.starts_with("Etc/") || name.starts_with("SystemV/")) && name != "Etc/UTC" {
                continue;
            }
            let Ok(zone) = database.get(&name) else {
                continue;
            };
            let full = name.to_ascii_lowercase().replace('_', " ");
            let city = full.rsplit('/').next().unwrap_or(&full);
            aliases.entry(full.clone()).or_insert_with(|| name.clone());
            aliases
                .entry(city.to_string())
                .or_insert_with(|| name.clone());
            zones.insert(name, zone);
        }
        aliases
            .entry("utc".to_string())
            .or_insert_with(|| "Etc/UTC".to_string());
        Self {
            aliases,
            zones,
            local_zone,
        }
    }

    fn evaluate_at(&self, request: &EvaluateRequest, now: Timestamp) -> EvaluateResponse {
        if request.surface != "flashlight" {
            return EvaluateResponse::default();
        }
        let query = request.query.trim().to_ascii_lowercase();
        if query != "time" && !query.starts_with("time ") {
            return EvaluateResponse::default();
        }
        let mut place = query["time".len()..].trim();
        if let Some(rest) = place.strip_prefix("in ") {
            place = rest.trim();
        }
        if place.is_empty() {
            let mut answers = vec![answer(now, "local", &self.local_zone)];
            if let Some(utc) = self.zones.get("Etc/UTC") {
                answers.push(answer(now, "Etc/UTC", utc));
            }
            return EvaluateResponse::answers(answers);
        }
        if place.len() < 2 {
            return EvaluateResponse::default();
        }
        let answers = self
            .matches(place)
            .into_iter()
            .take(MAX_ANSWERS)
            .filter_map(|name| self.zones.get(name).map(|zone| answer(now, name, zone)))
            .collect();
        EvaluateResponse::answers(answers)
    }

    /// Exact alias first, then lexicographically ordered prefix aliases, with
    /// the first occurrence of each canonical zone retained.
    fn matches(&self, place: &str) -> Vec<&str> {
        let mut matches = Vec::new();
        let mut seen = HashSet::new();
        if let Some(name) = self.aliases.get(place) {
            seen.insert(name.as_str());
            matches.push(name.as_str());
        }
        for (alias, name) in self.aliases.range(place.to_string()..) {
            if !alias.starts_with(place) {
                break;
            }
            if alias != place && seen.insert(name.as_str()) {
                matches.push(name.as_str());
            }
        }
        matches
    }
}

flash_plugin::plugin!(Timezones);

impl FlashPlugin for Timezones {
    async fn on_start(&self, ctx: Context) {
        ctx.log_fields(
            "info",
            "[timezones] zone index warmed",
            BTreeMap::from([("count".to_string(), self.zones.len().to_string())]),
        );
    }

    fn evaluate(&self, request: EvaluateRequest) -> EvaluateResponse {
        self.evaluate_at(&request, Timestamp::now())
    }
}

fn answer(now: Timestamp, label: &str, zone: &TimeZone) -> QueryAnswer {
    let zoned = now.to_zoned(zone.clone());
    let title = format!("{} — {label}", zoned.strftime("%H:%M %a"));
    let compact_offset = zoned.strftime("%z").to_string();
    let offset = match compact_offset.split_at_checked(3) {
        Some((hours, minutes)) => format!("{hours}:{minutes}"),
        None => compact_offset,
    };
    QueryAnswer::copy_text(title, Some(format!("UTC{offset}")))
}

fn main() {
    run(Timezones::new());
}

#[cfg(test)]
mod tests {
    use super::*;

    fn timezones() -> Timezones {
        let database = TimeZoneDatabase::bundled();
        let paris = database.get("Europe/Paris").unwrap();
        Timezones::from_database(database, paris)
    }

    fn request(query: &str) -> EvaluateRequest {
        EvaluateRequest {
            surface: "flashlight".to_string(),
            query: query.to_string(),
            ..EvaluateRequest::default()
        }
    }

    #[test]
    fn exact_city_alias_wins_before_prefix_matches() {
        let timezones = timezones();
        let matches = timezones.matches("new york");
        assert_eq!(matches.first(), Some(&"America/New_York"));
        assert_eq!(matches.len(), 1);

        let prefix = timezones.matches("tok");
        assert_eq!(prefix.first(), Some(&"Asia/Tokyo"));
    }

    #[test]
    fn evaluator_preserves_claiming_rules_and_four_answer_cap() {
        let timezones = timezones();
        let now: Timestamp = "2024-01-15T12:34:00Z".parse().unwrap();
        assert!(timezones
            .evaluate_at(&request("timer"), now)
            .answers
            .is_empty());
        assert!(timezones
            .evaluate_at(&request("time a"), now)
            .answers
            .is_empty());
        assert!(timezones
            .evaluate_at(&request("time in a"), now)
            .answers
            .is_empty());
        assert!(
            timezones
                .evaluate_at(&request("time am"), now)
                .answers
                .len()
                <= MAX_ANSWERS
        );
    }

    #[test]
    fn evaluator_formats_local_utc_and_dst_offsets_deterministically() {
        let timezones = timezones();
        let winter: Timestamp = "2024-01-15T12:34:00Z".parse().unwrap();
        let bare = timezones.evaluate_at(&request("time"), winter).answers;
        assert_eq!(bare.len(), 2);
        assert_eq!(bare[0].title, "13:34 Mon — local");
        assert_eq!(bare[0].subtitle.as_deref(), Some("UTC+01:00"));
        assert_eq!(bare[1].title, "12:34 Mon — Etc/UTC");
        assert_eq!(bare[1].subtitle.as_deref(), Some("UTC+00:00"));

        let summer: Timestamp = "2024-07-15T12:34:00Z".parse().unwrap();
        let paris = timezones
            .evaluate_at(&request("time in paris"), summer)
            .answers;
        assert_eq!(paris[0].title, "14:34 Mon — Europe/Paris");
        assert_eq!(paris[0].subtitle.as_deref(), Some("UTC+02:00"));
    }

    #[test]
    fn non_flashlight_surfaces_are_never_claimed() {
        let timezones = timezones();
        let now = Timestamp::UNIX_EPOCH;
        let mut request = request("time tokyo");
        request.surface = "other".to_string();
        assert!(timezones.evaluate_at(&request, now).answers.is_empty());
    }
}
