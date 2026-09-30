//! A nonblocking event mailbox. Ordinary events retain wire order. When the
//! finite backlog fills, replacement notifications retain their newest value
//! in one slot per coalescing key, so an authoritative final snapshot wins.

use crate::runtime::InboundEvent;
use crate::types::host_events;
use std::collections::{BTreeMap, VecDeque};
use std::sync::Mutex;
use tokio::sync::Notify;

pub(crate) const EVENT_QUEUE_CAPACITY: usize = 256;
pub(crate) const EVENT_QUEUE_BYTES: usize = 16 * 1024 * 1024;
/// Distinct coalescing keys the overflow slots hold at once
/// (`transport_limits.plugin_replacement_slots`).
pub(crate) const REPLACEMENT_SLOTS: usize = 256;

/// State signals whose latest value supersedes every earlier one
/// (`protocol.json` `host_events.replacement`).
pub(crate) const REPLACEMENT_EVENTS: [&str; 11] = [
    host_events::APPS_CHANGED,
    host_events::FOCUS_CHANGED,
    host_events::WINDOW_FOCUS_CHANGED,
    host_events::AX_CHANGED,
    host_events::CLIPBOARD_CHANGED,
    host_events::CONFIG_CHANGED,
    host_events::POWER_CHANGED,
    host_events::NETWORK_CHANGED,
    host_events::VOLUMES_CHANGED,
    host_events::SPACE_CHANGED,
    host_events::STATUS_OBSERVED,
];

/// The slot a replacement event supersedes (`protocol.json`
/// `host_events`): its name, plus the app and notification for
/// `core:ax.changed`, which reports one fact per pair. `None` for every other
/// event, which never coalesces.
fn coalescing_key(event: &crate::types::Event) -> Option<String> {
    if !REPLACEMENT_EVENTS.contains(&event.name.as_str()) {
        return None;
    }
    if event.name != host_events::AX_CHANGED {
        return Some(event.name.clone());
    }
    Some(format!(
        "{}\0{}\0{}",
        event.name,
        event.pid.unwrap_or_default(),
        event.notification.as_deref().unwrap_or_default()
    ))
}

struct Entry {
    sequence: u64,
    bytes: usize,
    event: InboundEvent,
}

#[derive(Default)]
struct Backlog {
    queue: VecDeque<Entry>,
    latest: BTreeMap<String, Entry>,
    bytes: usize,
    sequence: u64,
}

#[derive(Default)]
pub(crate) struct EventMailbox {
    backlog: Mutex<Backlog>,
    ready: Notify,
}

impl EventMailbox {
    pub(crate) fn push(&self, event: InboundEvent, bytes: usize) -> bool {
        let mut backlog = self.backlog.lock().expect("event mailbox");
        backlog.sequence += 1;
        let key = coalescing_key(&event.event);
        let entry = Entry {
            sequence: backlog.sequence,
            bytes,
            event,
        };
        if let Some(key) = key.as_ref().filter(|key| backlog.latest.contains_key(*key)) {
            backlog.latest.insert(key.clone(), entry);
        } else if backlog.queue.len() < EVENT_QUEUE_CAPACITY
            && bytes <= EVENT_QUEUE_BYTES.saturating_sub(backlog.bytes)
        {
            backlog.bytes += bytes;
            backlog.queue.push_back(entry);
        } else if let Some(key) = key.filter(|_| backlog.latest.len() < REPLACEMENT_SLOTS) {
            // Each slot is bounded by the inbound frame cap and the slots by
            // count, so arbitrary keys cannot grow the backlog.
            backlog.latest.insert(key, entry);
        } else {
            return false;
        }
        drop(backlog);
        self.ready.notify_one();
        true
    }

    fn pop(&self) -> Option<InboundEvent> {
        let mut backlog = self.backlog.lock().expect("event mailbox");
        let latest = backlog
            .latest
            .iter()
            .min_by_key(|(_, value)| value.sequence)
            .map(|(key, value)| (key.clone(), value.sequence));
        if let Some((key, sequence)) = latest
            && backlog
                .queue
                .front()
                .is_none_or(|entry| sequence < entry.sequence)
        {
            return backlog.latest.remove(&key).map(|entry| entry.event);
        }
        let entry = backlog.queue.pop_front()?;
        backlog.bytes -= entry.bytes;
        Some(entry.event)
    }

