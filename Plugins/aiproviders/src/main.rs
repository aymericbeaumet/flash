//! AI chat bangs and the weekly AI quota segments.
//!
//! Every AI chat trigger (`!claude`, `!chatgpt`, `!ai` for Duck.ai, …) is
//! this plugin's: it opens the provider, pre-filling the query where the
//! provider's URL takes one, and presses Return once the page had time to
//! load while the app it opened in still has focus. Search-engine bangs
//! belong to `searchproviders`, which leaves these triggers alone.
//!
//! The `claude`, `codex` and `grok` status segments carry only the metric
//! (`6%↻22h`); the template owns the names, colours, links and hover. The
//! quota rules live in [`quota`]: Claude from a read-only usage request with
//! the OAuth access token Claude Code stored (its login Keychain item, else
//! `~/.claude/.credentials.json`), Codex from `codex app-server`, Grok from
//! a read-only billing request with the access token already in Grok's auth
//! file. No token is ever refreshed or written. Quotas refresh only while a
//! status surface shows their segment, and only the shown providers.
//!
//! The manifest declares `"sandbox": false`: macOS refuses Apple Events from
//! a sandboxed sender, so the Return press through System Events could not
//! run, and the quota reads spawn `codex` (with its own network access and
//! credentials), `security` and `curl`. A token reaches curl on stdin, never
//! argv or logs, and the plugin stores percentages and times only.

mod quota;

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, LazyLock, Mutex, OnceLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use flash_plugin::process;
use flash_plugin::{
    CommandRequest, Context, Event, ObservedCadences, PerformResponse, PollPriority, Published,
    host_events, run,
};
use serde_json::Value;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::process::Command;
use tokio::sync::OnceCell;

use quota::{Entry, Quota, QuotaState};

const AUTOSEND_DELAY: Duration = Duration::from_millis(2_500);
/// The quota tick: once a minute while a segment is shown.
const QUOTA_TICK: Duration = Duration::from_secs(60);
const COMMAND_TIMEOUT: Duration = Duration::from_secs(6);
const STATE_FILE: &str = "quotas.json";
const GROK_AUTH_SETTING: &str = "grok_auth_file";
const GROK_AUTH_DEFAULT: &str = "~/.grok/auth.json";

static CODEX_PATH: LazyLock<OnceCell<Option<PathBuf>>> = LazyLock::new(OnceCell::new);

// -- Chat bangs -------------------------------------------------------------

/// An AI chat provider: `home` opens for an empty query, and `template`
/// (with `{query}`) pre-fills one. A provider whose URL takes no query
/// opens `home` either way.
#[derive(Debug, PartialEq, Eq)]
struct ChatProvider {
    token: &'static str,
    name: &'static str,
    home: &'static str,
    template: Option<&'static str>,
}

const fn chat(
    token: &'static str,
    name: &'static str,
    home: &'static str,
    template: Option<&'static str>,
) -> ChatProvider {
    ChatProvider {
        token,
        name,
        home,
        template,
    }
}

const DUCK_AI_HOME: &str = "https://duck.ai/";
const DUCK_AI: Option<&str> = Some("https://duckduckgo.com/?q={query}&ia=chat&bang=true");
const CHATGPT_HOME: &str = "https://chatgpt.com/";
const CHATGPT: Option<&str> = Some("https://chatgpt.com/?q={query}");
const GOOGLE_AI_HOME: &str = "https://www.google.com/?udm=50";
const GOOGLE_AI: Option<&str> = Some("https://www.google.com/search?q={query}&udm=50");
const LE_CHAT_HOME: &str = "https://chat.mistral.ai/chat";
const LE_CHAT: Option<&str> = Some("https://chat.mistral.ai/chat?q={query}");
const LUMO_HOME: &str = "https://lumo.proton.me/";
const LUMO: Option<&str> = Some("https://lumo.proton.me/?q={query}");
const PERPLEXITY_HOME: &str = "https://www.perplexity.ai/search";
const PERPLEXITY: Option<&str> = Some("https://www.perplexity.ai/search?q={query}");

