//! A nonblocking event mailbox. Ordinary events retain wire order. When the
//! finite backlog fills, replacement notifications retain their newest value
//! in one slot per known event kind, so an authoritative final snapshot wins.

use crate::runtime::InboundEvent;
use std::collections::{BTreeMap, VecDeque};
use std::sync::Mutex;
use tokio::sync::Notify;

pub(crate) const EVENT_QUEUE_CAPACITY: usize = 256;
pub(crate) const EVENT_QUEUE_BYTES: usize = 16 * 1024 * 1024;

fn replacement(name: &str) -> bool {
    matches!(
        name,
        "core:apps.changed"
            | "core:focus.changed"
            | "core:window.focus.changed"
            | "core:ax.changed"
            | "core:clipboard.changed"
            | "core:config.changed"
            | "core:power.changed"
            | "core:space.changed"
    )
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
        let entry = Entry {
            sequence: backlog.sequence,
            bytes,
            event,
        };
        let name = &entry.event.event.name;
        if backlog.latest.contains_key(name) {
            backlog.latest.insert(name.clone(), entry);
        } else if backlog.queue.len() < EVENT_QUEUE_CAPACITY
            && bytes <= EVENT_QUEUE_BYTES.saturating_sub(backlog.bytes)
        {
            backlog.bytes += bytes;
            backlog.queue.push_back(entry);
        } else if replacement(name) {
            // There are exactly eight replacement kinds, each bounded by the
            // inbound frame cap. They cannot grow with arbitrary event names.
            backlog.latest.insert(name.clone(), entry);
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
        if let Some((key, sequence)) = latest {
            if backlog
                .queue
                .front()
                .is_none_or(|entry| sequence < entry.sequence)
            {
                return backlog.latest.remove(&key).map(|entry| entry.event);
            }
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
