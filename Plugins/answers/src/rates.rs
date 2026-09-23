use std::collections::BTreeMap;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock, RwLock};
use std::time::Duration;

use flash_plugin::{Context, PollHandle};
use quick_xml::events::{BytesStart, Event};
use quick_xml::{Reader, XmlVersion};
use serde::{Deserialize, Serialize};
use tokio::io::AsyncReadExt;

const ECB_DAILY_URL: &str = "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml";
const CACHE_FILENAME: &str = "ecb-rates.json";
const MAX_CACHE_BYTES: u64 = 1024 * 1024;
const REFRESH_INTERVAL: Duration = Duration::from_secs(6 * 60 * 60);
const RETRY_INTERVAL: Duration = Duration::from_secs(15 * 60);

#[derive(Clone, Debug, Serialize, Deserialize)]
pub(crate) struct ExchangeRates {
    pub(crate) as_of: String,
    relative_to_eur: BTreeMap<String, f64>,
}

impl Default for ExchangeRates {
    fn default() -> Self {
        Self {
            as_of: String::new(),
            relative_to_eur: BTreeMap::from([("EUR".to_string(), 1.0)]),
        }
    }
}

impl ExchangeRates {
    fn is_fresh_snapshot(&self) -> bool {
        !self.as_of.is_empty() && self.relative_to_eur.len() > 1
    }

    pub(crate) fn relative_to_eur(&self, currency: &str) -> Option<f64> {
        self.relative_to_eur
            .get(&currency.to_ascii_uppercase())
            .copied()
    }

    pub(crate) fn currencies(&self) -> impl Iterator<Item = &str> {
        self.relative_to_eur.keys().map(String::as_str)
    }
}

#[derive(Clone, Default)]
pub(crate) struct RatesStore(Arc<RwLock<Arc<ExchangeRates>>>);

impl RatesStore {
    pub(crate) fn snapshot(&self) -> Arc<ExchangeRates> {
        self.0
            .read()
            .map(|rates| Arc::clone(&rates))
            .unwrap_or_else(|_| Arc::new(ExchangeRates::default()))
    }

    fn replace(&self, rates: ExchangeRates) {
        if let Ok(mut current) = self.0.write() {
            *current = Arc::new(rates);
        }
    }

    #[cfg(test)]
    pub(crate) fn from_rates(rates: ExchangeRates) -> Self {
        Self(Arc::new(RwLock::new(Arc::new(rates))))
    }
}

#[derive(Clone)]
pub(crate) struct SnapshotRateHandler(pub(crate) Arc<ExchangeRates>);

impl fend_core::ExchangeRateFnV2 for SnapshotRateHandler {
    fn relative_to_base_currency(
        &self,
        currency: &str,
        _options: &fend_core::ExchangeRateFnV2Options,
    ) -> Result<f64, Box<dyn std::error::Error + Send + Sync + 'static>> {
        self.0.relative_to_eur(currency).ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::NotFound,
                format!("no warm ECB rate for {currency}"),
            )
            .into()
        })
    }
}

pub(crate) async fn seed_and_refresh(ctx: Context, store: RatesStore) {
    let path = ctx.data_dir().join(CACHE_FILENAME);
    let cached = load_cached(&path).await;
    if let Some(cached) = cached {
        store.replace(cached);
    }

    let handle: Arc<OnceLock<PollHandle>> = Arc::new(OnceLock::new());
    let slot = Arc::clone(&handle);
    let refresh = move |ctx: Context| {
        let store = store.clone();
        let path = path.clone();
        let slot = Arc::clone(&slot);
        async move {
            // Retry sooner than the steady cadence while the fetch is
            // failing, and drop back once rates land.
            let period = match fetch_rates(&ctx).await {
                Some(rates) => {
                    store.replace(rates.clone());
                    persist(&path, &rates).await;
                    REFRESH_INTERVAL
                }
                None => RETRY_INTERVAL,
            };
            if let Some(handle) = slot.get() {
                handle.set_period(period);
            }
        }
    };

    let registered = ctx.interval(REFRESH_INTERVAL, refresh.clone());
    drop(handle.set(registered));
    // Network availability must never hold calculator readiness hostage: a
    // first-run `1+1` should work even while the initial ECB request is in
    // flight. A last-good disk snapshot is loaded above, so repeat launches
    // still have currency conversion immediately; only a truly cold launch
    // warms it asynchronously.
    drop(tokio::spawn(refresh(ctx)));
}

