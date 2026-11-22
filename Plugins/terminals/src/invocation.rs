//! Finding the tmux binary and running it: bounded subprocesses, argv
//! construction and the observer-first command path.

use std::time::{Duration, Instant};

use flash_plugin::process as bounded_process;

use crate::control_mode;
use crate::sockets::TmuxSocketRegistry;

const SUBPROCESS_STDOUT_LIMIT: usize = 8 * 1024 * 1024;
const SUBPROCESS_STDERR_LIMIT: usize = 64 * 1024;

const TMUX_PREFIXES: [&str; 4] = ["/opt/homebrew", "/usr/local", "/opt/local", "/usr"];
pub(crate) const ENV_PATH: &str = "/usr/bin/env";

pub(crate) async fn find_tmux() -> Option<String> {
    for prefix in TMUX_PREFIXES {
        let path = format!("{prefix}/bin/tmux");
        if is_file(&path).await {
            return resolve_tmux_executable(path).await;
        }
    }
    if let Some(path) = which("tmux").await {
        return resolve_tmux_executable(path).await;
    }
    // Version managers install outside the standard prefixes, and a GUI app's
    // PATH doesn't include their shims, so the scan above misses tmux entirely
    // (mise — the primary installer on this host — puts it under
    // ~/.local/share/mise/installs/…). Resolve through mise when it's present,
    // then fall back to the user's login+interactive shell, which sources their
    // full profile (mise/asdf activation, custom PATH exports).
    if let Some(path) = find_tmux_via_mise().await {
        return Some(path);
    }
    find_tmux_via_login_shell().await
}

async fn resolve_tmux_executable(path: String) -> Option<String> {
    let executable = tokio::fs::canonicalize(&path).await.ok()?;
    if executable.file_name().is_none_or(|name| name != "mise") {
        return Some(path);
    }
    // A GUI login PATH may contain mise shims. Starting mise for every tmux
    // query consumes the entire hint deadline; resolve once before caching.
    let output = run_cmd(
        executable.to_str()?,
        &["which", "tmux"],
        Duration::from_secs(5),
    )
    .await?;
    let resolved = output.trim();
    if !std::path::Path::new(resolved).is_absolute() || !is_file(resolved).await {
        return None;
    }
    let resolved_executable = tokio::fs::canonicalize(resolved).await.ok()?;
    (resolved_executable != executable).then(|| resolved.to_string())
}

async fn is_file(path: &str) -> bool {
    tokio::fs::metadata(path)
        .await
        .map(|m| m.is_file())
        .unwrap_or(false)
}

/// `mise which tmux` → the active tmux binary. `mise` itself installs into a
/// standard prefix (Homebrew), so it's reachable even when the tools it manages
/// are not — and it reads the user's global config, so the answer doesn't depend
/// on the plugin's cwd or PATH.
async fn find_tmux_via_mise() -> Option<String> {
    let mut mise = None;
    for prefix in TMUX_PREFIXES {
        let path = format!("{prefix}/bin/mise");
        if is_file(&path).await {
            mise = Some(path);
            break;
        }
    }
    let mise = match mise {
        Some(path) => path,
        None => which("mise").await?,
    };
    let out = run_cmd(&mise, &["which", "tmux"], Duration::from_secs(5)).await?;
    let path = out.lines().map(str::trim).find(|l| l.starts_with('/'))?;
    resolve_tmux_executable(path.to_string()).await
}

/// Last resort: the user's login+interactive shell sources their full profile
/// (mise/asdf activation, custom PATH), so `command -v tmux` there resolves
/// binaries a GUI app's bare PATH can't. `-i` is required because tool managers
/// commonly activate from interactive rc files such as `~/.zshrc`.
async fn find_tmux_via_login_shell() -> Option<String> {
    let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".to_string());
    let out = run_cmd(&shell, &["-lic", "command -v tmux"], Duration::from_secs(6)).await?;
    let path = out.lines().map(str::trim).find(|l| l.starts_with('/'))?;
    resolve_tmux_executable(path.to_string()).await
}

async fn which(program: &str) -> Option<String> {
    let path = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path) {
        let candidate = dir.join(program);
        if let Ok(meta) = tokio::fs::metadata(&candidate).await
            && meta.is_file()
        {
            return Some(candidate.to_string_lossy().into_owned());
        }
    }
    None
}

