//! Remote tmux backends: SSH/Mosh transport discovery, the `ssh_hosts`
//! opt-in and tmux commands run over SSH.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::PathBuf;
use std::time::Duration;

use flash_plugin::Context;
use serde_json::Value;

use crate::invocation::{CliResult, ENV_PATH, run_local};
use crate::processes::{find_top_level_ancestor, process_command, process_records};
use crate::terminal_windows::{AxWindowNode, terminal_window_nodes, window_handle_for_title};

const SSH_PATH: &str = "/usr/bin/ssh";

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct RemoteTmuxConfig {
    pub(crate) id: String,
    pub(crate) label: String,
    pub(crate) host: String,
    tmux_path: String,
    pub(crate) terminal_window_title: String,
    pub(crate) terminal_window_handle: Option<u64>,
    pub(crate) terminal_pid: i64,
    pub(crate) transport_pid: i64,
    pub(crate) home: String,
    control_path: Option<PathBuf>,
    ssh_options: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct RemoteTransport {
    host: String,
    tmux_path: String,
    home: String,
    ssh_options: Vec<String>,
}

pub(crate) fn executable_name(command: &str) -> &str {
    command.rsplit('/').next().unwrap_or(command)
}

async fn remote_control_path() -> Option<PathBuf> {
    let uid = nix::unistd::geteuid().as_raw();
    let directory = PathBuf::from(format!("/tmp/flash-tmux-{uid}"));
    match tokio::fs::symlink_metadata(&directory).await {
        Ok(metadata) => {
            if !metadata.is_dir() || metadata.uid() != uid {
                return None;
            }
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            if tokio::fs::create_dir(&directory).await.is_err() {
                let metadata = tokio::fs::symlink_metadata(&directory).await.ok()?;
                if !metadata.is_dir() || metadata.uid() != uid {
                    return None;
                }
            }
        }
        Err(_) => return None,
    }
    tokio::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700))
        .await
        .ok()?;
    Some(directory.join("ssh-%C"))
}

fn split_command_line(raw: &str) -> Vec<String> {
    let mut words = Vec::new();
    let mut word = String::new();
    let mut quote = None;
    let mut escaped = false;
    for ch in raw.chars() {
        if escaped {
            word.push(ch);
            escaped = false;
            continue;
        }
        match quote {
            Some('"') if ch == '\\' => escaped = true,
            Some(active) if ch == active => quote = None,
            Some(_) => word.push(ch),
            None if ch == '\\' => escaped = true,
            None if ch == '\'' || ch == '"' => quote = Some(ch),
            None if ch.is_whitespace() => {
                if !word.is_empty() {
                    words.push(std::mem::take(&mut word));
                }
            }
            None => word.push(ch),
        }
    }
    if escaped {
        word.push('\\');
    }
    if !word.is_empty() {
        words.push(word);
    }
    words
}

fn ssh_option_takes_value(option: &str) -> bool {
    option.len() == 2
        && option
            .chars()
            .nth(1)
            .is_some_and(|flag| "BbcDEeFIiJLlmOopQRSWw".contains(flag))
}

fn ssh_destination_index(words: &[String]) -> Option<usize> {
    let mut index = 1;
    while index < words.len() {
        let word = &words[index];
        if word == "--" {
            return (index + 1 < words.len()).then_some(index + 1);
        }
        if !word.starts_with('-') || word == "-" {
            return Some(index);
        }
        index += if ssh_option_takes_value(word) { 2 } else { 1 };
    }
    None
}

fn retained_ssh_options(words: &[String]) -> Vec<String> {
    let mut retained = Vec::new();
    let mut index = 0;
    while index < words.len() {
        let option = &words[index];
        let takes_value = ssh_option_takes_value(option);
        let value = takes_value.then(|| words.get(index + 1)).flatten();
        let keep = matches!(
            option.as_str(),
            "-4" | "-6" | "-B" | "-b" | "-F" | "-I" | "-i" | "-J" | "-l" | "-p"
        ) || option == "-o"
            && value.is_some_and(|value| {
                let key = value
                    .split('=')
                    .next()
                    .unwrap_or(value)
                    .to_ascii_lowercase();
                !matches!(
                    key.as_str(),
                    "batchmode"
                        | "connectionattempts"
                        | "connecttimeout"
                        | "controlmaster"
                        | "controlpath"
                        | "controlpersist"
                        | "remotecommand"
                        | "requesttty"
                )
            });
        if keep {
            retained.push(option.clone());
            if let Some(value) = value {
                retained.push(value.clone());
            }
        }
        index += if takes_value { 2 } else { 1 };
    }
    retained
}

