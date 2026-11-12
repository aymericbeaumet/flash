//! System information: CPU and GPU, memory, disks, network and power in one
//! resident plugin. Each domain keeps its own cadence, scoped to the
//! `core:status.observed` segments carrying its prefix (`cpu_`, `memory_`,
//! `disks_`, `network_`), and publishes `<domain>_<segment>` values; power
//! follows `core:power.changed`, disks `core:volumes.changed` and network
//! `core:network.changed`. The `network.addresses` catalog keeps the process
//! resident. All five read one `[plugins.sysinfo] summary_mode`.

mod common;
mod cpu;
mod disks;
mod memory;
mod network;
mod power;

use flash_plugin::{CommandRequest, Context, Event, PerformResponse, host_events, run};

use common::domain_segments;

#[derive(Default)]
struct Sysinfo {
    cpu: cpu::Cpu,
    memory: memory::Memory,
    disks: disks::Disks,
    network: network::Network,
    power: power::Power,
}

flash_plugin::plugin!(Sysinfo);

impl FlashPlugin for Sysinfo {
    async fn on_start(&self, ctx: Context) {
        common::warn_invalid_summary_mode(&ctx);
        tokio::join!(
            self.cpu.start(&ctx),
            self.memory.start(&ctx),
            self.disks.start(&ctx),
            self.network.start(&ctx),
            self.power.start(&ctx),
        );
    }

    async fn on_event(&self, ctx: Context, event: Event) {
        match event.name.as_str() {
            host_events::STATUS_OBSERVED => {
                let Some(segments) = event.segments.as_deref() else {
                    return;
                };
                self.cpu
                    .observe(&ctx, &domain_segments(segments, cpu::PREFIX));
                self.memory
                    .observe(&ctx, &domain_segments(segments, memory::PREFIX));
                self.disks
                    .observe(&ctx, &domain_segments(segments, disks::PREFIX));
                self.network
                    .observe(&ctx, &domain_segments(segments, network::PREFIX));
            }
            host_events::VOLUMES_CHANGED => self.disks.volumes_changed(&ctx),
            host_events::NETWORK_CHANGED => self.network.network_changed(&ctx),
            host_events::POWER_CHANGED => self.power.power_changed(&ctx).await,
            _ => {}
        }
    }

    async fn on_command(&self, ctx: Context, command: CommandRequest) -> PerformResponse {
        match command.subcommand.as_str() {
            "cpu" => self.cpu.show(&ctx).await,
            "memory" => self.memory.show(&ctx).await,
            "disks" => self.disks.show(&ctx).await,
            "network" => self.network.show(),
            "power" => self.power.show(),
            "refresh" => self.refresh(&ctx).await,
            other => PerformResponse::fail(format!("unknown subcommand: {other}")),
        }
    }
}

impl Sysinfo {
    /// Every domain at once, then one line of their visible summaries.
    async fn refresh(&self, ctx: &Context) -> PerformResponse {
        tokio::join!(
            self.cpu.refresh(ctx),
            self.memory.refresh(ctx),
            self.disks.refresh(ctx),
            self.network.refresh(ctx),
            self.power.refresh(ctx),
        );
        let summaries: Vec<String> = [
            self.cpu.summary(ctx),
            self.memory.summary(ctx),
            self.disks.summary(ctx),
            self.network.summary(ctx),
            self.power.summary(),
        ]
        .into_iter()
        .flatten()
        .map(|summary| summary.plain())
        .collect();
        if summaries.is_empty() {
            return PerformResponse::fail("system information unavailable");
        }
        PerformResponse::ok().message(summaries.join(" · "))
    }
}

