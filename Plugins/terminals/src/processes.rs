//! Processes: `ps` records and the in-process parent tree that tells which
//! terminal hosts which tmux client.

use std::collections::HashMap;
use std::time::Duration;

use crate::clients::TmuxClient;
use crate::invocation::run_cmd;

const PS_PATH: &str = "/bin/ps";

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct ProcessRecord {
    pub(crate) pid: i64,
    pub(crate) ppid: i64,
    pub(crate) tty: String,
    pub(crate) command: String,
}

pub(crate) async fn process_records() -> Vec<ProcessRecord> {
    let Some(raw) = run_cmd(
        PS_PATH,
        &["-axo", "pid=,ppid=,tty=,comm="],
        Duration::from_millis(1500),
    )
    .await
    else {
        return Vec::new();
    };
    raw.lines()
        .filter_map(|line| {
            let mut fields = line.split_whitespace();
            Some(ProcessRecord {
                pid: fields.next()?.parse().ok()?,
                ppid: fields.next()?.parse().ok()?,
                tty: fields.next()?.to_string(),
                command: fields.next()?.to_string(),
            })
        })
        .collect()
}

pub(crate) async fn process_command(pid: i64) -> Option<String> {
    run_cmd(
        PS_PATH,
        &["-ww", "-p", &pid.to_string(), "-o", "command="],
        Duration::from_millis(1500),
    )
    .await
    .map(|command| command.trim().to_string())
    .filter(|command| !command.is_empty())
}

/// Every process's parent, read in-process: a `ps` would cost an exec on the
/// path that resolves which tmux client the focused terminal hosts.
pub(crate) fn parent_pid_map() -> HashMap<i64, i64> {
    flash_plugin::sys::process_parents()
        .map(|parents| {
            parents
                .into_iter()
                .map(|(pid, ppid)| (i64::from(pid), i64::from(ppid)))
                .collect()
        })
        .unwrap_or_default()
}

/// Walk up from `pid` until the next parent is launchd (pid 1); return the
/// highest-level pid before launchd — typically the terminal app hosting the
/// tmux client.
pub(crate) fn find_top_level_ancestor(pid: i64, parent_map: &HashMap<i64, i64>) -> Option<i64> {
    let mut cur = pid;
    for _ in 0..64 {
        if cur <= 1 {
            return None;
        }
        let nxt = *parent_map.get(&cur)?;
        if nxt == cur {
            return None;
        }
        if nxt <= 1 {
            return Some(cur);
        }
        cur = nxt;
    }
    None
}

pub(crate) fn is_ancestor(
    ancestor_pid: i64,
    descendant_pid: i64,
    parent_map: &HashMap<i64, i64>,
) -> bool {
    let mut cur = descendant_pid;
    for _ in 0..64 {
        if cur <= 1 {
            return false;
        }
        if cur == ancestor_pid {
            return true;
        }
        match parent_map.get(&cur) {
            Some(&nxt) if nxt != cur => cur = nxt,
            _ => return false,
        }
    }
    false
}

pub(crate) fn client_hosted_by_from_map(
    clients: &[TmuxClient],
    focused_pid: i64,
    parent_map: &HashMap<i64, i64>,
) -> Option<TmuxClient> {
    let process_sample_can_evaluate_clients = clients
        .iter()
        .any(|c| parent_map.contains_key(&c.client_pid));
    let mut matches: Vec<TmuxClient> = clients
        .iter()
        .filter(|c| is_ancestor(focused_pid, c.client_pid, parent_map))
        .cloned()
        .collect();
    if matches.is_empty() {
        if process_sample_can_evaluate_clients {
            return None;
        }
        let mut fallback = clients.to_vec();
        fallback.sort_by_key(|c| std::cmp::Reverse(c.activity));
        return fallback.into_iter().next();
    }
    matches.sort_by_key(|c| std::cmp::Reverse(c.activity));
    matches.into_iter().next()
}

#[cfg(test)]
mod tests {
    use super::*;

    use crate::test_support::client;

    #[test]
    fn hosted_client_matches_focused_terminal_ancestor() {
        let clients = vec![
            client("/dev/ttys001", "other", 2000, 20),
            client("/dev/ttys000", "scratch", 1443, 10),
        ];
        let parent_map = HashMap::from([(1443, 1356), (1356, 1), (2000, 1999), (1999, 1)]);

        let picked = client_hosted_by_from_map(&clients, 1356, &parent_map).unwrap();

        assert_eq!(picked.session, "scratch");
        assert_eq!(picked.tty, "/dev/ttys000");
    }

    #[test]
    fn hosted_client_falls_back_to_active_when_parent_map_is_unavailable() {
        let clients = vec![
            client("/dev/ttys000", "scratch", 1443, 10),
            client("/dev/ttys001", "work", 2000, 30),
        ];
        let parent_map = HashMap::new();

        let picked = client_hosted_by_from_map(&clients, 1356, &parent_map).unwrap();

        assert_eq!(picked.session, "work");
    }

    #[test]
    fn hosted_client_does_not_fallback_when_process_sample_knows_clients() {
        let clients = vec![client("/dev/ttys000", "scratch", 1443, 10)];
        let parent_map = HashMap::from([(1443, 2222), (2222, 1)]);

        let picked = client_hosted_by_from_map(&clients, 1356, &parent_map);

        assert!(picked.is_none());
    }
}