    pub(crate) async fn next(&self) -> InboundEvent {
        loop {
            let ready = self.ready.notified();
            if let Some(event) = self.pop() {
                return event;
            }
            ready.await;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::Event;

    fn event(name: &str, marker: &str) -> InboundEvent {
        InboundEvent {
            event: Event {
                name: name.into(),
                text: Some(marker.into()),
                ..Event::default()
            },
            running_applications: Vec::new(),
        }
    }

    #[test]
    fn host_events_match_the_shared_protocol_contract() {
        let contract: serde_json::Value =
            serde_json::from_str(include_str!("../protocol.json")).unwrap();
        let list = |key: &str| -> Vec<String> {
            contract["host_events"][key]
                .as_array()
                .unwrap()
                .iter()
                .map(|name| name.as_str().unwrap().to_string())
                .collect()
        };
        assert_eq!(list("names"), host_events::ALL.map(String::from).to_vec());
        assert_eq!(
            list("replacement"),
            REPLACEMENT_EVENTS.map(String::from).to_vec()
        );
        assert_eq!(
            list("ax_notifications"),
            crate::types::ax_notifications::ALL
                .map(String::from)
                .to_vec()
        );
    }

    /// A burst of payload-free change signals under overload collapses to one
    /// delivery, which is all a plugin that re-reads its state needs.
    #[test]
    fn network_and_volume_signals_coalesce_under_overload() {
        let mailbox = EventMailbox::default();
        for _ in 0..EVENT_QUEUE_CAPACITY {
            assert!(mailbox.push(event("edge", "old"), 1));
        }
        for name in [host_events::NETWORK_CHANGED, host_events::VOLUMES_CHANGED] {
            for _ in 0..100 {
                assert!(mailbox.push(event(name, "signal"), 1));
            }
        }
        for _ in 0..EVENT_QUEUE_CAPACITY {
            assert_eq!(mailbox.pop().unwrap().event.name, "edge");
        }
        let mut coalesced = vec![
            mailbox.pop().unwrap().event.name,
            mailbox.pop().unwrap().event.name,
        ];
        coalesced.sort();
        assert_eq!(
            coalesced,
            [host_events::NETWORK_CHANGED, host_events::VOLUMES_CHANGED]
        );
        assert!(mailbox.pop().is_none());
    }

    fn ax(pid: i64, notification: &str, marker: &str) -> InboundEvent {
        InboundEvent {
            event: Event {
                name: host_events::AX_CHANGED.into(),
                pid: Some(pid),
                notification: Some(notification.into()),
                text: Some(marker.into()),
                ..Event::default()
            },
            running_applications: Vec::new(),
        }
    }

    /// An AX change reports one fact per app and notification: under
    /// overload a keystroke's value changes coalesce among themselves and
    /// never supersede a pending title change, nor one app another's.
    #[test]
    fn ax_changes_coalesce_per_app_and_notification() {
        let mailbox = EventMailbox::default();
        for _ in 0..EVENT_QUEUE_CAPACITY {
            assert!(mailbox.push(event("edge", "old"), 1));
        }
        assert!(mailbox.push(ax(7, "AXTitleChanged", "title-7"), 1));
        for index in 0..100 {
            assert!(mailbox.push(ax(7, "AXValueChanged", &format!("value-{index}")), 1));
        }
        assert!(mailbox.push(ax(8, "AXTitleChanged", "title-8"), 1));
        for _ in 0..EVENT_QUEUE_CAPACITY {
            assert_eq!(mailbox.pop().unwrap().event.name, "edge");
        }
        let delivered: Vec<String> = std::iter::from_fn(|| mailbox.pop())
            .map(|inbound| inbound.event.text.unwrap())
            .collect();
        assert_eq!(delivered, ["title-7", "value-99", "title-8"]);
    }

    /// Replacement slots are finite: once every slot holds a distinct key,
    /// a new key is dropped like an ordinary overflowing event.
    #[test]
    fn replacement_slots_are_bounded() {
        let mailbox = EventMailbox::default();
        for _ in 0..EVENT_QUEUE_CAPACITY {
            assert!(mailbox.push(event("edge", "old"), 1));
        }
        for pid in 1..=REPLACEMENT_SLOTS as i64 {
            assert!(mailbox.push(ax(pid, "AXTitleChanged", "slot"), 1));
        }
        assert!(!mailbox.push(ax(0x7fff, "AXTitleChanged", "extra"), 1));
        assert!(
            mailbox.push(ax(1, "AXTitleChanged", "latest"), 1),
            "a held key still takes its newest value"
        );
    }

    #[test]
    fn final_authoritative_empty_snapshot_survives_full_queue() {
        let mailbox = EventMailbox::default();
        for _ in 0..EVENT_QUEUE_CAPACITY {
            assert!(mailbox.push(event("edge", "old"), 1));
        }
        assert!(!mailbox.push(event("edge", "dropped"), 1));
        for _ in 0..1000 {
            assert!(mailbox.push(event("core:apps.changed", "superseded"), 1));
        }
        assert!(mailbox.push(event("core:apps.changed", "empty"), 1));
        for _ in 0..EVENT_QUEUE_CAPACITY {
            assert_eq!(mailbox.pop().unwrap().event.name, "edge");
        }
        assert_eq!(mailbox.pop().unwrap().event.text.as_deref(), Some("empty"));
        assert!(mailbox.pop().is_none());
    }

    /// The observed status-segment set is a full replacement: under overload
    /// the latest set must still arrive, or a plugin could keep sampling for
    /// a surface that is gone (or never start for one that appeared).
    #[test]
    fn final_status_observation_survives_full_queue() {
        let mailbox = EventMailbox::default();
        for _ in 0..EVENT_QUEUE_CAPACITY {
            assert!(mailbox.push(event("edge", "old"), 1));
        }
        assert!(mailbox.push(event("core:status.observed", "armed"), 1));
        assert!(mailbox.push(event("core:status.observed", "disarmed"), 1));
        for _ in 0..EVENT_QUEUE_CAPACITY {
            assert_eq!(mailbox.pop().unwrap().event.name, "edge");
        }
        assert_eq!(
            mailbox.pop().unwrap().event.text.as_deref(),
            Some("disarmed")
        );
        assert!(mailbox.pop().is_none());
    }

    #[test]
    fn backlog_is_bounded_by_bytes_as_well_as_frames() {
        let mailbox = EventMailbox::default();
        assert!(mailbox.push(event("edge", "full"), EVENT_QUEUE_BYTES));
        assert!(!mailbox.push(event("edge", "extra"), 1));
        assert!(mailbox.push(event("core:focus.changed", "latest"), 10));
        assert_eq!(mailbox.pop().unwrap().event.text.as_deref(), Some("full"));
        assert_eq!(mailbox.pop().unwrap().event.text.as_deref(), Some("latest"));
    }
}
