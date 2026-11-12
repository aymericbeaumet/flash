//! The bang table: DuckDuckGo's list first, Kagi's community list for the
//! triggers DuckDuckGo lacks, each bang resolved locally to its site's URL.
//!
//! Both lists stay the compact text they are stored as, one bang per line:
//! the vendored Kagi snapshot inside the binary and the cached DuckDuckGo
//! copy read from the data directory. Each list adds only an index of
//! trigger positions sorted by lowercase trigger, so a lookup is a binary
//! search and no bang is copied out of its text until it is resolved or
//! listed.
//!
//! DuckDuckGo's semantics follow its own redirects: the query is
//! percent-encoded with only `A-Z a-z 0-9 ! ( ) * . _ ~` kept (a space is
//! `%20`), a template without `{{{s}}}` opens as written, and an empty query
//! opens the bang's domain. A relative DuckDuckGo template (`/?q=…`) is one of
//! DuckDuckGo's own searches and resolves against `https://duckduckgo.com`.
//! Kagi's entries carry their own format flags (`fmt`, all enabled when
//! absent) and, for three bangs, a query pattern whose captures fill `$1`,
//! `$2`, …; Kagi's relative templates are Kagi searches that need a Kagi
//! account, so they are left out.

use std::borrow::Cow;
use std::cmp::Ordering;
use std::sync::LazyLock;

use flash_plugin::{Candidate, Priority};
use serde::Deserialize;

pub const SOURCE: &str = "searchproviders.bangs";
const PLACEHOLDER: &str = "{{{s}}}";
const DUCKDUCKGO_ORIGIN: &str = "https://duckduckgo.com";
/// Triggers one list indexes at most. DuckDuckGo lists ~13.6k and Kagi
/// ~13.6k counting aliases; the bound leaves room for both to grow.
pub const MAX_BANGS: usize = 32_768;
/// The flashlight lists the best-ranked bangs, up to the protocol's catalog
/// quota (`catalog_rows`). Every bang resolves whether listed or not.
pub const MAX_CATALOG_ROWS: usize = 10_000;
/// The largest list text read or downloaded: bang.js is ~2.2 MB, its cache
/// ~1.6 MB and the Kagi snapshot ~1.4 MB.
pub const MAX_LIST_BYTES: usize = 8 * 1024 * 1024;
const MAX_TRIGGER_BYTES: usize = 64;
const MAX_TEMPLATE_BYTES: usize = 4_096;
const MAX_TEXT_BYTES: usize = 256;

/// The vendored Kagi snapshot, indexed once per process.
pub static KAGI: LazyLock<List> = LazyLock::new(|| List::kagi(include_str!("../kagi-bangs.tsv")));

/// No list: the DuckDuckGo side before its first download.
pub static EMPTY: List = List::empty();

/// Triggers another owner answers, so this plugin neither lists nor serves
/// them: Flash's own `!f` (file search), the `browsers` plugin's browser
/// history and bookmark bangs, and every AI chat bang of `aiproviders`. A
/// test keeps this list equal to those manifests.
pub const RESERVED: &[&str] = &[
    // Flash core
    "f",
    // browsers
    "cb",
    "ch",
    "fb",
    "fh",
    // aiproviders
    "ai",
    "aichat",
    "cgpt",
    "chat",
    "chatgpt",
    "claude",
    "copilot",
    "ddg-ai",
    "ddg-chat",
    "deepseek",
    "duckai",
    "felo",
    "gai",
    "gemini",
    "googleai",
    "grok",
    "huggingchat",
    "ithy",
    "kagiassistant",
    "kimi",
    "lechat",
    "lmarena",
    "lumo",
    "metaai",
    "mistral",
    "perplexity",
    "phind",
    "piai",
    "poeai",
    "pplx",
    "ppx",
    "protonlumo",
    "qwen",
    "t3",
    "v0",
    "youai",
    "zai",
    "гии",
];

/// How a bang turns a query into a URL: Kagi's `fmt` flags plus
/// DuckDuckGo's empty-query rule.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Format(u8);

impl Format {
    /// An empty query opens the template's origin (`open_base_path`).
    const BASE_PATH: u8 = 1;
    /// An empty query opens the snap domain (`open_snap_domain`).
    const SNAP_DOMAIN: u8 = 2;
    /// The query is percent-encoded (`url_encode_placeholder`).
    const ENCODE: u8 = 4;
    /// A space is `+`, not `%20` (`url_encode_space_to_plus`).
    const PLUS: u8 = 8;
    /// An empty query opens the bang's domain (DuckDuckGo).
    const DOMAIN: u8 = 16;

    pub const DUCKDUCKGO: Format = Format(Self::ENCODE | Self::DOMAIN);

    /// The vendored snapshot's letters: `b`, `d`, `e`, `p`, or `-` for none.
    fn kagi(letters: &str) -> Option<Format> {
        if letters == "-" {
            return Some(Format(0));
        }
        if letters.is_empty() {
            return None;
        }
        letters.chars().try_fold(Format(0), |format, letter| {
            let bit = match letter {
                'b' => Self::BASE_PATH,
                'd' => Self::SNAP_DOMAIN,
                'e' => Self::ENCODE,
                'p' => Self::PLUS,
                _ => return None,
            };
            Some(Format(format.0 | bit))
        })
    }

    fn has(self, bit: u8) -> bool {
        self.0 & bit != 0
    }
}