/// Sorted by token so lookup stays allocation-free. Each token is one
/// manifest `bangs` item: every AI chat bang of DuckDuckGo's and Kagi's
/// lists (Duck.ai, Kagi's "AI Chatbots" and its Copilot, You.com and
/// DuckDuckGo AI Chat entries), plus the chat providers neither lists.
const PROVIDERS: &[ChatProvider] = &[
    chat("ai", "Duck.ai", DUCK_AI_HOME, DUCK_AI),
    chat("aichat", "Duck.ai", DUCK_AI_HOME, DUCK_AI),
    chat("cgpt", "ChatGPT", CHATGPT_HOME, CHATGPT),
    chat("chat", "Duck.ai", DUCK_AI_HOME, DUCK_AI),
    chat("chatgpt", "ChatGPT", CHATGPT_HOME, CHATGPT),
    chat(
        "claude",
        "Claude",
        "https://claude.ai/new",
        Some("https://claude.ai/new?q={query}"),
    ),
    chat(
        "copilot",
        "Microsoft Copilot",
        "https://copilot.microsoft.com/",
        Some("https://copilot.microsoft.com/?q={query}&bypassredir=1"),
    ),
    chat("ddg-ai", "Duck.ai", DUCK_AI_HOME, DUCK_AI),
    chat("ddg-chat", "Duck.ai", DUCK_AI_HOME, DUCK_AI),
    chat("deepseek", "DeepSeek", "https://chat.deepseek.com/", None),
    chat("duckai", "Duck.ai", DUCK_AI_HOME, DUCK_AI),
    chat(
        "felo",
        "Felo",
        "https://felo.ai/",
        Some("https://felo.ai/search?q={query}"),
    ),
    chat("gai", "Google AI Mode", GOOGLE_AI_HOME, GOOGLE_AI),
    chat(
        "gemini",
        "Gemini",
        "https://gemini.google.com/app",
        Some("https://gemini.google.com/app?q={query}"),
    ),
    chat("googleai", "Google AI Mode", GOOGLE_AI_HOME, GOOGLE_AI),
    chat(
        "grok",
        "Grok",
        "https://grok.com/",
        Some("https://grok.com/?q={query}"),
    ),
    chat(
        "huggingchat",
        "HuggingChat",
        "https://huggingface.co/chat/",
        None,
    ),
    chat(
        "ithy",
        "Ithy",
        "https://ithy.com/",
        Some("https://ithy.com/?query={query}"),
    ),
    chat(
        "kagiassistant",
        "Kagi Assistant",
        "https://kagi.com/assistant",
        Some("https://kagi.com/assistant?q={query}"),
    ),
    chat("kimi", "Kimi", "https://www.kimi.com/", None),
    chat("lechat", "Le Chat", LE_CHAT_HOME, LE_CHAT),
    chat("lmarena", "LMArena", "https://lmarena.ai/", None),
    chat("lumo", "Lumo", LUMO_HOME, LUMO),
    chat("metaai", "Meta AI", "https://www.meta.ai/", None),
    chat("mistral", "Le Chat", LE_CHAT_HOME, LE_CHAT),
    chat("perplexity", "Perplexity", PERPLEXITY_HOME, PERPLEXITY),
    chat(
        "phind",
        "Phind",
        "https://www.phind.com/",
        Some("https://www.phind.com/search?q={query}"),
    ),
    chat("piai", "Pi", "https://pi.ai/", None),
    chat("poeai", "Poe", "https://poe.com/", None),
    chat("pplx", "Perplexity", PERPLEXITY_HOME, PERPLEXITY),
    chat("ppx", "Perplexity", PERPLEXITY_HOME, PERPLEXITY),
    chat("protonlumo", "Lumo", LUMO_HOME, LUMO),
    chat("qwen", "Qwen Chat", "https://chat.qwen.ai/", None),
    chat(
        "t3",
        "T3 Chat",
        "https://www.t3.chat/",
        Some("https://www.t3.chat/new?q={query}"),
    ),
    chat(
        "v0",
        "v0",
        "https://v0.app/",
        Some("https://v0.app/?q={query}"),
    ),
    chat(
        "youai",
        "You.com",
        "https://you.com/",
        Some("https://you.com/search?q={query}"),
    ),
    chat("zai", "Z.ai", "https://chat.z.ai/", None),
    // Kagi's Russian alias for Google AI Mode.
    chat("гии", "Google AI Mode", GOOGLE_AI_HOME, GOOGLE_AI),
];

fn lookup(bang: &str) -> Option<&'static ChatProvider> {
    PROVIDERS
        .binary_search_by(|provider| provider.token.cmp(bang))
        .ok()
        .map(|index| &PROVIDERS[index])
}

/// The URL to open, and whether the page then gets its Return press: only
/// a pre-filled query is submitted.
fn chat_url(provider: &ChatProvider, query: &str) -> (String, bool) {
    match provider.template.filter(|_| !query.is_empty()) {
        Some(template) => (template.replace("{query}", &percent_encode(query)), true),
        None => (provider.home.to_string(), false),
    }
}

/// Match `urllib.parse.quote`'s default query-value behavior: RFC 3986
/// unreserved bytes and `/` pass through, every other UTF-8 byte is `%XX`.
fn percent_encode(input: &str) -> String {
    let mut encoded = String::with_capacity(input.len());
    for byte in input.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' | b'/' => {
                encoded.push(byte as char)
            }
            _ => encoded.push_str(&format!("%{byte:02X}")),
        }
    }
    encoded
}

/// Return, pressed only while the app the page opened in still has focus:
/// by the time the page has loaded the user may be typing elsewhere, where
/// a stray Return would submit or run whatever is there. `None` for a bundle
/// id that could not be spliced into AppleScript verbatim.
fn autosend_script(bundle_id: &str) -> Option<flash_plugin::AppleScriptOperation> {
    let valid = !bundle_id.is_empty()
        && bundle_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'.' || byte == b'-');
    valid.then(|| flash_plugin::AppleScriptOperation::ChatSubmit {
        bundle_id: bundle_id.to_string(),
    })
}

// -- Quota settings -----------------------------------------------------------

/// Where each quota is read. `grok_auth_file` is `None` when its setting is
/// invalid: Grok then keeps its last reading rather than reading another
/// file.
#[derive(Clone, Debug, PartialEq)]
struct Sources {
    claude: quota::ClaudeCredentials,
    claude_usage_url: String,
    grok_auth_file: Option<PathBuf>,
}