fn tmux_command_index(words: &[String], start: usize) -> Option<usize> {
    words
        .iter()
        .enumerate()
        .skip(start)
        .find(|(_, word)| executable_name(word) == "tmux")
        .map(|(index, _)| index)
}

fn inferred_remote_home(host: &str, tmux_words: &[String]) -> String {
    let user = host
        .split('@')
        .next()
        .filter(|_| host.contains('@'))
        .unwrap_or("");
    if user.is_empty() {
        return String::new();
    }
    for pair in tmux_words.windows(2) {
        if pair[0] != "-c" {
            continue;
        }
        for prefix in ["/home/", "/Users/"] {
            let expected = format!("{prefix}{user}");
            if pair[1] == expected || pair[1].starts_with(&format!("{expected}/")) {
                return expected;
            }
        }
    }
    String::new()
}

fn parse_ssh_transport(command: &str) -> Option<RemoteTransport> {
    let words = split_command_line(command);
    if executable_name(words.first()?) != "ssh" {
        return None;
    }
    let destination = ssh_destination_index(&words)?;
    let tmux_index = tmux_command_index(&words, destination + 1)?;
    let host = words[destination].clone();
    Some(RemoteTransport {
        home: inferred_remote_home(&host, &words[tmux_index + 1..]),
        tmux_path: words[tmux_index].clone(),
        ssh_options: retained_ssh_options(&words[1..destination]),
        host,
    })
}

fn parse_mosh_transport(command: &str) -> Option<RemoteTransport> {
    let marker = command.find(" -# ")? + 4;
    let end = command[marker..].rfind(" | ")? + marker;
    let words = split_command_line(&command[marker..end]);
    let separator = words.iter().rposition(|word| word == "--")?;
    if separator == 0 || separator + 1 >= words.len() {
        return None;
    }
    let host = words[separator - 1].clone();
    let tmux_index = tmux_command_index(&words, separator + 1)?;
    Some(RemoteTransport {
        home: inferred_remote_home(&host, &words[tmux_index + 1..]),
        tmux_path: words[tmux_index].clone(),
        ssh_options: Vec::new(),
        host,
    })
}

fn parse_remote_transport(command: &str, process_name: &str) -> Option<RemoteTransport> {
    match process_name {
        "ssh" => parse_ssh_transport(command),
        "mosh-client" => parse_mosh_transport(command),
        _ => None,
    }
}

pub(crate) fn remote_host_name(host: &str) -> &str {
    host.rsplit('@').next().unwrap_or(host)
}

const SSH_HOSTS_ERROR: &str =
    "ssh_hosts must be an array of host names without user@ or whitespace";

/// `[plugins.terminals] ssh_hosts`: the remote hosts whose tmux sessions the plugin
/// may inventory. Inventory opens the plugin's own noninteractive SSH
/// connections, which can ask an SSH agent or hardware key for approval and
/// land in the remote auth log, so remote discovery is opt-in per host: with
/// no entry the plugin never inspects SSH/Mosh processes and never runs `ssh`.
/// Entries name the destination as written on the ssh/mosh command line,
/// without its `user@` prefix, case-insensitively.
fn parse_ssh_hosts(value: Option<Value>) -> Result<BTreeSet<String>, &'static str> {
    let Some(value) = value else {
        return Ok(BTreeSet::new());
    };
    value
        .as_array()
        .ok_or(SSH_HOSTS_ERROR)?
        .iter()
        .map(|host| {
            host.as_str()
                .filter(|host| {
                    !host.is_empty() && !host.contains('@') && !host.contains(char::is_whitespace)
                })
                .map(str::to_ascii_lowercase)
                .ok_or(SSH_HOSTS_ERROR)
        })
        .collect()
}

