//! The `focused_app_details` status segment: live resource figures for the
//! focused app's process.
//!
//! Sampling is scoped to observation, as the top tables are. The plugin always
//! tracks which app is focused (`core:focus.changed` carries identity, which is
//! free), but it reads `host.process_metrics` only while a status surface
//! shows the segment (`core:status.observed`): at once when the segment
//! becomes observed, after a focus change settles, and on a host-driven
//! cadence for the CPU figure, which has no change event. A segment that
//! stops being shown is cleared, so showing it again never reads another
//! moment's figures.

use std::sync::{Mutex, MutexGuard};
use std::time::Duration;

use flash_plugin::status::{bytes_iec, duration_uptime};
use flash_plugin::{
    Context, Deadline, Event, Markup, PollHandle, PollPriority, Preview, RefreshGate,
};
use serde_json::Value;
use tokio::task::JoinHandle;

use crate::CPU_SAMPLE_WINDOW;

pub(crate) const SEGMENT: &str = "focused_app_details";
/// CPU use has no change event: while the segment is observed its figures
/// are resampled on this cadence, registered with the host clock.
pub(crate) const FOCUSED_POLL: Duration = Duration::from_secs(10);
/// A burst of focus changes (cmd-tab through several apps) samples only the
/// app the user settles on.
const FOCUS_REFRESH_DEBOUNCE: Duration = Duration::from_millis(300);

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct FocusedApp {
    pub(crate) pid: i64,
    pub(crate) bundle_id: String,
}

impl FocusedApp {
    pub(crate) fn from_event(event: &Event) -> Option<Self> {
        let pid = event.pid.filter(|pid| *pid > 0)?;
        Some(Self {
            pid,
            bundle_id: event.bundle_id.clone().unwrap_or_default(),
        })
    }
}

#[derive(Clone, Debug, PartialEq)]
struct FocusedProcessMetrics {
    comm: String,
    cpu_percent: f64,
    memory_bytes: u64,
    mem_percent: f64,
    process_count: u64,
    socket_count: u64,
    thread_count: u64,
    uptime_seconds: u64,
    disk_read_bytes: u64,
    disk_write_bytes: u64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct FocusedSample {
    app: FocusedApp,
    generation: u64,
}

#[derive(Debug, Default)]
struct FocusedState {
    app: Option<FocusedApp>,
    generation: u64,
    /// A status surface shows the segment: only then does anything sample
    /// or publish it.
    observed: bool,
}

impl FocusedState {
    fn replace(&mut self, app: FocusedApp) -> FocusedSample {
        self.generation = self.generation.wrapping_add(1);
        self.app = Some(app.clone());
        FocusedSample {
            app,
            generation: self.generation,
        }
    }

    fn install_if_empty(&mut self, app: FocusedApp) -> Option<FocusedSample> {
        self.app.is_none().then(|| self.replace(app))
    }

    fn clear(&mut self) {
        self.generation = self.generation.wrapping_add(1);
        self.app = None;
    }

    fn snapshot(&self) -> Option<FocusedSample> {
        self.app.clone().map(|app| FocusedSample {
            app,
            generation: self.generation,
        })
    }

    fn is_current(&self, sample: &FocusedSample) -> bool {
        self.generation == sample.generation && self.app.as_ref() == Some(&sample.app)
    }

    /// A sample may publish only while it is current and observed.
    fn publishable(&self, sample: &FocusedSample) -> bool {
        self.observed && self.is_current(sample)
    }
}

#[derive(Default)]
struct SamplerState {
    focus: FocusedState,
    /// Registered on first observation and re-armed or cancelled in place
    /// after that, so toggling observation never leaks a registration.
    poll: Option<PollHandle>,
    /// The pending sample after a focus change; the next change replaces it.
    settle: Option<Deadline>,
}

/// Owns the focused-app segment: the tracked app, whether a surface shows the
/// segment, and the cadence registered while it does.
#[derive(Default)]
pub(crate) struct FocusedSampler {
    state: Mutex<SamplerState>,
    gate: RefreshGate,
}

impl FocusedSampler {
    fn lock(&self) -> MutexGuard<'_, SamplerState> {
        self.state.lock().unwrap_or_else(|error| error.into_inner())
    }