/// An explicit path setting, `~/` expanded against `home`.
fn configured_path(
    value: Option<&Value>,
    default: &str,
    home: Option<&Path>,
) -> Result<PathBuf, &'static str> {
    let raw = match value {
        None => default,
        Some(Value::String(raw)) => raw.as_str(),
        Some(_) => return Err("not_a_string"),
    };
    let path = match raw.strip_prefix("~/") {
        Some(rest) => home.ok_or("no_home")?.join(rest),
        None => PathBuf::from(raw),
    };
    if path.is_absolute() {
        Ok(path)
    } else {
        Err("not_absolute")
    }
}

/// Claude Code's own credential locations, and the Grok setting, logging an
/// invalid one once without its value.
fn configured_sources(ctx: &Context) -> Sources {
    let home = std::env::var_os("HOME").map(PathBuf::from);
    let resolve = |setting: &str, default: &str| {
        let value = ctx.config_json::<Value>(setting);
        configured_path(value.as_ref(), default, home.as_deref())
            .map_err(|reason| {
                ctx.log_fields(
                    "warn",
                    "[aiproviders] invalid quota setting; that quota keeps its last reading",
                    BTreeMap::from([
                        ("setting".to_string(), setting.to_string()),
                        ("reason".to_string(), reason.to_string()),
                    ]),
                );
            })
            .ok()
    };
    Sources {
        claude: quota::ClaudeCredentials::claude_code(home.as_deref()),
        claude_usage_url: quota::CLAUDE_USAGE_URL.to_string(),
        grok_auth_file: resolve(GROK_AUTH_SETTING, GROK_AUTH_DEFAULT),
    }
}

// -- Observation scope --------------------------------------------------------

/// The quotas a status surface shows, from `core:status.observed`: a quota
/// refreshes only while its own segment is shown. Every quota counts until
/// the host's first report.
#[derive(Debug, Default)]
struct ObservedScope {
    shown: Mutex<Option<BTreeSet<Quota>>>,
}

impl ObservedScope {
    fn current(&self) -> Vec<Quota> {
        match &*self.shown.lock().unwrap_or_else(|error| error.into_inner()) {
            Some(shown) => shown.iter().copied().collect(),
            None => Quota::ALL.to_vec(),
        }
    }

    /// Apply a report; the quotas it newly shows (all shown ones on the
    /// first report) refresh at once rather than a tick later.
    fn observe(&self, segments: &[String]) -> Vec<Quota> {
        let next: BTreeSet<Quota> = segments
            .iter()
            .filter_map(|segment| Quota::from_segment(segment))
            .collect();
        let mut shown = self.shown.lock().unwrap_or_else(|error| error.into_inner());
        let gained = match &*shown {
            Some(previous) => next.difference(previous).copied().collect(),
            None => next.iter().copied().collect(),
        };
        *shown = Some(next);
        gained
    }
}

// -- Quota runtime ------------------------------------------------------------

#[derive(Clone, Debug, PartialEq, Eq)]
struct Metrics {
    claude: String,
    codex: String,
    grok: String,
}

fn render_metrics(state: &QuotaState, now: u64, offset: &dyn Fn(u64) -> i64) -> Metrics {
    let metric = |quota| quota::metric(state.get(quota), now, offset);
    Metrics {
        claude: metric(Quota::Claude),
        codex: metric(Quota::Codex),
        grok: metric(Quota::Grok),
    }
}

#[derive(Debug, Default)]
struct QuotaRuntime {
    loaded: bool,
    state: QuotaState,
    published: Published<Metrics>,
}

type SharedQuotas = Arc<tokio::sync::Mutex<QuotaRuntime>>;

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn state_path(ctx: &Context) -> PathBuf {
    ctx.data_dir().join(STATE_FILE)
}

async fn ensure_loaded(ctx: &Context, runtime: &mut QuotaRuntime) {
    if runtime.loaded {
        return;
    }
    if let Ok(bytes) = tokio::fs::read(state_path(ctx)).await {
        runtime.state = QuotaState::from_json(&bytes);
    }
    runtime.loaded = true;
}

/// Atomically replace the state file, readable by the user alone.
async fn write_state(path: &Path, state: &QuotaState) -> bool {
    use std::os::unix::fs::PermissionsExt;

    let Some(parent) = path.parent() else {
        return false;
    };
    if tokio::fs::create_dir_all(parent).await.is_err() {
        return false;
    }
    let temporary = path.with_extension(format!("json.tmp-{}", std::process::id()));
    let written = async {
        let mut file = tokio::fs::OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .mode(0o600)
            .open(&temporary)
            .await?;
        file.write_all(&state.to_json()).await?;
        file.flush().await?;
        file.sync_all().await?;
        drop(file);
        tokio::fs::set_permissions(&temporary, std::fs::Permissions::from_mode(0o600)).await?;
        tokio::fs::rename(&temporary, path).await
    }
    .await;
    if written.is_err() {
        let _ = tokio::fs::remove_file(&temporary).await;
    }
    written.is_ok()
}

fn publish_metrics(ctx: &Context, runtime: &mut QuotaRuntime, now: u64) {
    let metrics = render_metrics(&runtime.state, now, &quota::local_utc_offset);
    if let Some(metrics) = runtime.published.update(metrics) {
        ctx.status([
            (Quota::Claude.segment(), metrics.claude.as_str()),
            (Quota::Codex.segment(), metrics.codex.as_str()),
            (Quota::Grok.segment(), metrics.grok.as_str()),
        ]);
    }
}