pub(crate) async fn run_cmd(program: &str, args: &[&str], timeout: Duration) -> Option<String> {
    let mut argv = Vec::with_capacity(args.len() + 1);
    argv.push(program.to_string());
    argv.extend(args.iter().map(|s| s.to_string()));
    let result = run_local(&argv, timeout).await;
    if !result.ok {
        return None;
    }
    Some(result.stdout)
}

#[derive(Clone, Debug, Default)]
pub(crate) struct CliResult {
    pub(crate) ok: bool,
    pub(crate) stdout: String,
    pub(crate) stderr: String,
    pub(crate) status: i32,
}

pub(crate) async fn run_local(argv: &[String], timeout: Duration) -> CliResult {
    let Some((program, args)) = argv.split_first() else {
        return CliResult {
            ok: false,
            stderr: "empty argv".to_string(),
            status: -1,
            ..Default::default()
        };
    };
    let mut command = tokio::process::Command::new(program);
    command.args(args);
    let started_at = Instant::now();
    match bounded_process::capture(
        &mut command,
        None,
        timeout,
        SUBPROCESS_STDOUT_LIMIT,
        SUBPROCESS_STDERR_LIMIT,
    )
    .await
    {
        Ok(output) => {
            if started_at.elapsed() >= Duration::from_secs(1) {
                eprintln!(
                    "[tmux] subprocess slow elapsed_ms={} status={}",
                    started_at.elapsed().as_millis(),
                    output
                        .status
                        .code()
                        .map(|code| code.to_string())
                        .unwrap_or_else(|| "signal".to_string())
                );
            }
            CliResult {
                ok: output.status.success(),
                stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
                stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
                status: output.status.code().unwrap_or(-1),
            }
        }
        Err(error) => {
            eprintln!(
                "[tmux] subprocess capture failed elapsed_ms={} status={} detail={}",
                started_at.elapsed().as_millis(),
                error.status(),
                error.diagnostic()
            );
            CliResult {
                ok: false,
                stderr: error.diagnostic(),
                status: error.status(),
                ..Default::default()
            }
        }
    }
}

pub(crate) fn tmux_argv(tmux_path: &str, args: &[&str]) -> Vec<String> {
    let mut argv = Vec::with_capacity(args.len() + 10);
    argv.push(ENV_PATH.to_string());
    argv.extend([
        "-u".to_string(),
        "TMUX".to_string(),
        "-u".to_string(),
        "TMUX_PANE".to_string(),
        "-u".to_string(),
        "TMUX_TMPDIR".to_string(),
        "-u".to_string(),
        "TMPDIR".to_string(),
    ]);
    argv.push(tmux_path.to_string());
    argv.extend(args.iter().map(|s| s.to_string()));
    argv
}

pub(crate) fn tmux_socket_argv(tmux_path: &str, socket_path: &str, args: &[&str]) -> Vec<String> {
    let mut argv = tmux_argv(tmux_path, &["-S", socket_path]);
    argv.extend(args.iter().map(|s| s.to_string()));
    argv
}

fn tmux_command_needs_nonempty_output(args: &[&str]) -> bool {
    matches!(args.first().copied(), Some("list-clients" | "list-windows"))
}

async fn run_tmux_local(
    tmux_path: &str,
    args: &[&str],
    timeout: Duration,
    socket_registry: &TmuxSocketRegistry,
) -> Result<CliResult, CliResult> {
    let needs_nonempty = tmux_command_needs_nonempty_output(args);
    let mut result = run_local(&tmux_argv(tmux_path, args), timeout).await;
    if result.ok && (!needs_nonempty || !result.stdout.trim().is_empty()) {
        return Ok(result);
    }
    // User-triggered work bypasses the inventory's fan-out and retry delay: a
    // named server that just recovered must be reachable immediately. The
    // registry still suppresses sockets already confirmed absent.
    for socket in socket_registry.action_targets(tmux_path).await {
        result = run_local(&tmux_socket_argv(tmux_path, &socket.path, args), timeout).await;
        if result.ok && (!needs_nonempty || !result.stdout.trim().is_empty()) {
            return Ok(result);
        }
    }
    Err(result)
}