    /// Apply the host's observed segment set. The cadence is armed only while
    /// the segment is observed and cancelled as soon as it is not, clearing
    /// the segment. Returns the immediate sample when it just became observed.
    pub(crate) fn observe(
        &'static self,
        ctx: &Context,
        segments: &[String],
    ) -> Option<JoinHandle<()>> {
        let observed = segments.iter().any(|segment| segment == SEGMENT);
        let mut state = self.lock();
        if state.focus.observed == observed {
            return None;
        }
        state.focus.observed = observed;
        if !observed {
            if let Some(poll) = &state.poll {
                poll.cancel();
            }
            // Emitted under the lock, so no sample can publish in between.
            ctx.status([(SEGMENT, "")]);
            return None;
        }
        match &state.poll {
            Some(poll) => poll.set_period(FOCUSED_POLL),
            None => {
                // `Normal`: a ten-second refresh of figures on screen, where
                // a tenth of a second of slack is invisible.
                state.poll =
                    Some(
                        ctx.interval(FOCUSED_POLL, PollPriority::Normal, move |ctx| async move {
                            self.refresh(&ctx).await;
                        }),
                    );
            }
        }
        drop(state);
        let ctx = ctx.clone();
        Some(tokio::spawn(async move { self.sample_now(&ctx).await }))
    }

    /// Track the newly focused app. While observed, show its placeholder and
    /// sample it once the focus burst settles: each change re-arms one host
    /// deadline, at `High` because the placeholder on screen is waiting for
    /// it. True when that deadline was armed.
    pub(crate) fn focus_changed(&'static self, ctx: &Context, event: &Event) -> bool {
        let mut state = self.lock();
        if let Some(pending) = state.settle.take() {
            pending.cancel();
        }
        let Some(app) = FocusedApp::from_event(event) else {
            state.focus.clear();
            if state.focus.observed {
                ctx.status([(SEGMENT, "")]);
            }
            return false;
        };
        let sample = state.focus.replace(app);
        if !state.focus.observed {
            return false;
        }
        ctx.status([(
            SEGMENT,
            focused_app_placeholder(&sample.app, "Collecting metrics…"),
        )]);
        state.settle = Some(ctx.after(
            FOCUS_REFRESH_DEBOUNCE,
            PollPriority::High,
            move |ctx| async move {
                if self.lock().focus.publishable(&sample) {
                    self.refresh(&ctx).await;
                }
            },
        ));
        true
    }

    /// Sample the focused app and publish its figures. A tick that raced a
    /// disarm finds nothing observed and does not sample.
    pub(crate) async fn refresh(&self, ctx: &Context) {
        self.gate
            .run(ctx, |ctx, _applications| async move {
                let Some(sample) = self.observed_sample() else {
                    return;
                };
                let response = ctx
                    .process_metrics(sample.app.pid, Some(CPU_SAMPLE_WINDOW.as_millis() as u64))
                    .await;
                let content = focused_process_metrics(&response, sample.app.pid)
                    .map(|metrics| focused_app_details(&sample.app, &metrics))
                    .unwrap_or_else(|| focused_app_placeholder(&sample.app, "Metrics unavailable"));
                self.publish_if_current(&ctx, &sample, content);
            })
            .await;
    }

    /// The segment just became observed: resolve the focused app when no
    /// focus event has named one yet, then sample it.
    async fn sample_now(&self, ctx: &Context) {
        if self.lock().focus.app.is_none() {
            let Some(target) = ctx.normal_mode_target().await else {
                return;
            };
            self.lock().focus.install_if_empty(FocusedApp {
                pid: target.pid,
                bundle_id: target.bundle_id,
            });
        }
        let Some(sample) = self.observed_sample() else {
            return;
        };
        self.publish_if_current(
            ctx,
            &sample,
            focused_app_placeholder(&sample.app, "Collecting metrics…"),
        );
        self.refresh(ctx).await;
    }