/// One bang, borrowed from its list's text.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Bang<'a> {
    pub trigger: &'a str,
    pub template: &'a str,
    pub name: &'a str,
    pub domain: &'a str,
    pub snap: &'a str,
    pub category: &'a str,
    pub subcategory: &'a str,
    /// Kagi's query pattern (`x`); empty for a plain `{{{s}}}` template.
    pub pattern: &'a str,
    pub format: Format,
    /// DuckDuckGo's popularity rank; 0 when unranked or from Kagi.
    pub rank: u64,
}

/// A trigger lowercased the one way every comparison here uses.
fn fold(text: &str) -> impl Iterator<Item = char> + '_ {
    text.chars().flat_map(char::to_lowercase)
}

fn cmp_folded(left: &str, right: &str) -> Ordering {
    fold(left).cmp(fold(right))
}

/// `[&str; N]` from exactly `N` tab-separated fields.
fn fields<const N: usize>(line: &str) -> Option<[&str; N]> {
    let mut out = [""; N];
    let mut parts = line.split('\t');
    for slot in &mut out {
        *slot = parts.next()?;
    }
    parts.next().is_none().then_some(out)
}

/// Data lines of a `#`-commented table with their byte offsets. No trigger
/// starts with `#`.
fn records(text: &str) -> impl Iterator<Item = (usize, &str)> {
    let base = text.as_ptr() as usize;
    text.lines()
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
        .map(move |line| (line.as_ptr() as usize - base, line))
}

/// A Kagi snapshot line — trigger, aliases, format flags, template, name,
/// domain, snap domain, category, subcategory, pattern — and its aliases.
fn kagi_record(line: &str) -> Option<(Bang<'_>, &str)> {
    let [
        trigger,
        aliases,
        format,
        template,
        name,
        domain,
        snap,
        category,
        subcategory,
        pattern,
    ] = fields(line)?;
    let bang = Bang {
        trigger,
        template,
        name,
        domain,
        snap,
        category,
        subcategory,
        pattern,
        format: Format::kagi(format)?,
        rank: 0,
    };
    Some((bang, aliases))
}

/// A DuckDuckGo cache line: trigger, rank, template, name, domain, category,
/// subcategory.
fn duckduckgo_record(line: &str) -> Option<Bang<'_>> {
    let [trigger, rank, template, name, domain, category, subcategory] = fields(line)?;
    Some(Bang {
        trigger,
        template,
        name,
        domain,
        snap: "",
        category,
        subcategory,
        pattern: "",
        format: Format::DUCKDUCKGO,
        rank: rank.parse().ok()?,
    })
}

fn plain_text(value: &str, limit: usize) -> bool {
    value.len() <= limit && !value.chars().any(char::is_control)
}

/// A trigger the flashlight can type: no whitespace or `!`, which end a
/// bang, and no leading `#`, which starts a comment line.
fn valid_trigger(trigger: &str) -> bool {
    !trigger.is_empty()
        && trigger.len() <= MAX_TRIGGER_BYTES
        && !trigger.starts_with('#')
        && !trigger.chars().any(|character| {
            character.is_whitespace() || character.is_control() || character == '!'
        })
}

/// A bang the table can hold: a typeable trigger and an absolute http(s)
/// template.
fn valid(bang: &Bang) -> bool {
    valid_trigger(bang.trigger)
        && plain_text(bang.template, MAX_TEMPLATE_BYTES)
        && (bang.template.starts_with("https://") || bang.template.starts_with("http://"))
        && [
            bang.name,
            bang.domain,
            bang.snap,
            bang.category,
            bang.subcategory,
            bang.pattern,
        ]
        .into_iter()
        .all(|value| plain_text(value, MAX_TEXT_BYTES))
}