pub(crate) fn configured_ssh_hosts(ctx: &Context) -> BTreeSet<String> {
    parse_ssh_hosts(ctx.config_json("ssh_hosts")).unwrap_or_else(|error| {
        ctx.log(
            "warn",
            &format!("[tmux] invalid configuration: {error}; remote discovery stays off"),
        );
        BTreeSet::new()
    })
}

fn ssh_host_allowed(ssh_hosts: &BTreeSet<String>, host: &str) -> bool {
    ssh_hosts.contains(&remote_host_name(host).to_ascii_lowercase())
}

fn remote_host_label(host: &str) -> String {
    remote_host_name(host)
        .trim_matches(['[', ']'])
        .split(['.', ':'])
        .next()
        .filter(|value| !value.is_empty())
        .unwrap_or("remote")
        .to_string()
}

pub(crate) fn terminal_title_for_host(nodes: &[AxWindowNode], host: &str) -> String {
    let full = remote_host_name(host).to_ascii_lowercase();
    let short = remote_host_label(host).to_ascii_lowercase();
    nodes
        .iter()
        .filter_map(|node| node.attrs.get("AXTitle"))
        .max_by_key(|title| {
            let lower = title.to_ascii_lowercase();
            if !full.is_empty() && lower.contains(&full) {
                3
            } else if !short.is_empty() && lower.contains(&short) {
                2
            } else {
                0
            }
        })
        .filter(|title| {
            let lower = title.to_ascii_lowercase();
            (!full.is_empty() && lower.contains(&full))
                || (!short.is_empty() && lower.contains(&short))
                || nodes.len() == 1
        })
        .cloned()
        .unwrap_or_default()
}

pub(crate) async fn discover_remote_tmux_configs(
    ctx: &Context,
    ssh_hosts: &BTreeSet<String>,
) -> BTreeMap<String, RemoteTmuxConfig> {
    // Opt-in: without configured hosts, no process scan and no SSH side channel.
    if ssh_hosts.is_empty() {
        return BTreeMap::new();
    }
    let control_path = remote_control_path().await;
    let records = process_records().await;
    let parent_map = records
        .iter()
        .map(|record| (record.pid, record.ppid))
        .collect::<HashMap<_, _>>();
    let application_pids = ctx
        .running_applications()
        .into_iter()
        .map(|application| application.pid)
        .collect::<BTreeSet<_>>();
    let mut windows_by_pid: HashMap<i64, Vec<AxWindowNode>> = HashMap::new();
    let mut discovered = BTreeMap::new();
    for record in records {
        let process_name = executable_name(&record.command);
        if !matches!(process_name, "ssh" | "mosh-client")
            || matches!(record.tty.as_str(), "?" | "??" | "-")
        {
            continue;
        }
        let Some(terminal_pid) = find_top_level_ancestor(record.pid, &parent_map)
            .filter(|pid| application_pids.contains(pid))
        else {
            continue;
        };
        let Some(command) = process_command(record.pid).await else {
            continue;
        };
        let Some(transport) = parse_remote_transport(&command, process_name)
            .filter(|transport| ssh_host_allowed(ssh_hosts, &transport.host))
        else {
            continue;
        };
        let nodes = if let Some(nodes) = windows_by_pid.get(&terminal_pid) {
            nodes.clone()
        } else {
            let nodes = terminal_window_nodes(ctx, terminal_pid).await;
            windows_by_pid.insert(terminal_pid, nodes.clone());
            nodes
        };
        let label = remote_host_label(&transport.host);
        let id = format!(
            "remote:{}",
            remote_host_name(&transport.host).to_ascii_lowercase()
        );
        let terminal_window_title = terminal_title_for_host(&nodes, &id["remote:".len()..]);
        let terminal_window_handle = window_handle_for_title(&nodes, &terminal_window_title);
        let config = RemoteTmuxConfig {
            id: id.clone(),
            label,
            host: transport.host,
            tmux_path: transport.tmux_path,
            terminal_window_title,
            terminal_window_handle,
            terminal_pid,
            transport_pid: record.pid,
            home: transport.home,
            control_path: control_path.clone(),
            ssh_options: transport.ssh_options,
        };
        discovered.insert(id, config);
    }
    discovered
}