    fn observed_sample(&self) -> Option<FocusedSample> {
        let state = self.lock();
        state
            .focus
            .observed
            .then(|| state.focus.snapshot())
            .flatten()
    }

    fn publish_if_current(&self, ctx: &Context, sample: &FocusedSample, content: String) {
        let state = self.lock();
        if state.focus.publishable(sample) {
            ctx.status([(SEGMENT, content)]);
        }
    }
}

fn focused_process_metrics(response: &Value, pid: i64) -> Option<FocusedProcessMetrics> {
    let row = response
        .get("processes")?
        .as_array()?
        .iter()
        .find(|row| row.get("pid").and_then(Value::as_i64) == Some(pid))?;
    Some(FocusedProcessMetrics {
        comm: row.get("comm")?.as_str()?.to_string(),
        cpu_percent: row.get("cpu_percent")?.as_f64()?,
        memory_bytes: row.get("memory_bytes")?.as_u64()?,
        mem_percent: row.get("mem_percent")?.as_f64()?,
        process_count: row.get("process_count")?.as_u64()?,
        socket_count: row.get("socket_count")?.as_u64()?,
        thread_count: row.get("thread_count")?.as_u64()?,
        uptime_seconds: row.get("uptime_seconds")?.as_u64()?,
        disk_read_bytes: row.get("disk_read_bytes")?.as_u64()?,
        disk_write_bytes: row.get("disk_write_bytes")?.as_u64()?,
    })
}

/// The `focused_app_details` segment feeds a document template, so the rows
/// are rendered plain: the template owns colour.
fn focused_app_details(app: &FocusedApp, metrics: &FocusedProcessMetrics) -> String {
    focused_app_identity(app)
        .row("Process", Markup::text(&metrics.comm))
        .row("CPU", format!("{:.1}%", metrics.cpu_percent))
        .row(
            "Memory",
            format!(
                "{} ({:.1}%)",
                bytes_iec(metrics.memory_bytes),
                metrics.mem_percent
            ),
        )
        .row("Sockets", metrics.socket_count.to_string())
        .row("Processes", metrics.process_count.to_string())
        .row("Threads", metrics.thread_count.to_string())
        .row("Uptime", duration_uptime(metrics.uptime_seconds))
        .row(
            "Disk I/O",
            format!(
                "{} read · {} written",
                bytes_iec(metrics.disk_read_bytes),
                bytes_iec(metrics.disk_write_bytes)
            ),
        )
        .render_plain()
}

fn focused_app_placeholder(app: &FocusedApp, state: &str) -> String {
    focused_app_identity(app).note(state).render_plain()
}

fn focused_app_identity(app: &FocusedApp) -> Preview {
    Preview::new()
        .row("Bundle", Markup::text(bundle_label(app)))
        .row("PID", app.pid.to_string())
}