fn reserved(trigger: &str) -> bool {
    RESERVED
        .iter()
        .any(|owned| cmp_folded(owned, trigger) == Ordering::Equal)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Shape {
    DuckDuckGo,
    Kagi,
}

/// Where one trigger sits in a list's text: the trigger itself (a record's
/// first field or one of a Kagi record's aliases) and its record's line.
#[derive(Clone, Copy, Debug)]
struct Key {
    start: u32,
    len: u32,
    line: u32,
}

/// One bang list: its text and the triggers it serves, sorted by lowercase
/// trigger.
#[derive(Debug)]
pub struct List {
    text: Cow<'static, str>,
    shape: Shape,
    keys: Vec<Key>,
    /// Triggers left out: a malformed or invalid record, a reserved or
    /// repeated trigger, or one past [`MAX_BANGS`].
    dropped: usize,
}

impl List {
    pub const fn empty() -> List {
        List {
            text: Cow::Borrowed(""),
            shape: Shape::DuckDuckGo,
            keys: Vec::new(),
            dropped: 0,
        }
    }

    pub fn kagi(text: &'static str) -> List {
        List::index(Cow::Borrowed(text), Shape::Kagi)
    }

    /// A DuckDuckGo cache text, as [`duckduckgo_cache`] renders it.
    pub fn duckduckgo(text: String) -> List {
        List::index(Cow::Owned(text), Shape::DuckDuckGo)
    }

    fn index(text: Cow<'static, str>, shape: Shape) -> List {
        let mut keys = Vec::new();
        let mut dropped = 0;
        let body: &str = &text;
        let base = body.as_ptr() as usize;
        let offset = |part: &str| u32::try_from(part.as_ptr() as usize - base).ok();
        let mut add = |trigger: &str, line: usize| -> bool {
            let key = (|| {
                Some(Key {
                    start: offset(trigger)?,
                    len: u32::try_from(trigger.len()).ok()?,
                    line: u32::try_from(line).ok()?,
                })
            })();
            match key {
                Some(key) if valid_trigger(trigger) && !reserved(trigger) => {
                    keys.push(key);
                    true
                }
                _ => false,
            }
        };
        for (line, record) in records(body) {
            let (bang, aliases) = match shape {
                Shape::DuckDuckGo => match duckduckgo_record(record) {
                    Some(bang) => (bang, ""),
                    None => {
                        dropped += 1;
                        continue;
                    }
                },
                Shape::Kagi => match kagi_record(record) {
                    Some(parsed) => parsed,
                    None => {
                        dropped += 1;
                        continue;
                    }
                },
            };
            let triggers =
                std::iter::once(bang.trigger).chain(aliases.split(' ').filter(|a| !a.is_empty()));
            if !valid(&bang) {
                dropped += triggers.count();
                continue;
            }
            for trigger in triggers {
                if !add(trigger, line) {
                    dropped += 1;
                }
            }
        }
        // A stable sort keeps the first of a repeated trigger first; the
        // cache is written sorted, so this is one linear pass there.
        let key_text = |key: &Key| &body[key.start as usize..(key.start + key.len) as usize];
        keys.sort_by(|left, right| cmp_folded(key_text(left), key_text(right)));
        let before = keys.len();
        keys.dedup_by(|later, earlier| cmp_folded(key_text(later), key_text(earlier)).is_eq());
        dropped += before - keys.len();
        if keys.len() > MAX_BANGS {
            dropped += keys.len() - MAX_BANGS;
            keys.truncate(MAX_BANGS);
        }
        keys.shrink_to_fit();
        List {
            text,
            shape,
            keys,
            dropped,
        }
    }

    pub fn len(&self) -> usize {
        self.keys.len()
    }

    pub fn dropped(&self) -> usize {
        self.dropped
    }

    fn key_text(&self, key: &Key) -> &str {
        &self.text[key.start as usize..(key.start + key.len) as usize]
    }

    fn bang(&self, key: &Key) -> Option<Bang<'_>> {
        let line = self.text[key.line as usize..].lines().next()?;
        let mut bang = match self.shape {
            Shape::DuckDuckGo => duckduckgo_record(line)?,
            Shape::Kagi => kagi_record(line)?.0,
        };
        bang.trigger = self.key_text(key);
        Some(bang)
    }

    fn position(&self, trigger: &str) -> Option<usize> {
        self.keys
            .binary_search_by(|key| cmp_folded(self.key_text(key), trigger))
            .ok()
    }

    pub fn get(&self, trigger: &str) -> Option<Bang<'_>> {
        self.bang(&self.keys[self.position(trigger)?])
    }

    fn bangs(&self) -> impl Iterator<Item = Bang<'_>> {
        self.keys.iter().filter_map(|key| self.bang(key))
    }
}

/// What a table serves and left out, for the content-free start log.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Counts {
    pub duckduckgo: usize,
    /// Kagi triggers DuckDuckGo lacks.
    pub kagi: usize,
    /// Malformed, invalid (Kagi's relative searches included), reserved,
    /// repeated or over the bound.
    pub dropped: usize,
}

/// DuckDuckGo's bangs win; Kagi's fill only the triggers DuckDuckGo lacks.
/// Triggers match case-insensitively.
#[derive(Debug)]
pub struct Table {
    duckduckgo: List,
    kagi: &'static List,
}

impl Default for Table {
    fn default() -> Table {
        Table::new(List::empty(), &EMPTY)
    }
}

impl Table {
    pub fn new(duckduckgo: List, kagi: &'static List) -> Table {
        Table { duckduckgo, kagi }
    }

    /// Kagi's bangs whose trigger DuckDuckGo does not define.
    fn kagi_fills(&self) -> impl Iterator<Item = Bang<'_>> {
        self.kagi
            .bangs()
            .filter(|bang| self.duckduckgo.position(bang.trigger).is_none())
    }

    pub fn counts(&self) -> Counts {
        Counts {
            duckduckgo: self.duckduckgo.len(),
            kagi: self.kagi_fills().count(),
            dropped: self.duckduckgo.dropped() + self.kagi.dropped(),
        }
    }

    pub fn get(&self, trigger: &str) -> Option<Bang<'_>> {
        self.duckduckgo
            .get(trigger)
            .or_else(|| self.kagi.get(trigger))
    }

    pub fn resolve(&self, trigger: &str, query: &str) -> Result<String, &'static str> {
        if trigger.len() > MAX_TRIGGER_BYTES {
            return Err("bang token too long");
        }
        url(&self.get(trigger).ok_or("unknown bang")?, query)
    }

    /// The flashlight rows: the best-ranked bangs first (DuckDuckGo's rank,
    /// then the shorter trigger), at most [`MAX_CATALOG_ROWS`].
    pub fn catalog(&self) -> Vec<Candidate> {
        let mut order: Vec<Bang> = self.duckduckgo.bangs().chain(self.kagi_fills()).collect();
        order.sort_by(|left, right| {
            right
                .rank
                .cmp(&left.rank)
                .then(left.trigger.len().cmp(&right.trigger.len()))
                .then_with(|| left.trigger.cmp(right.trigger))
        });
        order.truncate(MAX_CATALOG_ROWS);
        order.iter().map(row).collect()
    }
}

fn row(bang: &Bang) -> Candidate {
    Candidate::new(SOURCE, format!("!{}", bang.trigger))
        .kind("bang")
        .subtitle(subtitle(bang))
        .payload(bang.trigger)
        .priority(priority(bang.rank))
}