/// Publish the stored readings as they read now.
async fn publish_stored(ctx: &Context, shared: &SharedQuotas) {
    let mut runtime = shared.lock().await;
    ensure_loaded(ctx, &mut runtime).await;
    publish_metrics(ctx, &mut runtime, unix_now());
}

/// Refresh the due `quotas`, persist a changed state, and republish.
/// Serialized by the runtime lock.
async fn refresh_quotas(ctx: &Context, shared: &SharedQuotas, sources: &Sources, quotas: &[Quota]) {
    let mut runtime = shared.lock().await;
    ensure_loaded(ctx, &mut runtime).await;
    let now = unix_now();
    let wants = |quota| quotas.contains(&quota);
    let state = &runtime.state;
    let claude = async {
        if wants(Quota::Claude) && quota::wants_fetch(&state.entry(Quota::Claude), now) {
            Some(quota::fetch_claude(&sources.claude, &sources.claude_usage_url, now).await)
        } else {
            None
        }
    };
    let codex = async {
        if wants(Quota::Codex) && quota::wants_fetch(&state.entry(Quota::Codex), now) {
            Some(fetch_codex().await)
        } else {
            None
        }
    };
    let grok = async {
        match &sources.grok_auth_file {
            Some(path)
                if wants(Quota::Grok) && quota::wants_fetch(&state.entry(Quota::Grok), now) =>
            {
                Some(quota::fetch_grok(path, now).await)
            }
            _ => None,
        }
    };
    let (claude, codex, grok) = tokio::join!(claude, codex, grok);

    let mut next = runtime.state.clone();
    if let Some(fetch) = claude {
        let entry = quota::after_token_fetch(next.entry(Quota::Claude), now, fetch);
        next.set(Quota::Claude, entry);
    }
    if let Some(window) = codex {
        let entry = quota::after_codex(next.entry(Quota::Codex), now, window);
        next.set(Quota::Codex, entry);
    }
    if let Some(fetch) = grok {
        let entry = quota::after_token_fetch(next.entry(Quota::Grok), now, fetch);
        next.set(Quota::Grok, entry);
    }
    if next != runtime.state {
        runtime.state = next;
        if !write_state(&state_path(ctx), &runtime.state).await {
            ctx.log("warn", "[aiproviders] quota state write failed");
        }
    }
    publish_metrics(ctx, &mut runtime, now);
}

// -- Codex ----------------------------------------------------------------------

#[derive(Debug)]
struct CapturedOutput {
    stdout: String,
}

async fn capture(
    program: &Path,
    args: &[&str],
    stdin: Option<Vec<u8>>,
    timeout: Duration,
) -> Option<CapturedOutput> {
    let mut command = Command::new(program);
    command.args(args);
    let output = process::capture(
        &mut command,
        stdin,
        timeout,
        quota::STDOUT_LIMIT,
        quota::STDERR_LIMIT,
    )
    .await
    .ok()?;
    output.status.success().then(|| CapturedOutput {
        stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
    })
}

/// The weekly Codex window from `account/rateLimits/read`, through Codex's
/// own app-server and authentication.
async fn fetch_codex() -> Option<Entry> {
    let codex = resolved_codex_path().await?;
    let input = concat!(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{",
        "\"clientInfo\":{\"name\":\"flash-aiproviders\",\"version\":\"1\"},",
        "\"capabilities\":{\"experimentalApi\":true,\"requestAttestation\":false}}}\n",
        "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\"}\n",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"account/rateLimits/read\"}\n"
    );
    let response = capture_codex_rate_limits(&codex, input).await?;
    quota::parse_codex_rate_limits(&response)
}

async fn capture_codex_rate_limits(codex: &Path, input: &str) -> Option<String> {
    let mut command = Command::new(codex);
    command
        .args(["app-server", "--stdio"])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true);
    let mut child = command.spawn().ok()?;
    let mut stdin = child.stdin.take()?;
    stdin.write_all(input.as_bytes()).await.ok()?;
    stdin.flush().await.ok()?;
    let stdout = child.stdout.take()?.take((quota::STDOUT_LIMIT + 1) as u64);
    let mut lines = BufReader::new(stdout).lines();
    let response = tokio::time::timeout(COMMAND_TIMEOUT, async {
        while let Some(line) = lines.next_line().await.ok()? {
            if let Ok(value) = serde_json::from_str::<Value>(&line)
                && value.get("id").and_then(Value::as_u64) == Some(2)
            {
                return Some(line);
            }
        }
        None
    })
    .await
    .ok()
    .flatten();
    drop(stdin);
    let _ = child.start_kill();
    let _ = tokio::time::timeout(Duration::from_secs(1), child.wait()).await;
    response
}

async fn resolved_codex_path() -> Option<PathBuf> {
    CODEX_PATH.get_or_init(find_codex).await.clone()
}