fn bundle_label(app: &FocusedApp) -> &str {
    let bundle = app.bundle_id.trim();
    if bundle.is_empty() {
        "Unavailable"
    } else {
        bundle
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use flash_plugin::testing::Harness;
    use serde_json::json;

    #[test]
    fn focused_app_details_formats_live_and_lifetime_metrics() {
        let app = FocusedApp {
            pid: 4242,
            bundle_id: "org.mozilla.firefox".into(),
        };
        let metrics = FocusedProcessMetrics {
            comm: "firefox".into(),
            cpu_percent: 12.5,
            memory_bytes: 1_610_612_736,
            mem_percent: 6.25,
            process_count: 9,
            socket_count: 7,
            thread_count: 42,
            uptime_seconds: 7_384,
            disk_read_bytes: 536_870_912,
            disk_write_bytes: 67_108_864,
        };

        assert_eq!(
            focused_app_details(&app, &metrics),
            "Bundle        org.mozilla.firefox\n\
PID           4242\n\
Process       firefox\n\
CPU           12.5%\n\
Memory        1.5 GiB (6.2%)\n\
Sockets       7\n\
Processes     9\n\
Threads       42\n\
Uptime        2h 3m\n\
Disk I/O      512 MiB read · 64 MiB written"
        );
    }

    #[test]
    fn focused_app_details_keep_literal_hashes_from_external_names() {
        let app = FocusedApp {
            pid: 7,
            bundle_id: "com.example.#[dev]".into(),
        };
        assert_eq!(
            focused_app_placeholder(&app, "Metrics unavailable"),
            "Bundle        com.example.#[dev]\nPID           7\nMetrics unavailable"
        );
    }

    #[test]
    fn focused_app_placeholder_never_reuses_another_apps_metrics() {
        let app = FocusedApp {
            pid: 99,
            bundle_id: "com.example.Editor".into(),
        };
        assert_eq!(
            focused_app_placeholder(&app, "Collecting metrics…"),
            "Bundle        com.example.Editor\nPID           99\nCollecting metrics…"
        );
    }

    #[test]
    fn focused_metrics_parse_the_exact_requested_process() {
        let response = json!({
            "ok": true,
            "processes": [{
                "pid": 7,
                "comm": "wrong"
            }, {
                "pid": 42,
                "comm": "right",
                "cpu_percent": 1.25,
                "memory_bytes": 2048,
                "mem_percent": 0.5,
                "process_count": 4,
                "socket_count": 2,
                "thread_count": 3,
                "uptime_seconds": 4,
                "disk_read_bytes": 5,
                "disk_write_bytes": 6
            }]
        });

        let metrics = focused_process_metrics(&response, 42).expect("metrics");
        assert_eq!(metrics.comm, "right");
        assert_eq!(metrics.socket_count, 2);
        assert_eq!(metrics.process_count, 4);
        assert_eq!(metrics.disk_write_bytes, 6);
    }

    #[test]
    fn focused_app_is_built_only_from_a_valid_focus_event() {
        let valid = Event {
            name: "core:focus.changed".into(),
            bundle_id: Some("com.example.App".into()),
            pid: Some(123),
            ..Event::default()
        };
        assert_eq!(
            FocusedApp::from_event(&valid),
            Some(FocusedApp {
                pid: 123,
                bundle_id: "com.example.App".into()
            })
        );
        assert!(
            FocusedApp::from_event(&Event {
                pid: Some(0),
                ..Event::default()
            })
            .is_none()
        );
    }

    #[test]
    fn focus_generation_rejects_an_older_in_flight_sample() {
        let mut state = FocusedState::default();
        let old = state.replace(FocusedApp {
            pid: 1,
            bundle_id: "com.example.Old".into(),
        });
        let current = state.replace(FocusedApp {
            pid: 2,
            bundle_id: "com.example.Current".into(),
        });

        assert!(!state.is_current(&old));
        assert!(state.is_current(&current));
        assert!(
            state
                .install_if_empty(FocusedApp {
                    pid: 3,
                    bundle_id: "com.example.StaleInitialization".into(),
                })
                .is_none()
        );
        assert!(state.is_current(&current));
        assert!(!state.publishable(&current), "unobserved never publishes");
        state.observed = true;
        assert!(state.publishable(&current));
        assert!(!state.publishable(&old));
    }

    fn segments(names: &[&str]) -> Vec<String> {
        names.iter().map(|name| name.to_string()).collect()
    }

    fn focus(pid: i64, bundle_id: &str) -> Event {
        Event {
            name: "core:focus.changed".into(),
            bundle_id: Some(bundle_id.into()),
            pid: Some(pid),
            ..Event::default()
        }
    }

    fn frames_with(frames: &[Value], method: &str, key: &str) -> Vec<Value> {
        frames
            .iter()
            .filter(|frame| frame["method"] == method)
            .map(|frame| frame["params"][key].clone())
            .collect()
    }

    /// Answer the sampler's metrics read for `pid`.
    async fn reply_metrics(harness: &mut Harness, pid: i64) {
        let (id, method, params) = harness.next_host_request().await.expect("metrics read");
        assert_eq!(method, "host.process_table");
        assert_eq!(params, json!({ "pid": pid, "sample_window_ms": 150 }));
        assert!(harness.reply_host(
            id,
            json!({ "ok": true, "processes": [{
                "pid": pid, "comm": "editor", "cpu_percent": 2.5,
                "memory_bytes": 1024, "mem_percent": 0.5, "process_count": 1,
                "socket_count": 0, "thread_count": 4, "uptime_seconds": 60,
                "disk_read_bytes": 0, "disk_write_bytes": 0
            }]})
        ));
    }

    #[tokio::test]
    async fn sampling_runs_only_while_the_segment_is_observed() {
        let sampler: &'static FocusedSampler = Box::leak(Box::default());
        let mut harness = Harness::new("processes");
        let ctx = harness.context();

        // Unobserved: focus is tracked, but nothing registers, samples, or
        // publishes — including for other segments being observed.
        assert!(!sampler.focus_changed(&ctx, &focus(42, "com.example.Editor")));
        assert!(sampler.observe(&ctx, &segments(&["top_cpu"])).is_none());
        sampler.refresh(&ctx).await;
        assert!(harness.drain().is_empty());

        // Observed: the cadence registers and the tracked app samples at once.
        let sample = sampler
            .observe(&ctx, &segments(&["focused_app_details", "top_cpu"]))
            .expect("immediate sample");
        reply_metrics(&mut harness, 42).await;
        sample.await.unwrap();
        let frames = harness.drain();
        assert_eq!(
            frames_with(&frames, "poll", "registrations"),
            [json!({ "i0": { "every": 10.0, "priority": "normal" } })]
        );
        let published = frames_with(&frames, "status", "segments");
        assert_eq!(published.len(), 2, "{published:?}");
        assert!(
            published[1][SEGMENT]
                .as_str()
                .is_some_and(|details| details.contains("CPU           2.5%")),
            "{published:?}"
        );

        // A focus change while observed publishes the placeholder, then the
        // settled sample once its host deadline lands; a second change
        // inside the window replaces that deadline.
        assert!(sampler.focus_changed(&ctx, &focus(8, "com.example.Passing")));
        assert!(sampler.focus_changed(&ctx, &focus(7, "com.example.Other")));
        let frames = harness.drain();
        let polls = frames_with(&frames, "poll", "registrations");
        assert_eq!(
            polls.last(),
            Some(&json!({
                "i0": { "every": 10.0, "priority": "normal" },
                "d2": { "after": 0.3, "priority": "high" },
            })),
            "{polls:?}"
        );
        assert!(harness.deliver_poll_tick("d1").is_none(), "replaced");
        let settled = harness.deliver_poll_tick("d2").expect("debounced sample");
        reply_metrics(&mut harness, 7).await;
        settled.await.unwrap();
        assert_eq!(frames_with(&harness.drain(), "status", "segments").len(), 1);

        // No longer observed: the cadence is cancelled, the segment cleared,
        // and a tick that raced the change does not sample.
        assert!(sampler.observe(&ctx, &segments(&[])).is_none());
        let frames = harness.drain();
        assert_eq!(frames_with(&frames, "poll", "registrations"), [json!({})]);
        assert_eq!(
            frames_with(&frames, "status", "segments"),
            [json!({ SEGMENT: "" })]
        );
        sampler.refresh(&ctx).await;
        assert!(!sampler.focus_changed(&ctx, &focus(9, "com.example.Third")));
        assert!(harness.drain().is_empty());

        // Observing again re-arms the same registration.
        let sample = sampler
            .observe(&ctx, &segments(&["focused_app_details"]))
            .expect("immediate sample");
        reply_metrics(&mut harness, 9).await;
        sample.await.unwrap();
        assert_eq!(
            frames_with(&harness.drain(), "poll", "registrations"),
            [json!({ "i0": { "every": 10.0, "priority": "normal" } })]
        );
    }
}