/// `GitHub · Tech › Programming`: the site, then its category.
fn subtitle(bang: &Bang) -> String {
    let site = if bang.name.is_empty() {
        bang.domain
    } else {
        bang.name
    };
    let category = match (bang.category, bang.subcategory) {
        ("", "") => String::new(),
        (category, "") | ("", category) => category.to_string(),
        (category, subcategory) => format!("{category} › {subcategory}"),
    };
    match (site.is_empty(), category.is_empty()) {
        (_, true) => site.to_string(),
        (true, false) => category,
        (false, false) => format!("{site} · {category}"),
    }
}

/// DuckDuckGo's rank as the row's tiebreak salience, so `!g` outranks an
/// equally matching obscure bang.
fn priority(rank: u64) -> Priority {
    match rank {
        100_000.. => Priority::Urgent,
        10_000.. => Priority::Important,
        1_000.. => Priority::High,
        1.. => Priority::Normal,
        0 => Priority::Low,
    }
}

// -- DuckDuckGo's list --------------------------------------------------------

#[derive(Deserialize)]
struct DuckDuckGoEntry<'a> {
    #[serde(borrow)]
    t: Cow<'a, str>,
    #[serde(borrow)]
    u: Cow<'a, str>,
    #[serde(borrow, default)]
    s: Option<Cow<'a, str>>,
    #[serde(borrow, default)]
    d: Option<Cow<'a, str>>,
    #[serde(borrow, default)]
    c: Option<Cow<'a, str>>,
    #[serde(borrow, default)]
    sc: Option<Cow<'a, str>>,
    #[serde(default)]
    r: Option<serde_json::Value>,
}

const CACHE_HEADER: &str = "# DuckDuckGo bangs (https://duckduckgo.com/bang.js) fetched at ";
const CACHE_COLUMNS: &str = "# trigger, rank, URL template, site name, domain, category, subcategory; sorted by lowercase trigger\n";

/// DuckDuckGo's `bang.js` (a JSON array of `{t, u, s, d, c, sc, r}`) as the
/// data-dir cache text, and how many bangs it holds: valid bangs only, one
/// per line, sorted by lowercase trigger with the first of a repeated one
/// kept.
pub fn duckduckgo_cache(json: &str, fetched_at: u64) -> Result<(String, usize), &'static str> {
    let entries: Vec<DuckDuckGoEntry> =
        serde_json::from_str(json).map_err(|_| "not a bang list")?;
    let text = |value: &Option<Cow<str>>| value.as_deref().unwrap_or("").trim().to_string();
    let mut rows: Vec<[String; 7]> = entries
        .iter()
        .filter_map(|entry| {
            let template = entry.u.trim();
            let template = if template.starts_with('/') {
                format!("{DUCKDUCKGO_ORIGIN}{template}")
            } else {
                template.to_string()
            };
            let rank = entry
                .r
                .as_ref()
                .and_then(serde_json::Value::as_u64)
                .unwrap_or(0);
            let row = [
                entry.t.trim().to_string(),
                rank.to_string(),
                template,
                text(&entry.s),
                text(&entry.d),
                text(&entry.c),
                text(&entry.sc),
            ];
            let bang = Bang {
                trigger: &row[0],
                template: &row[2],
                name: &row[3],
                domain: &row[4],
                snap: "",
                category: &row[5],
                subcategory: &row[6],
                pattern: "",
                format: Format::DUCKDUCKGO,
                rank,
            };
            valid(&bang).then_some(row)
        })
        .collect();
    drop(entries);
    rows.sort_by(|left, right| cmp_folded(&left[0], &right[0]));
    rows.dedup_by(|later, earlier| cmp_folded(&later[0], &earlier[0]).is_eq());
    let mut out = format!("{CACHE_HEADER}{fetched_at}\n{CACHE_COLUMNS}");
    for row in &rows {
        out.push_str(&row.join("\t"));
        out.push('\n');
    }
    Ok((out, rows.len()))
}

/// When a cache text was fetched; `None` without its header, which leaves
/// the cache unread.
pub fn cache_fetched_at(text: &str) -> Option<u64> {
    text.lines()
        .next()?
        .strip_prefix(CACHE_HEADER)?
        .parse()
        .ok()
}

// -- Resolution ---------------------------------------------------------------

/// The URL `!<bang> <query>` opens.
pub fn url(bang: &Bang, query: &str) -> Result<String, &'static str> {
    let query = query.trim();
    let url = if query.is_empty() {
        empty_query_url(bang)
    } else if !bang.pattern.is_empty() {
        pattern_url(bang, query)?
    } else if bang.template.contains(PLACEHOLDER) {
        bang.template
            .replace(PLACEHOLDER, &encode(query, bang.format))
    } else {
        bang.template.to_string()
    };
    Ok(escape_url(&url))
}

fn empty_query_url(bang: &Bang) -> String {
    if bang.format.has(Format::SNAP_DOMAIN) && !bang.snap.is_empty() {
        return format!("https://{}", bang.snap);
    }
    if bang.format.has(Format::DOMAIN) && !bang.domain.is_empty() {
        return format!("https://{}", bang.domain);
    }
    if (bang.format.has(Format::BASE_PATH) || !bang.pattern.is_empty())
        && let Some(origin) = origin(bang.template)
    {
        return format!("{origin}/");
    }
    bang.template.replace(PLACEHOLDER, "")
}

/// `https://host[:port]` of an absolute template.
fn origin(template: &str) -> Option<&str> {
    let start = template.find("://")? + 3;
    let end = template[start..]
        .find(['/', '?', '#'])
        .map_or(template.len(), |offset| start + offset);
    (end > start).then(|| &template[..end])
}