pub(crate) fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

fn remote_tmux_command(config: &RemoteTmuxConfig, args: &[&str]) -> String {
    let mut words = vec![
        shell_quote(ENV_PATH),
        "-u".to_string(),
        "TMUX".to_string(),
        "-u".to_string(),
        "TMUX_PANE".to_string(),
        "-u".to_string(),
        "TMUX_TMPDIR".to_string(),
        "-u".to_string(),
        "TMPDIR".to_string(),
        shell_quote(&config.tmux_path),
    ];
    words.extend(args.iter().map(|arg| shell_quote(arg)));
    words.join(" ")
}

fn remote_ssh_argv(config: &RemoteTmuxConfig, command: &str) -> Vec<String> {
    let mut argv = vec![SSH_PATH.to_string(), "-T".to_string()];
    argv.extend(config.ssh_options.iter().cloned());
    argv.extend([
        "-o".to_string(),
        "BatchMode=yes".to_string(),
        "-o".to_string(),
        "ConnectTimeout=5".to_string(),
        "-o".to_string(),
        "ConnectionAttempts=1".to_string(),
        "-o".to_string(),
        "StrictHostKeyChecking=yes".to_string(),
    ]);
    if let Some(control_path) = config.control_path.as_ref() {
        argv.extend([
            "-o".to_string(),
            "ControlMaster=auto".to_string(),
            "-o".to_string(),
            "ControlPersist=60".to_string(),
            "-o".to_string(),
            format!("ControlPath={}", control_path.display()),
        ]);
    }
    argv.extend(["--".to_string(), config.host.clone(), command.to_string()]);
    argv
}

pub(crate) async fn run_remote_tmux(
    config: &RemoteTmuxConfig,
    args: &[&str],
    timeout: Duration,
) -> CliResult {
    let command = remote_tmux_command(config, args);
    run_local(&remote_ssh_argv(config, &command), timeout).await
}

pub(crate) async fn run_remote_tmux_default(
    config: &RemoteTmuxConfig,
    args: &[&str],
) -> Option<String> {
    let result = run_remote_tmux(config, args, Duration::from_secs(7)).await;
    result.ok.then_some(result.stdout)
}

#[cfg(test)]
mod tests {
    use super::*;

    use serde_json::json;

    #[test]
    fn remote_ssh_command_is_argument_safe_and_reuses_a_control_connection() {
        let config = RemoteTmuxConfig {
            id: "remote:moria".to_string(),
            label: "moria".to_string(),
            host: "ab@moria.zone".to_string(),
            tmux_path: "/opt/tmux with space".to_string(),
            terminal_window_title: "scratch@moria.zone".to_string(),
            terminal_window_handle: Some(22),
            terminal_pid: 1356,
            transport_pid: 1443,
            home: "/home/ab".to_string(),
            control_path: Some(PathBuf::from("/tmp/flash-tmux/ssh-%C")),
            ssh_options: vec!["-o".to_string(), "IdentitiesOnly=yes".to_string()],
        };
        let command = remote_tmux_command(&config, &["display-message", "it's safe"]);
        let argv = remote_ssh_argv(&config, &command);

        assert!(command.contains("'/opt/tmux with space'"));
        assert!(command.contains("'it'\\''s safe'"));
        assert!(argv.contains(&"ControlMaster=auto".to_string()));
        assert!(argv.contains(&"ControlPersist=60".to_string()));
        assert!(argv.contains(&"ControlPath=/tmp/flash-tmux/ssh-%C".to_string()));
        assert_eq!(argv[argv.len() - 2], "ab@moria.zone");
        assert_eq!(argv.last(), Some(&command));
    }