fn main() {
    run(Sysinfo::default());
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;
    use std::sync::Arc;
    use std::time::{Duration, Instant};

    use flash_plugin::testing::Harness;
    use serde_json::{Value, json};
    use tokio::task::JoinHandle;

    use super::*;

    fn published_segments() -> Vec<&'static str> {
        cpu::SEGMENTS
            .iter()
            .chain(memory::SEGMENTS.iter())
            .chain(disks::SEGMENTS.iter())
            .chain(network::SEGMENTS.iter())
            .chain(power::SEGMENTS.iter())
            .copied()
            .collect()
    }

    #[test]
    fn manifest_status_names_are_exactly_the_published_segments() {
        let manifest: Value = serde_json::from_str(include_str!("../manifest.json")).unwrap();
        let declared: Vec<&str> = manifest["status"]
            .as_array()
            .unwrap()
            .iter()
            .map(|name| name.as_str().unwrap())
            .collect();
        let published = published_segments();
        assert_eq!(declared, published);
        assert_eq!(published.len(), 33);
        for (prefix, names) in [
            (cpu::PREFIX, &cpu::SEGMENTS[..]),
            (memory::PREFIX, &memory::SEGMENTS[..]),
            (disks::PREFIX, &disks::SEGMENTS[..]),
            (network::PREFIX, &network::SEGMENTS[..]),
            ("power_", &power::SEGMENTS[..]),
        ] {
            assert!(
                names.iter().all(|name| name.starts_with(prefix)),
                "{prefix}: {names:?}"
            );
            for suffix in ["summary", "label", "details"] {
                assert!(names.contains(&format!("{prefix}{suffix}").as_str()));
            }
        }
        let subcommands: Vec<&str> = manifest["commands"]
            .as_array()
            .unwrap()
            .iter()
            .map(|command| {
                assert_eq!(command["command"], "sysinfo");
                command["subcommand"].as_str().unwrap()
            })
            .collect();
        assert_eq!(
            subcommands,
            ["cpu", "memory", "disks", "network", "power", "refresh"]
        );
    }

    /// Plays the host for `task`: answers every Wi-Fi read with no network
    /// and delivers each deadline's tick once its delay has elapsed, so
    /// cpu's first-sample bracket spans real ticks.
    async fn drive<T: Send + 'static>(harness: &mut Harness, task: JoinHandle<T>) -> T {
        let mut deadlines: Vec<(Instant, String)> = Vec::new();
        let started = Instant::now();
        while !task.is_finished() {
            assert!(
                started.elapsed() < Duration::from_secs(20),
                "the host-driven task did not complete"
            );
            let due = Instant::now();
            for (_, name) in deadlines.extract_if(.., |(at, _)| *at <= due) {
                harness.deliver_poll_tick(&name);
            }
            let Ok(Some(frame)) =
                tokio::time::timeout(Duration::from_millis(50), harness.next_frame()).await
            else {
                continue;
            };
            match (
                frame.get("id").and_then(Value::as_u64),
                frame["method"].as_str(),
            ) {
                (Some(id), Some("host.wifi_info")) => {
                    assert!(harness.reply_host(id, json!({ "ok": true, "present": false })));
                }
                (None, Some("poll")) => {
                    let registrations = frame["params"]["registrations"]
                        .as_object()
                        .cloned()
                        .unwrap_or_default();
                    for (name, registration) in registrations {
                        if let Some(after) = registration["after"].as_f64()
                            && !deadlines.iter().any(|(_, pending)| *pending == name)
                        {
                            deadlines.push((Instant::now() + Duration::from_secs_f64(after), name));
                        }
                    }
                }
                _ => {}
            }
        }
        task.await.expect("the host-driven task completes")
    }

    async fn started(harness: &mut Harness) -> Arc<Sysinfo> {
        let plugin = Arc::new(Sysinfo::default());
        let starting = Arc::clone(&plugin);
        let ctx = harness.context();
        drive(
            harness,
            tokio::spawn(async move { starting.on_start(ctx).await }),
        )
        .await;
        harness.drain();
        plugin
    }

    fn observed(segments: &[&str]) -> Event {
        Event {
            name: host_events::STATUS_OBSERVED.to_string(),
            segments: Some(segments.iter().map(|name| name.to_string()).collect()),
            ..Event::default()
        }
    }

    /// The cadences the last `poll` frame left registered, as (period,
    /// priority) pairs.
    fn cadences(harness: &mut Harness) -> Vec<(f64, String)> {
        let mut cadences: Vec<(f64, String)> = harness
            .drain_poll_registrations()
            .expect("a poll frame")
            .values()
            .map(|registration| {
                (
                    registration["every"].as_f64().expect("a cadence"),
                    registration["priority"].as_str().unwrap().to_string(),
                )
            })
            .collect();
        cadences.sort_by(|a, b| a.partial_cmp(b).unwrap());
        cadences
    }

    /// `core:status.observed` carries every domain's segments in one set;
    /// each domain follows only the names under its prefix.
    #[tokio::test]
    async fn observation_arms_only_the_named_domain() {
        let mut harness = Harness::new("sysinfo");
        let plugin = started(&mut harness).await;
        let ctx = harness.context();

        plugin.on_event(ctx.clone(), observed(&[])).await;
        assert!(
            harness
                .drain_poll_registrations()
                .expect("every cadence cancelled")
                .is_empty()
        );

        plugin
            .on_event(ctx.clone(), observed(&["cpu_percent"]))
            .await;
        assert_eq!(
            cadences(&mut harness),
            [(1.0, "high".to_string()), (15.0, "normal".to_string())],
            "cpu's one-second and GPU cadences, nothing else"
        );

        plugin
            .on_event(ctx.clone(), observed(&["memory_history"]))
            .await;
        assert_eq!(cadences(&mut harness), [(1.0, "high".to_string())]);

        plugin
            .on_event(ctx.clone(), observed(&["disks_read_bps"]))
            .await;
        assert_eq!(cadences(&mut harness), [(3.0, "normal".to_string())]);

        plugin
            .on_event(ctx.clone(), observed(&["network_down_bps"]))
            .await;
        assert_eq!(cadences(&mut harness), [(1.0, "high".to_string())]);

        // `address` follows discovery and power follows its event: no cadence.
        plugin
            .on_event(ctx.clone(), observed(&["network_address", "power_percent"]))
            .await;
        assert!(cadences(&mut harness).is_empty());
    }

    fn command(subcommand: &str) -> CommandRequest {
        CommandRequest {
            command: "sysinfo".to_string(),
            subcommand: subcommand.to_string(),
            ..CommandRequest::default()
        }
    }

    #[tokio::test]
    async fn commands_route_to_their_domain() {
        let mut harness = Harness::new("sysinfo");
        let plugin = started(&mut harness).await;
        let ctx = harness.context();

        let mut replies: BTreeMap<&str, PerformResponse> = BTreeMap::new();
        for subcommand in ["cpu", "memory", "disks", "network", "power"] {
            replies.insert(
                subcommand,
                plugin.on_command(ctx.clone(), command(subcommand)).await,
            );
        }
        for (subcommand, title) in [
            ("cpu", "CPU"),
            ("memory", "Memory"),
            ("disks", "Disks"),
            ("network", "Network"),
        ] {
            let reply = &replies[subcommand];
            assert!(reply.is_ok(), "{subcommand}: {:?}", reply.error_message());
            assert_eq!(
                reply.toast_message().unwrap().lines().next(),
                Some(title),
                "{subcommand}"
            );
        }
        // A Mac without a readable power source answers with its own failure.
        let power = &replies["power"];
        assert!(
            power.is_ok() || power.error_message() == Some("power information unavailable"),
            "{:?}",
            power.error_message()
        );

        let refreshing = Arc::clone(&plugin);
        let refresh_ctx = ctx.clone();
        let refresh = drive(
            &mut harness,
            tokio::spawn(
                async move { refreshing.on_command(refresh_ctx, command("refresh")).await },
            ),
        )
        .await;
        assert!(refresh.is_ok(), "{:?}", refresh.error_message());
        let line = refresh.toast_message().unwrap();
        assert!(line.starts_with("CPU "), "{line}");
        assert!(line.contains(" · MEM "), "{line}");
        assert!(line.contains(" · DSK "), "{line}");
        assert!(line.contains(" · NET"), "{line}");
        assert!(!line.contains("#["), "{line}");

        let unknown = plugin.on_command(ctx, command("gpu")).await;
        assert!(!unknown.is_ok());
        assert_eq!(unknown.error_message(), Some("unknown subcommand: gpu"));
    }
}