fn pattern_url(bang: &Bang, query: &str) -> Result<String, &'static str> {
    let pattern = regex_lite::Regex::new(bang.pattern).map_err(|_| "invalid bang pattern")?;
    let captures = pattern
        .captures(query)
        .ok_or("the query does not match the bang's pattern")?;
    let mut url = bang.template.to_string();
    // Highest group first, so `$1` never rewrites the start of `$10`.
    for group in (1..captures.len()).rev() {
        let value = captures.get(group).map_or("", |found| found.as_str());
        url = url.replace(&format!("${group}"), &encode(value, bang.format));
    }
    Ok(url)
}

/// The query as the template receives it. Encoded, only DuckDuckGo's
/// unreserved set passes; unencoded, only spaces change, and [`escape_url`]
/// still escapes what a URL cannot hold.
fn encode(query: &str, format: Format) -> String {
    let mut out = Vec::with_capacity(query.len() * 3);
    for &byte in query.as_bytes() {
        match byte {
            b' ' if format.has(Format::PLUS) => out.push(b'+'),
            b' ' => out.extend_from_slice(b"%20"),
            _ if !format.has(Format::ENCODE) => out.push(byte),
            b'A'..=b'Z'
            | b'a'..=b'z'
            | b'0'..=b'9'
            | b'!'
            | b'('
            | b')'
            | b'*'
            | b'.'
            | b'_'
            | b'~' => out.push(byte),
            _ => out.extend_from_slice(format!("%{byte:02X}").as_bytes()),
        }
    }
    // Only ASCII bytes were substituted, so the UTF-8 sequences are intact.
    String::from_utf8(out).unwrap_or_default()
}