async fn find_codex() -> Option<PathBuf> {
    let home = std::env::var_os("HOME").map(PathBuf::from);
    let mut candidates = vec![
        PathBuf::from("/opt/homebrew/bin/codex"),
        PathBuf::from("/opt/local/bin/codex"),
        PathBuf::from("/usr/bin/codex"),
    ];
    if let Some(home) = &home {
        candidates.push(home.join(".local/bin/codex"));
        candidates.push(home.join(".local/share/mise/shims/codex"));
    }
    if let Some(path) = find_on_path("codex") {
        candidates.push(path);
    }
    for path in candidates {
        if executable_file(&path).await {
            return Some(path);
        }
    }

    let mut mise_candidates = vec![
        PathBuf::from("/opt/homebrew/bin/mise"),
        PathBuf::from("/opt/local/bin/mise"),
    ];
    if let Some(home) = &home {
        mise_candidates.push(home.join(".local/bin/mise"));
    }
    if let Some(path) = find_on_path("mise") {
        mise_candidates.push(path);
    }
    for mise in mise_candidates {
        if !executable_file(&mise).await {
            continue;
        }
        if let Some(output) = capture(&mise, &["which", "codex"], None, COMMAND_TIMEOUT).await {
            let path = PathBuf::from(output.stdout.trim());
            if executable_file(&path).await {
                return Some(path);
            }
        }
    }

    let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".to_string());
    let output = capture(
        Path::new(&shell),
        &["-lic", "command -v codex"],
        None,
        COMMAND_TIMEOUT,
    )
    .await?;
    let path = PathBuf::from(output.stdout.lines().next()?.trim());
    executable_file(&path).await.then_some(path)
}

fn find_on_path(name: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|directory| directory.join(name))
        .find(|candidate| candidate.is_file())
}