/// Run tmux capturing stderr too, so callers can surface why a command
/// failed instead of just seeing `None`. Used by the mutating tab actions
/// (`new-window`, `kill-window`) where a silent failure is the worst
/// outcome — we'd rather log "session 1: no current path" than fall back
/// to a ⌘N that opens a fresh terminal window.
pub(crate) async fn run_tmux_capture(
    tmux_path: Option<&str>,
    args: &[&str],
    timeout: Duration,
    socket_registry: &TmuxSocketRegistry,
) -> Result<String, String> {
    let path = tmux_path.ok_or_else(|| "tmux binary not found".to_string())?;
    match run_tmux_local(path, args, timeout, socket_registry).await {
        Ok(result) => Ok(result.stdout),
        Err(result) => Err(tmux_failure_detail(&result)),
    }
}

pub(crate) fn tmux_failure_detail(result: &CliResult) -> String {
    let stderr = result.stderr.trim();
    if stderr.is_empty() {
        format!("tmux exited status={}", result.status)
    } else {
        stderr.to_string()
    }
}

/// Run `args` on the server at `socket` through its control-mode observer:
/// no process to spawn, so no exec to wait on. `None` when no observer can
/// take it and a spawned client must.
pub(crate) async fn run_on_observer(
    observers: &control_mode::ControlObservers,
    socket: &str,
    args: &[&str],
    timeout: Duration,
) -> Option<CliResult> {
    if socket.is_empty() {
        return None;
    }
    let reply = observers.run(socket, args, timeout).await?;
    Some(CliResult {
        ok: reply.ok,
        stdout: reply.stdout,
        stderr: reply.stderr,
        status: i32::from(!reply.ok),
    })
}

async fn run_tmux(
    tmux_path: Option<&str>,
    args: &[&str],
    timeout: Duration,
    socket_registry: &TmuxSocketRegistry,
) -> Option<String> {
    let path = tmux_path?;
    run_tmux_local(path, args, timeout, socket_registry)
        .await
        .ok()
        .map(|result| result.stdout)
}

pub(crate) async fn run_tmux_default(
    tmux_path: Option<&str>,
    args: &[&str],
    socket_registry: &TmuxSocketRegistry,
) -> Option<String> {
    run_tmux(tmux_path, args, Duration::from_secs(2), socket_registry).await
}

#[cfg(test)]
mod tests {
    use super::*;

    use crate::remote::shell_quote;
    use crate::test_support::ExecutableFixture;

    #[tokio::test]
    async fn tmux_executable_resolves_mise_shims_once() {
        let fixture = ExecutableFixture::new().await;
        let binary = fixture.script("real-tmux", "exit 0").await;
        let mise = fixture
            .script(
                "mise",
                &format!(
                    "test \"$1\" = which && test \"$2\" = tmux || exit 1\nprintf '%s\\n' {}",
                    shell_quote(&binary)
                ),
            )
            .await;
        let shim = fixture.0.join("tmux");
        tokio::fs::symlink(&mise, &shim).await.unwrap();
        assert_eq!(
            resolve_tmux_executable(shim.to_string_lossy().into_owned()).await,
            Some(binary.clone())
        );
        assert_eq!(resolve_tmux_executable(binary.clone()).await, Some(binary));
        fixture.script("mise", "exit 1").await;
        assert!(
            resolve_tmux_executable(shim.to_string_lossy().into_owned())
                .await
                .is_none()
        );
        fixture.cleanup().await;
    }

    #[test]
    fn tmux_argv_clears_inherited_tmux_environment() {
        let argv = tmux_argv("/opt/homebrew/bin/tmux", &["list-clients"]);

        assert_eq!(argv[0], ENV_PATH);
        assert_eq!(argv[1], "-u");
        assert_eq!(argv[2], "TMUX");
        assert_eq!(argv[3], "-u");
        assert_eq!(argv[4], "TMUX_PANE");
        assert_eq!(argv[5], "-u");
        assert_eq!(argv[6], "TMUX_TMPDIR");
        assert_eq!(argv[7], "-u");
        assert_eq!(argv[8], "TMPDIR");
        assert_eq!(argv[9], "/opt/homebrew/bin/tmux");
        assert_eq!(argv[10], "list-clients");
    }
}