    #[test]
    fn ssh_process_command_discovers_host_tmux_and_reusable_connection_options() {
        let command = "ssh -tt -p 2222 -o BatchMode=yes -o IdentitiesOnly=yes \
-o StrictHostKeyChecking=yes ab@moria.zone \
/home/ab/.local/share/mise/shims/tmux new-session -A -s scratch -c /home/ab";

        let transport = parse_remote_transport(command, "ssh").unwrap();

        assert_eq!(transport.host, "ab@moria.zone");
        assert_eq!(transport.tmux_path, "/home/ab/.local/share/mise/shims/tmux");
        assert_eq!(transport.home, "/home/ab");
        assert!(transport.ssh_options.contains(&"-p".to_string()));
        assert!(transport.ssh_options.contains(&"2222".to_string()));
        assert!(
            transport
                .ssh_options
                .contains(&"IdentitiesOnly=yes".to_string())
        );
        assert!(!transport.ssh_options.contains(&"BatchMode=yes".to_string()));
    }

    #[test]
    fn mosh_client_marker_discovers_original_remote_tmux_command() {
        let command = "/opt/homebrew/bin/mosh-client -# --bind-server=ssh \
--port=61000:61009 --server=/usr/bin/env MOSH_SERVER_NETWORK_TMOUT=86400 \
/usr/bin/mosh-server --ssh=ssh -o BatchMode=yes -o ConnectTimeout=10 \
ab@moria.zone -- /home/ab/.local/share/mise/shims/tmux new-session -A \
-s scratch -c /home/ab | 82.65.243.222 61000";

        let transport = parse_remote_transport(command, "mosh-client").unwrap();

        assert_eq!(transport.host, "ab@moria.zone");
        assert_eq!(transport.tmux_path, "/home/ab/.local/share/mise/shims/tmux");
        assert_eq!(transport.home, "/home/ab");
    }

    #[test]
    fn ssh_hosts_default_to_none_and_reject_malformed_values() {
        assert_eq!(parse_ssh_hosts(None), Ok(BTreeSet::new()));
        assert_eq!(parse_ssh_hosts(Some(json!([]))), Ok(BTreeSet::new()));
        assert_eq!(
            parse_ssh_hosts(Some(json!(["Moria.Zone", "dev"]))),
            Ok(BTreeSet::from([
                "dev".to_string(),
                "moria.zone".to_string()
            ]))
        );
        for malformed in [
            json!("moria.zone"),
            json!(true),
            json!([""]),
            json!(["ab@moria.zone"]),
            json!(["moria zone"]),
            json!([1]),
        ] {
            assert_eq!(
                parse_ssh_hosts(Some(malformed)),
                Err(SSH_HOSTS_ERROR),
                "malformed ssh_hosts must disable remote discovery"
            );
        }
    }

    #[test]
    fn remote_transports_are_inventoried_only_for_configured_hosts() {
        let ssh =
            parse_remote_transport("ssh -tt ab@Moria.Zone tmux new-session -A", "ssh").unwrap();
        let mosh = parse_remote_transport(
            "mosh-client -# --ssh=ssh ab@moria.zone -- tmux attach | 10.0.0.1 61000",
            "mosh-client",
        )
        .unwrap();

        for transport in [&ssh, &mosh] {
            assert!(!ssh_host_allowed(&BTreeSet::new(), &transport.host));
            assert!(!ssh_host_allowed(
                &BTreeSet::from(["dev".to_string()]),
                &transport.host
            ));
            assert!(ssh_host_allowed(
                &parse_ssh_hosts(Some(json!(["moria.zone"]))).unwrap(),
                &transport.host
            ));
        }
    }

    #[tokio::test]
    async fn default_settings_open_no_remote_backend() {
        let harness = flash_plugin::testing::Harness::new("tmux");
        let ctx = harness.context();
        let ssh_hosts = configured_ssh_hosts(&ctx);

        assert!(ssh_hosts.is_empty());
        // Every remote ssh argv is built from a discovered backend; none exist.
        assert!(
            discover_remote_tmux_configs(&ctx, &ssh_hosts)
                .await
                .is_empty()
        );

        let harness = flash_plugin::testing::Harness::with_config(
            "tmux",
            json!({ "ssh_hosts": "moria.zone" }),
        );
        assert!(configured_ssh_hosts(&harness.context()).is_empty());
    }
}