async fn executable_file(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;

    tokio::fs::metadata(path)
        .await
        .map(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}

// -- Plugin -----------------------------------------------------------------------

#[derive(Default)]
struct AiProviders {
    quotas: SharedQuotas,
    sources: OnceLock<Sources>,
    scope: Arc<ObservedScope>,
    /// The quota tick runs only while a surface shows a quota segment: a
    /// chat bang starts this plugin too, and must not leave it reading
    /// files, spawning Codex and calling Grok every minute for nobody.
    cadences: ObservedCadences,
}

impl AiProviders {
    fn sources(&self, ctx: &Context) -> Sources {
        self.sources.get_or_init(|| configured_sources(ctx)).clone()
    }

    fn spawn_refresh(&self, ctx: Context, quotas: Vec<Quota>) {
        let shared = Arc::clone(&self.quotas);
        let sources = self.sources(&ctx);
        tokio::spawn(async move {
            refresh_quotas(&ctx, &shared, &sources, &quotas).await;
        });
    }
}

flash_plugin::plugin!(AiProviders);

impl FlashPlugin for AiProviders {
    async fn on_start(&self, ctx: Context) {
        publish_stored(&ctx, &self.quotas).await;

        let shared = Arc::clone(&self.quotas);
        let scope = Arc::clone(&self.scope);
        let sources = self.sources(&ctx);
        // `Low`: a file read and two fetches behind a one-minute cadence; a
        // second of slack is invisible and lets it coalesce with everything
        // else. Armed only while a quota segment is shown.
        self.cadences
            .interval(&ctx, QUOTA_TICK, PollPriority::Low, move |ctx| {
                let shared = Arc::clone(&shared);
                let sources = sources.clone();
                let quotas = scope.current();
                async move {
                    refresh_quotas(&ctx, &shared, &sources, &quotas).await;
                }
            });
    }

    async fn on_event(&self, ctx: Context, event: Event) {
        let Some(segments) = event
            .segments
            .as_deref()
            .filter(|_| event.name == host_events::STATUS_OBSERVED)
        else {
            return;
        };
        self.cadences.observe(segments);
        let gained = self.scope.observe(segments);
        if !gained.is_empty() {
            self.spawn_refresh(ctx, gained);
        }
    }

    async fn on_command(&self, ctx: Context, command: CommandRequest) -> PerformResponse {
        let bang = command.subcommand.to_lowercase();
        let Some(provider) = lookup(&bang) else {
            return PerformResponse::fail(format!("unknown ai provider: !{bang}"));
        };
        let (url, autosend) = chat_url(provider, &command.query());
        let handler = match ctx.open_url(&url).await {
            Ok(handler) => handler,
            Err(error) => return PerformResponse::fail(error),
        };
        if let Some(script) = handler
            .as_deref()
            .filter(|_| autosend)
            .and_then(autosend_script)
        {
            // The page needs a beat to load before Return reaches it: a host
            // deadline, so the command answers at once instead of holding
            // its perform open for the wait.
            ctx.after(
                AUTOSEND_DELAY,
                PollPriority::Normal,
                move |ctx| async move {
                    let _ = ctx.applescript(&script, Duration::from_secs(10)).await;
                },
            );
        }
        PerformResponse::ok()
    }
}

fn main() {
    run(AiProviders::default());
}

#[cfg(test)]
mod tests {
    use super::*;
    use flash_plugin::testing::Harness;
    use serde_json::json;
    use std::os::unix::fs::PermissionsExt;

    fn bang(subcommand: &str, args: &[&str]) -> CommandRequest {
        CommandRequest {
            subcommand: subcommand.to_string(),
            args: args.iter().map(|arg| arg.to_string()).collect(),
            ..CommandRequest::default()
        }
    }

    /// A chat bang opens through `host.open` and reports the host's refusal
    /// as its own failure.
    #[tokio::test]
    async fn a_refused_open_fails_with_the_host_error() {
        let mut harness = Harness::new("aiproviders");
        let ctx = harness.context();
        let request = tokio::spawn(async move {
            AiProviders::default()
                .on_command(ctx, bang("claude", &["hello"]))
                .await
        });

        let (id, method, params) = harness.next_host_request().await.expect("host request");
        assert_eq!(
            (method.as_str(), params),
            (
                "host.open",
                json!({ "url": "https://claude.ai/new?q=hello" })
            )
        );
        assert!(harness.reply_host(id, json!({ "ok": false, "error": "open failed" })));
        assert_eq!(
            serde_json::to_value(request.await.expect("command task")).expect("response"),
            json!({ "ok": false, "error": "open failed" })
        );
    }

    /// Opens `subcommand` with `args`, answers the open from Chrome, and
    /// returns the URL and whether a Return press was scheduled.
    async fn open(subcommand: &str, args: &[&str]) -> (String, bool) {
        let mut harness = Harness::new("aiproviders");
        let ctx = harness.context();
        let command = bang(subcommand, args);
        let request =
            tokio::spawn(async move { AiProviders::default().on_command(ctx, command).await });
        let (id, _, params) = harness.next_host_request().await.expect("host request");
        assert!(harness.reply_host(id, json!({ "ok": true, "bundle_id": "com.google.Chrome" })));
        assert_eq!(
            serde_json::to_value(request.await.expect("command task")).expect("response"),
            json!({ "ok": true })
        );
        let scheduled = harness
            .drain()
            .iter()
            .any(|frame| frame["method"] == "poll");
        (
            params["url"].as_str().unwrap_or_default().to_string(),
            scheduled,
        )
    }

    #[tokio::test]
    async fn only_a_prefilled_query_gets_the_return_press() {
        assert_eq!(
            open("claude", &["hello", "world"]).await,
            ("https://claude.ai/new?q=hello%20world".to_string(), true)
        );
        assert_eq!(
            open("claude", &[]).await,
            ("https://claude.ai/new".to_string(), false)
        );
        assert_eq!(
            open("DeepSeek", &["hello"]).await,
            ("https://chat.deepseek.com/".to_string(), false),
            "an open-only provider ignores the query and never presses Return"
        );
    }

    #[test]
    fn provider_table_is_sorted_unique_and_lowercase() {
        assert!(
            PROVIDERS
                .windows(2)
                .all(|pair| pair[0].token < pair[1].token)
        );
        for provider in PROVIDERS {
            assert_eq!(provider.token, provider.token.to_lowercase());
            assert_eq!(lookup(provider.token), Some(provider));
            assert!(provider.home.starts_with("https://"));
            if let Some(template) = provider.template {
                assert!(template.starts_with("https://"));
                assert_eq!(template.matches("{query}").count(), 1, "{}", provider.token);
            }
        }
        assert!(lookup("unknown").is_none());
    }

    fn describe(provider: &ChatProvider) -> String {
        match provider.template {
            Some(_) => format!("Open {} (pre-fills query if provided)", provider.name),
            None => format!("Open {}", provider.name),
        }
    }

    /// Every chat trigger is one manifest bang, and the manifest describes
    /// what the table does.
    #[test]
    fn manifest_bangs_are_exactly_the_provider_table() {
        let manifest: Value =
            serde_json::from_str(include_str!("../manifest.json")).expect("manifest JSON");
        let items: Vec<(String, String)> = manifest["bangs"]
            .as_array()
            .expect("bang items")
            .iter()
            .map(|item| {
                (
                    item["token"].as_str().unwrap_or_default().to_string(),
                    item["description"].as_str().unwrap_or_default().to_string(),
                )
            })
            .collect();
        let table: Vec<(String, String)> = PROVIDERS
            .iter()
            .map(|provider| (provider.token.to_string(), describe(provider)))
            .collect();
        assert_eq!(items, table);
        let status: Vec<&str> = manifest["status"]
            .as_array()
            .expect("status segments")
            .iter()
            .filter_map(Value::as_str)
            .collect();
        let segments: Vec<&str> = Quota::ALL.iter().map(|quota| quota.segment()).collect();
        assert_eq!(status, segments);
    }

    #[test]
    fn chat_urls_prefill_only_where_the_provider_takes_a_query() {
        let duck = lookup("ai").unwrap();
        assert_eq!(
            chat_url(duck, "what is rust?"),
            (
                "https://duckduckgo.com/?q=what%20is%20rust%3F&ia=chat&bang=true".to_string(),
                true
            )
        );
        assert_eq!(chat_url(duck, ""), ("https://duck.ai/".to_string(), false));
        assert_eq!(
            chat_url(lookup("mistral").unwrap(), "a/b"),
            ("https://chat.mistral.ai/chat?q=a/b".to_string(), true)
        );
        assert_eq!(
            chat_url(lookup("qwen").unwrap(), "hello"),
            ("https://chat.qwen.ai/".to_string(), false)
        );
        assert_eq!(
            chat_url(lookup("perplexity").unwrap(), ""),
            ("https://www.perplexity.ai/search".to_string(), false)
        );
    }

    #[test]
    fn query_encoding_matches_python_quote_defaults() {
        assert_eq!(percent_encode("hello world"), "hello%20world");
        assert_eq!(percent_encode("a/b?c=d"), "a/b%3Fc%3Dd");
        assert_eq!(percent_encode("café"), "caf%C3%A9");
        assert_eq!(percent_encode("-_.~"), "-_.~");
    }

    #[test]
    fn autosend_preserves_the_focus_guard_as_data() {
        assert_eq!(AUTOSEND_DELAY, Duration::from_millis(2_500));
        assert_eq!(
            autosend_script("com.google.Chrome"),
            Some(flash_plugin::AppleScriptOperation::ChatSubmit {
                bundle_id: "com.google.Chrome".into()
            })
        );
        assert_eq!(autosend_script(""), None);
        assert_eq!(autosend_script(r#"x" then key code 36 --"#), None);
    }

    #[test]
    fn path_settings_default_expand_home_and_reject_the_rest() {
        let home = Path::new("/Users/me");
        assert_eq!(
            configured_path(None, GROK_AUTH_DEFAULT, Some(home)),
            Ok(PathBuf::from("/Users/me/.grok/auth.json"))
        );
        assert_eq!(
            configured_path(Some(&json!("~/x/auth.json")), GROK_AUTH_DEFAULT, Some(home)),
            Ok(PathBuf::from("/Users/me/x/auth.json"))
        );
        assert_eq!(
            configured_path(Some(&json!("/tmp/a.json")), GROK_AUTH_DEFAULT, None),
            Ok(PathBuf::from("/tmp/a.json"))
        );
        assert_eq!(
            configured_path(Some(&json!("relative.json")), GROK_AUTH_DEFAULT, Some(home)),
            Err("not_absolute")
        );
        assert_eq!(
            configured_path(Some(&json!(true)), GROK_AUTH_DEFAULT, Some(home)),
            Err("not_a_string")
        );
        assert_eq!(
            configured_path(None, GROK_AUTH_DEFAULT, None),
            Err("no_home")
        );
    }

    /// An invalid setting disables that quota's source, logged once without
    /// its value. Claude is read where Claude Code keeps its credentials.
    #[test]
    fn invalid_settings_disable_their_source_and_log_without_the_value() {
        let mut harness = Harness::with_config(
            "aiproviders",
            json!({ "grok_auth_file": "secret-relative-path" }),
        );
        let sources = configured_sources(&harness.context());
        assert_eq!(sources.grok_auth_file, None);
        assert_eq!(
            sources.claude.keychain_service,
            Some(quota::CLAUDE_KEYCHAIN_SERVICE)
        );
        assert!(
            sources
                .claude
                .file
                .as_ref()
                .is_some_and(|file| file.ends_with(".claude/.credentials.json"))
        );
        assert_eq!(sources.claude_usage_url, quota::CLAUDE_USAGE_URL);
        let logs: Vec<Value> = harness
            .drain()
            .into_iter()
            .filter(|frame| frame["method"] == "log")
            .collect();
        assert_eq!(logs.len(), 1);
        assert_eq!(logs[0]["params"]["fields"]["setting"], "grok_auth_file");
        assert!(!logs[0].to_string().contains("secret-relative-path"));
    }

    fn segments(names: &[&str]) -> Vec<String> {
        names.iter().map(|name| name.to_string()).collect()
    }

    #[test]
    fn only_the_shown_quotas_refresh() {
        let scope = ObservedScope::default();
        assert_eq!(
            scope.current(),
            Quota::ALL,
            "every quota until the host reports"
        );
        assert_eq!(
            scope.observe(&segments(&["claude"])),
            [Quota::Claude],
            "the first report refreshes what it shows at once"
        );
        assert_eq!(scope.current(), [Quota::Claude]);
        assert_eq!(scope.observe(&segments(&["claude"])), []);
        assert_eq!(
            scope.observe(&segments(&["grok", "claude"])),
            [Quota::Grok],
            "a newly shown quota refreshes at once"
        );
        assert_eq!(scope.current(), [Quota::Claude, Quota::Grok]);
        assert_eq!(scope.observe(&[]), []);
        assert!(
            scope.current().is_empty(),
            "nothing shown, nothing refreshes"
        );
        assert_eq!(
            scope.observe(&segments(&["codex", "unknown"])),
            [Quota::Codex]
        );
    }

    #[test]
    fn an_unobserved_start_never_refreshes() {
        let scope = ObservedScope::default();
        assert_eq!(scope.observe(&[]), [], "a bang-started process stays idle");
        assert!(scope.current().is_empty());
    }

    /// One canned 200 on loopback: the URL to fetch, and the request it
    /// received, headers included.
    fn serve_once(body: String) -> (String, std::thread::JoinHandle<String>) {
        use std::io::{Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}/api/oauth/usage", listener.local_addr().unwrap());
        let handle = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = Vec::new();
            let mut buffer = [0_u8; 4096];
            while !request.windows(4).any(|window| window == b"\r\n\r\n") {
                let read = stream.read(&mut buffer).unwrap();
                if read == 0 {
                    break;
                }
                request.extend_from_slice(&buffer[..read]);
            }
            let reply = format!(
                "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
                body.len()
            );
            stream.write_all(reply.as_bytes()).unwrap();
            String::from_utf8_lossy(&request).into_owned()
        });
        (url, handle)
    }

    fn claude_credentials(expires_at: u64) -> String {
        json!({"claudeAiOauth": {
            "accessToken": "access-value",
            "refreshToken": "refresh-value",
            "expiresAt": expires_at * 1_000,
        }})
        .to_string()
    }

    /// Claude's usage drives the `claude` segment through Claude Code's
    /// stored access token; the state file is private and holds percentages
    /// and times only; an expired token is never sent and keeps the reading.
    #[tokio::test]
    async fn claude_refresh_publishes_persists_privately_and_keeps_the_last_reading() {
        let mut harness = Harness::new("aiproviders");
        let ctx = harness.context();
        let data_dir = harness.data_dir();
        tokio::fs::create_dir_all(&data_dir).await.unwrap();
        let credentials_file = data_dir.join("credentials.json");
        tokio::fs::write(&credentials_file, claude_credentials(unix_now() + 3_600))
            .await
            .unwrap();
        let reset = unix_now() + 22 * 3_600 + 1_800;
        let (url, request) =
            serve_once(json!({"seven_day": {"utilization": 94.0, "resets_at": reset}}).to_string());
        let state_file = data_dir.join(STATE_FILE);
        tokio::fs::write(&state_file, "{}").await.unwrap();
        tokio::fs::set_permissions(&state_file, std::fs::Permissions::from_mode(0o644))
            .await
            .unwrap();
        let auth_file = data_dir.join("auth.json");
        tokio::fs::write(
            &auth_file,
            json!({"x": {"key": "token-value", "expires_at": "2001-01-01T00:00:00Z", "refresh_token": "refresh-value"}}).to_string(),
        )
        .await
        .unwrap();
        let sources = Sources {
            claude: quota::ClaudeCredentials {
                keychain_service: None,
                file: Some(credentials_file.clone()),
            },
            claude_usage_url: url,
            grok_auth_file: Some(auth_file),
        };
        let shared = SharedQuotas::default();

        refresh_quotas(&ctx, &shared, &sources, &[Quota::Claude, Quota::Grok]).await;
        let request = request.join().unwrap().to_ascii_lowercase();
        assert!(request.starts_with("get /api/oauth/usage "), "{request}");
        assert!(request.contains("\r\nauthorization: bearer access-value\r\n"));
        assert!(request.contains("\r\nanthropic-beta: oauth-2025-04-20\r\n"));
        assert!(!request.contains("refresh-value"));
        let published = harness.drain_status();
        assert_eq!(published.len(), 1);
        assert_eq!(published[0]["claude"], "6%↻22h");
        assert_eq!(published[0]["codex"], "—");
        assert_eq!(
            published[0]["grok"], "—",
            "an expired token never produced a reading"
        );

        let mode = tokio::fs::metadata(&state_file)
            .await
            .unwrap()
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(mode, 0o600, "quota state is mode 0600");
        let stored = tokio::fs::read_to_string(&state_file).await.unwrap();
        assert!(stored.contains("\"used_percent\":94.0"));
        assert!(
            !stored.contains("token-value")
                && !stored.contains("access-value")
                && !stored.contains("refresh-value")
        );
        assert!(
            !stored.contains("\"codex\""),
            "an unshown quota is untouched"
        );

        // Due again, but the token has expired: nothing is sent (the test
        // server is gone, so a request would fail and wait to retry), and
        // the reading stays.
        tokio::fs::write(&credentials_file, claude_credentials(unix_now() - 60))
            .await
            .unwrap();
        {
            let mut runtime = shared.lock().await;
            let mut entry = runtime.state.entry(Quota::Claude);
            entry.fetched_at = Some(0);
            runtime.state.set(Quota::Claude, entry);
        }
        refresh_quotas(&ctx, &shared, &sources, &[Quota::Claude]).await;
        assert!(
            harness.drain_status().is_empty(),
            "an expired token keeps the published reading"
        );
        let kept = shared.lock().await.state.entry(Quota::Claude);
        assert_eq!(kept.used_percent, Some(94.0));
        assert_eq!(kept.retry_at, None, "an expired token is not a failure");

        let restarted = SharedQuotas::default();
        publish_stored(&ctx, &restarted).await;
        assert_eq!(
            harness.drain_status()[0]["claude"],
            "6%↻22h",
            "a restart republishes the persisted reading"
        );
    }

    #[tokio::test]
    async fn start_publishes_stored_metrics_without_fetching() {
        let mut harness = Harness::new("aiproviders");
        let ctx = harness.context();
        AiProviders::default().on_start(ctx).await;
        let frames = harness.drain();
        let status: Vec<&Value> = frames
            .iter()
            .filter(|frame| frame["method"] == "status")
            .collect();
        assert_eq!(status.len(), 1);
        assert_eq!(
            status[0]["params"]["segments"],
            json!({ "claude": "—", "codex": "—", "grok": "—" })
        );
        assert!(
            frames.iter().any(|frame| frame["method"] == "poll"
                && frame["params"]["registrations"]["i0"]["every"] == 60.0),
            "{frames:?}"
        );
        assert!(
            !tokio::fs::try_exists(harness.data_dir().join(STATE_FILE))
                .await
                .unwrap(),
            "no refresh ran at start"
        );
    }
}