/// Percent-encode the bytes a URL cannot carry literally: spaces and
/// controls, `"<>\^`{|}`, and non-ASCII (templates such as
/// `…/übersetzung?q=` hold them raw).
fn escape_url(url: &str) -> String {
    let mut out = String::with_capacity(url.len());
    for &byte in url.as_bytes() {
        match byte {
            b'!'..=b'~'
                if !matches!(
                    byte,
                    b'"' | b'<' | b'>' | b'\\' | b'^' | b'`' | b'{' | b'|' | b'}'
                ) =>
            {
                out.push(char::from(byte));
            }
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const KAGI_TEXT: &str = include_str!("../kagi-bangs.tsv");

    /// Real entries from DuckDuckGo's bang.js, covering each template shape.
    const DUCKDUCKGO_SAMPLE: &str = r#"[
      {"c":"Online Services","d":"www.google.com","r":1750254,"s":"Google","sc":"Google","t":"g","u":"https://www.google.com/search?q={{{s}}}"},
      {"c":"Online Services","d":"en.wikipedia.org","r":184304,"s":"Wikipedia","sc":"Search","t":"w","u":"https://en.wikipedia.org/wiki/Special:Search?search={{{s}}}"},
      {"c":"Tech","d":"github.com","r":11610,"s":"GitHub","sc":"Programming","t":"gh","u":"https://github.com/search?utf8=%E2%9C%93&q={{{s}}}"},
      {"c":"Multimedia","d":"www.youtube.com","r":423271,"s":"YouTube","sc":"Video","t":"yt","u":"https://www.youtube.com/results?search_query={{{s}}}"},
      {"c":"Online Services","d":"duckduckgo.com","r":13881,"s":"DuckDuckGo Images","sc":"Search (DDG)","t":"i","u":"https://duckduckgo.com/?q={{{s}}}&ia=images&iax=images"},
      {"c":"Shopping","d":"","r":9,"s":"App Store on iTunes","sc":"Tech","t":"appstore","u":"/?q=site%3Aitunes.apple.com%2Fus%2Fapp%2F+{{{s}}}"},
      {"c":"Research","d":"www.climedweb.com","r":0,"s":"Climed Seviços de Saude","sc":"Health","t":"climed","u":"http://www.climedweb.com/wp/?s="},
      {"c":"Entertainment","d":"www.abcya.com","r":0,"s":"abcya","sc":"Games (offline)","t":"abcya","u":"https://www.abcya.com/search/?term={{{s}}}&type={{{s}}}"},
      {"c":"Research","d":"www.duckduckgo.com","r":7072,"s":"Duck.ai","sc":"Reference","t":"ai","u":"https://www.duckduckgo.com/?q={{{s}}}&ia=chat&bang=true "},
      {"c":"Online Services","d":"www.facebook.com","r":4389,"s":"Facebook","sc":"Social","t":"fb","u":"https://www.facebook.com/search.php/?q={{{s}}}"},
      {"c":"Online Services","d":"www.flickr.com","r":769,"s":"Flickr","sc":"Search","t":"f","u":"http://www.flickr.com/search/?q={{{s}}}"},
      {"c":"Tech","d":"mxtoolbox.com","r":10,"s":"MxToolbox","sc":"Sysadmin","t":"mx","u":"http://mxtoolbox.com/SuperTool.aspx?action=mx%3a{{{s}}}&run=networktools"},
      {"c":"Tech","d":"www.aptoide.com","r":0,"s":"Aptoide","sc":"Downloads (apps)","t":"aapt","u":"http://www.aptoide.com/search/view?search_top= {{{s}}} &x=0&y=0"},
      {"c":"Tech","d":"wiki.archlinux.fr","r":0,"s":"Wiki Français Archlinux","sc":"Sysadmin (Arch)","t":"archlinuxfr","u":"https://wiki.archlinux.fr/index.php?title=Spécial%3ARecherche&profile=default&fulltext=Search&search={{{s}}}"},
      {"c":"Online Services","d":"www.xe.com","r":0,"s":"XE (AUD2EUR)","sc":"Tools","t":"AUD2EUR","u":"http://www.xe.com/currencyconverter/convert/?Amount={{{s}}}&From=AUD&To=EUR"},
      {"c":"Tech","d":"","r":735,"s":"Search all !bangs","sc":"Search (DDG)","t":"bang","u":"/bang?q={{{s}}}"},
      {"c":"Entertainment","d":"www.allocine.fr","r":0,"s":"Allociné","sc":"Movies","t":"allociné","u":"http://www.allocine.fr/recherche/?q={{{s}}}"},
      {"c":"Tech","d":"x.test","r":5,"s":"Broken","sc":"Tab","t":"tabbed","u":"https://x.test/?q={{{s}}}\t&x=1"},
      {"c":"Tech","d":"x.test","r":5,"s":"Spaced","sc":"Space","t":"two words","u":"https://x.test/?q={{{s}}}"},
      {"c":"Tech","d":"x.test","r":5,"s":"Relative to nothing","sc":"Bad","t":"ftp","u":"ftp://x.test/{{{s}}}"}
    ]"#;

    fn duckduckgo(json: &str) -> List {
        List::duckduckgo(
            duckduckgo_cache(json, 1_700_000_000)
                .expect("sample parses")
                .0,
        )
    }

    fn sample() -> Table {
        Table::new(duckduckgo(DUCKDUCKGO_SAMPLE), &KAGI)
    }

    fn resolve(table: &Table, trigger: &str, query: &str) -> String {
        table.resolve(trigger, query).expect(trigger)
    }

    #[test]
    fn duckduckgo_bangs_resolve_to_the_site_like_duckduckgo_does() {
        let table = sample();
        // Observed on DuckDuckGo: `!g café (x) ~*!'` keeps `!()*._~` and
        // encodes everything else, `-` and `'` included, a space as %20.
        assert_eq!(
            resolve(&table, "g", "café (x) ~*!' a&b=c/d?e+f foo-bar"),
            "https://www.google.com/search?q=caf%C3%A9%20(x)%20~*!%27%20a%26b%3Dc%2Fd%3Fe%2Bf%20foo%2Dbar"
        );
        assert_eq!(
            resolve(&table, "w", "100%"),
            "https://en.wikipedia.org/wiki/Special:Search?search=100%25"
        );
        assert_eq!(
            resolve(&table, "gh", "rust;lang:x"),
            "https://github.com/search?utf8=%E2%9C%93&q=rust%3Blang%3Ax"
        );
        assert_eq!(
            resolve(&table, "yt", "a#b"),
            "https://www.youtube.com/results?search_query=a%23b"
        );
        assert_eq!(
            resolve(&table, "mx", "a b"),
            "http://mxtoolbox.com/SuperTool.aspx?action=mx%3aa%20b&run=networktools"
        );
        assert_eq!(
            resolve(&table, "abcya", "cat dog"),
            "https://www.abcya.com/search/?term=cat%20dog&type=cat%20dog"
        );
        assert_eq!(
            resolve(&table, "G", "x"),
            "https://www.google.com/search?q=x",
            "triggers match case-insensitively"
        );
        assert_eq!(
            resolve(&table, "aud2eur", "12"),
            "http://www.xe.com/currencyconverter/convert/?Amount=12&From=AUD&To=EUR"
        );
        assert_eq!(
            resolve(&table, "ALLOCINÉ", "amélie"),
            "http://www.allocine.fr/recherche/?q=am%C3%A9lie",
            "non-ASCII triggers fold case too"
        );
    }

    #[test]
    fn duckduckgo_edge_templates_follow_its_redirects() {
        let table = sample();
        // An empty query opens the bang's domain.
        assert_eq!(resolve(&table, "g", ""), "https://www.google.com");
        assert_eq!(resolve(&table, "mx", "  "), "https://mxtoolbox.com");
        // A template without `{{{s}}}` opens as written.
        assert_eq!(
            resolve(&table, "climed", "foo"),
            "http://www.climedweb.com/wp/?s="
        );
        // DuckDuckGo's own searches resolve against duckduckgo.com.
        assert_eq!(
            resolve(&table, "appstore", "x y"),
            "https://duckduckgo.com/?q=site%3Aitunes.apple.com%2Fus%2Fapp%2F+x%20y"
        );
        assert_eq!(
            resolve(&table, "bang", ""),
            "https://duckduckgo.com/bang?q="
        );
        // A raw space or non-ASCII byte in a template is escaped.
        assert_eq!(
            resolve(&table, "aapt", "x"),
            "http://www.aptoide.com/search/view?search_top=%20x%20&x=0&y=0"
        );
        assert_eq!(
            resolve(&table, "archlinuxfr", "é"),
            "https://wiki.archlinux.fr/index.php?title=Sp%C3%A9cial%3ARecherche&profile=default&fulltext=Search&search=%C3%A9"
        );
        assert_eq!(table.resolve("missing", "x"), Err("unknown bang"));
        assert_eq!(
            table.resolve(&"x".repeat(65), "x"),
            Err("bang token too long")
        );
    }

    #[test]
    fn kagi_bangs_follow_their_format_flags() {
        let table = Table::new(List::empty(), &KAGI);
        // Kagi's default: encoded, a space as `+`.
        assert_eq!(
            resolve(&table, "gh", "async await"),
            "https://github.com/search?q=async+await"
        );
        // Aliases resolve like their bang.
        assert_eq!(
            resolve(&table, "github", "x"),
            "https://github.com/search?q=x"
        );
        // An empty query opens the snap domain, else the base path.
        assert_eq!(resolve(&table, "hn", ""), "https://news.ycombinator.com");
        assert_eq!(resolve(&table, "gh", ""), "https://github.com/");
        // Query patterns fill `$1`, `$2`, … with encoded captures.
        assert_eq!(
            resolve(&table, "rsr", "rust async await"),
            "https://reddit.com/r/rust/search?q=async+await&restrict_sr=on"
        );
        assert_eq!(
            resolve(&table, "xec", "USD EUR 12.5"),
            "https://www.xe.com/currencyconverter/convert/?Amount=12.5&From=USD&To=EUR"
        );
        assert_eq!(
            table.resolve("xec", "twelve dollars"),
            Err("the query does not match the bang's pattern")
        );
        assert_eq!(resolve(&table, "rsr", ""), "https://reddit.com/");
        // Kagi's relative templates are Kagi searches: left out.
        assert!(table.get("4chan").is_none());
        assert!(table.get("deepwiki").is_none());
        // Non-ASCII triggers resolve folded.
        assert!(table.get("ДРОМ").is_some());
    }

    #[test]
    fn unencoded_kagi_queries_change_only_spaces() {
        let bang = Bang {
            trigger: "raw",
            template: "https://example.test/{{{s}}}",
            name: "",
            domain: "",
            snap: "",
            category: "",
            subcategory: "",
            pattern: "",
            format: Format::kagi("-").unwrap(),
            rank: 0,
        };
        assert_eq!(
            url(&bang, "a/b c?d é").unwrap(),
            "https://example.test/a/b%20c?d%20%C3%A9"
        );
        let plus = Bang {
            format: Format::kagi("p").unwrap(),
            ..bang
        };
        assert_eq!(url(&plus, "a b").unwrap(), "https://example.test/a+b");
        assert_eq!(url(&plus, "").unwrap(), "https://example.test/");
        assert_eq!(Format::kagi("bx"), None);
        assert_eq!(Format::kagi(""), None);
    }

    #[test]
    fn duckduckgo_wins_and_kagi_fills_the_triggers_it_lacks() {
        let table = sample();
        // Both lists define `gh`: DuckDuckGo's template wins.
        assert_eq!(
            table.get("gh").map(|bang| bang.template),
            Some("https://github.com/search?utf8=%E2%9C%93&q={{{s}}}")
        );
        // Only Kagi defines the alias `github`.
        assert_eq!(
            table.get("github").map(|bang| bang.template),
            Some("https://github.com/search?q={{{s}}}")
        );
        let duckduckgo_only = Table::new(duckduckgo(DUCKDUCKGO_SAMPLE), &EMPTY).counts();
        // 20 entries: three are invalid and left out of the cache, and `ai`,
        // `fb` and `f` belong to other owners.
        assert_eq!(
            duckduckgo_only,
            Counts {
                duckduckgo: 14,
                kagi: 0,
                dropped: 3
            }
        );
        let served = [
            "g",
            "w",
            "gh",
            "yt",
            "i",
            "appstore",
            "climed",
            "abcya",
            "mx",
            "aapt",
            "archlinuxfr",
            "AUD2EUR",
            "bang",
            "allociné",
        ];
        let shadowed: Vec<&str> = KAGI
            .bangs()
            .map(|bang| bang.trigger)
            .filter(|trigger| {
                served
                    .iter()
                    .any(|served| cmp_folded(served, trigger).is_eq())
            })
            .collect();
        assert!(
            ["g", "w", "gh", "yt"]
                .iter()
                .all(|trigger| shadowed.contains(trigger))
        );
        let counts = sample().counts();
        assert_eq!(counts.duckduckgo, served.len());
        assert_eq!(
            counts.kagi,
            KAGI.len() - shadowed.len(),
            "Kagi fills every trigger the sample lacks"
        );
    }

    #[test]
    fn reserved_triggers_are_neither_listed_nor_served() {
        let table = sample();
        for trigger in RESERVED {
            assert!(table.get(trigger).is_none(), "!{trigger} is reserved");
            assert!(
                table.get(&trigger.to_uppercase()).is_none(),
                "!{trigger} is reserved in any case"
            );
        }
        assert!(
            table
                .catalog()
                .iter()
                .all(|row| !reserved(row.payload_str().unwrap()))
        );
    }

    /// The reserved list is exactly Flash's own `!f` plus every token the
    /// other bundled plugins declare, so a trigger has one owner.
    #[test]
    fn reserved_triggers_match_the_other_bundled_owners() {
        fn tokens(manifest: &str) -> Vec<String> {
            let manifest: serde_json::Value = serde_json::from_str(manifest).unwrap();
            manifest["bangs"]
                .as_array()
                .unwrap()
                .iter()
                .map(|item| item["token"].as_str().unwrap().to_string())
                .collect()
        }
        let mut owned = vec!["f".to_string()];
        owned.extend(tokens(include_str!("../../browsers/manifest.json")));
        owned.extend(tokens(include_str!("../../aiproviders/manifest.json")));
        owned.sort();
        let mut reserved: Vec<String> = RESERVED.iter().map(|token| token.to_string()).collect();
        reserved.sort();
        assert_eq!(reserved, owned);
        assert_eq!(
            tokens(include_str!("../manifest.json")),
            ["*"],
            "this plugin claims only the catch-all"
        );
    }

    /// Every AI chat bang either list carries in its AI category belongs to
    /// `aiproviders`, which pre-fills and submits the chat. OpenRouter's model
    /// search is listed there but opens no chat, so it stays a search bang.
    #[test]
    fn the_ai_chatbot_category_belongs_to_aiproviders() {
        let searches = ["opr", "openrouter"];
        let chatbots: Vec<&str> = KAGI_TEXT
            .lines()
            .filter(|line| !line.starts_with('#'))
            .filter_map(|line| kagi_record(line))
            .filter(|(bang, _)| bang.subcategory == "AI Chatbots")
            .flat_map(|(bang, aliases)| {
                std::iter::once(bang.trigger).chain(aliases.split(' ').filter(|a| !a.is_empty()))
            })
            .filter(|trigger| !searches.contains(trigger))
            .collect();
        assert_eq!(chatbots.len(), 19, "{chatbots:?}");
        for trigger in chatbots {
            assert!(reserved(trigger), "!{trigger} is an AI chat bang");
        }
        for search in searches {
            assert!(KAGI.get(search).is_some(), "!{search} stays a search bang");
        }
    }

    #[test]
    fn the_vendored_snapshot_is_complete_sorted_and_bounded() {
        assert!(
            KAGI_TEXT.len() < 2 * 1024 * 1024,
            "{} bytes",
            KAGI_TEXT.len()
        );
        assert!(KAGI_TEXT.contains("at commit 9867d7e7aecdf013f96d4ff0ce4b9667bfacc137"));
        let triggers: Vec<&str> = records(KAGI_TEXT)
            .map(|(_, line)| line.split('\t').next().unwrap())
            .collect();
        assert_eq!(triggers.len(), 10_910);
        assert!(
            triggers
                .windows(2)
                .all(|pair| cmp_folded(pair[0], pair[1]).is_lt()),
            "the snapshot is sorted by lowercase trigger"
        );
        let aliases: usize = records(KAGI_TEXT)
            .filter_map(|(_, line)| kagi_record(line))
            .map(|(_, aliases)| aliases.split(' ').filter(|a| !a.is_empty()).count())
            .sum();
        assert_eq!(triggers.len() + aliases, 13_637, "every trigger and alias");
        assert_eq!(KAGI.len() + KAGI.dropped(), 13_637);
        assert!(KAGI.len() > 13_000 && KAGI.len() <= MAX_BANGS);
    }

    #[test]
    fn the_catalog_lists_the_best_ranked_bangs_within_the_quota() {
        let table = sample();
        let rows = table.catalog();
        assert_eq!(rows.len(), MAX_CATALOG_ROWS);
        let titles: Vec<&str> = rows.iter().take(4).map(|row| row.title.as_str()).collect();
        assert_eq!(titles, ["!g", "!yt", "!w", "!i"]);
        let google = &rows[0];
        assert_eq!(google.source, SOURCE);
        assert_eq!(google.meta("kind"), Some("bang"));
        assert_eq!(
            google.meta("subtitle"),
            Some("Google · Online Services › Google")
        );
        assert_eq!(google.payload_str(), Some("g"));
        assert_eq!(google.meta("priority"), Some("urgent"));
        let encoded = serde_json::to_vec(&rows).unwrap();
        assert!(
            encoded.len() < 4 * 1024 * 1024,
            "{} bytes exceed the catalog quota",
            encoded.len()
        );
    }

    #[test]
    fn the_cache_is_sorted_valid_and_reloads() {
        let (cache, count) = duckduckgo_cache(DUCKDUCKGO_SAMPLE, 1_700_000_000).unwrap();
        assert_eq!(count, 17, "the tab, space and ftp entries are left out");
        assert_eq!(cache_fetched_at(&cache), Some(1_700_000_000));
        let triggers: Vec<&str> = records(&cache)
            .map(|(_, line)| line.split('\t').next().unwrap())
            .collect();
        assert_eq!(triggers.len(), count);
        assert!(
            triggers
                .windows(2)
                .all(|pair| cmp_folded(pair[0], pair[1]).is_lt())
        );
        assert!(cache.contains("\nappstore\t9\thttps://duckduckgo.com/?q=site%3A"));
        assert!(!cache.contains("bang=true \t"), "templates are trimmed");
        assert_eq!(cache_fetched_at("g\t1\thttps://x/{{{s}}}\t\t\t\t\n"), None);
        assert_eq!(
            duckduckgo_cache("{\"not\":\"a list\"}", 0),
            Err("not a bang list")
        );
        // A repeated trigger keeps its first entry.
        let (repeated, count) = duckduckgo_cache(
            r#"[{"t":"x","u":"https://one.test/{{{s}}}","r":1},{"t":"X","u":"https://two.test/{{{s}}}","r":2}]"#,
            0,
        )
        .unwrap();
        assert_eq!(count, 1);
        assert_eq!(
            List::duckduckgo(repeated)
                .get("x")
                .map(|bang| bang.template),
            Some("https://one.test/{{{s}}}")
        );
    }

    #[test]
    fn an_unsorted_or_damaged_cache_still_indexes_its_valid_lines() {
        let list = List::duckduckgo(
            "# header\nzz\t1\thttps://z.test/{{{s}}}\t\t\t\t\naa\t2\thttps://a.test/{{{s}}}\t\t\t\t\nbad line\nrel\t0\t/relative\t\t\t\t\n"
                .to_string(),
        );
        assert_eq!(list.len(), 2);
        assert_eq!(list.dropped(), 2);
        assert_eq!(list.get("AA").map(|bang| bang.rank), Some(2));
        assert_eq!(list.get("zz").map(|bang| bang.rank), Some(1));
    }

    #[test]
    fn subtitles_and_priorities_follow_the_data() {
        let table = sample();
        assert_eq!(
            subtitle(&table.get("gh").unwrap()),
            "GitHub · Tech › Programming"
        );
        assert_eq!(priority(0), Priority::Low);
        assert_eq!(priority(735), Priority::Normal);
        assert_eq!(priority(4_389), Priority::High);
        assert_eq!(priority(13_881), Priority::Important);
        assert_eq!(priority(1_750_254), Priority::Urgent);
    }
}