async fn fetch_rates(ctx: &Context) -> Option<ExchangeRates> {
    // The host performs the request (`host.fetch`): the manifest's
    // `fetch_urls` allowlists exactly the ECB endpoint, so the plugin
    // keeps a fully network-denied sandbox with no curl subprocess.
    let body = match ctx.fetch(ECB_DAILY_URL).await {
        Ok(body) => body,
        Err(error) => {
            ctx.log("warn", &format!("[answers] rates fetch failed: {error}"));
            return None;
        }
    };
    parse_ecb_xml(&body).ok()
}

async fn load_cached(path: &Path) -> Option<ExchangeRates> {
    // The cache is plugin-owned, but it still sits on a mutable filesystem.
    // Bound the read itself rather than trusting metadata so a corrupt or
    // concurrently replaced file cannot allocate without limit during startup.
    let file = tokio::fs::File::open(path).await.ok()?;
    let mut bytes = Vec::with_capacity(MAX_CACHE_BYTES as usize);
    file.take(MAX_CACHE_BYTES + 1)
        .read_to_end(&mut bytes)
        .await
        .ok()?;
    if bytes.len() as u64 > MAX_CACHE_BYTES {
        return None;
    }
    let rates: ExchangeRates = serde_json::from_slice(&bytes).ok()?;
    rates.is_fresh_snapshot().then_some(rates)
}

async fn persist(path: &Path, rates: &ExchangeRates) {
    let Ok(bytes) = serde_json::to_vec(rates) else {
        return;
    };
    let temporary = temporary_path(path);
    if tokio::fs::write(&temporary, bytes).await.is_ok() {
        let _ = tokio::fs::rename(temporary, path).await;
    }
}

fn temporary_path(path: &Path) -> PathBuf {
    path.with_extension("json.tmp")
}

pub(crate) fn parse_ecb_xml(xml: &str) -> Result<ExchangeRates, String> {
    let mut reader = Reader::from_str(xml);
    reader.config_mut().trim_text(true);
    let mut as_of = String::new();
    let mut relative_to_eur = BTreeMap::from([("EUR".to_string(), 1.0)]);

    loop {
        match reader.read_event() {
            Ok(Event::Start(element)) | Ok(Event::Empty(element)) => {
                read_cube(&element, &mut as_of, &mut relative_to_eur)?;
            }
            Ok(Event::Eof) => break,
            Ok(_) => {}
            Err(error) => return Err(error.to_string()),
        }
    }

    let rates = ExchangeRates {
        as_of,
        relative_to_eur,
    };
    if rates.is_fresh_snapshot() {
        Ok(rates)
    } else {
        Err("ECB response contained no dated rates".to_string())
    }
}

fn read_cube(
    element: &BytesStart<'_>,
    as_of: &mut String,
    rates: &mut BTreeMap<String, f64>,
) -> Result<(), String> {
    if element.local_name().as_ref() != "Cube" {
        return Ok(());
    }
    let mut currency = None;
    let mut rate = None;
    for attribute in element.attributes() {
        let attribute = attribute.map_err(|error| error.to_string())?;
        let value = attribute
            .normalized_value(XmlVersion::Implicit1_0)
            .map_err(|error| error.to_string())?
            .into_owned();
        match attribute.key.as_ref() {
            "time" => *as_of = value,
            "currency" => currency = Some(value),
            "rate" => rate = value.parse::<f64>().ok(),
            _ => {}
        }
    }
    if let (Some(currency), Some(rate)) = (currency, rate) {
        if currency.len() == 3 && rate.is_finite() && rate > 0.0 {
            rates.insert(currency.to_ascii_uppercase(), rate);
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::parse_ecb_xml;

    #[test]
    fn parses_daily_ecb_cube() {
        let rates = parse_ecb_xml(
            r#"<?xml version="1.0"?>
            <gesmes:Envelope xmlns:gesmes="x">
              <Cube><Cube time="2026-07-17">
                <Cube currency="USD" rate="1.1622"/>
                <Cube currency="GBP" rate="0.85098"/>
              </Cube></Cube>
            </gesmes:Envelope>"#,
        )
        .unwrap();

        assert_eq!(rates.as_of, "2026-07-17");
        assert_eq!(rates.relative_to_eur("EUR"), Some(1.0));
        assert_eq!(rates.relative_to_eur("USD"), Some(1.1622));
        assert_eq!(rates.relative_to_eur("GBP"), Some(0.85098));
    }

    #[test]
    fn rejects_empty_or_undated_feed() {
        assert!(parse_ecb_xml("<Cube/>").is_err());
        assert!(parse_ecb_xml(r#"<Cube><Cube currency="USD" rate="1.2"/></Cube>"#).is_err());
    }
}
