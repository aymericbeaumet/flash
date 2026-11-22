//! Hint discovery: the focused client's layout, its pane chips and the link
//! chips found in visible pane captures.

use std::collections::HashMap;

use flash_plugin::{
    Context, Frame, HintsRequest, HintsResponse, JumpTarget, Priority, TERMINAL_LINK_ROLE,
};

use crate::clients::{
    PaneCaptureRunner, TMUX_FIELD_SEP, TmuxClient, focused_tmux_client, run_tmux_for_client,
};
use crate::geometry::resolve_geometry;
use crate::links::{captured_links, is_url};
use crate::{Tmux, pane_capture, status_hints};

const PANE_TARGET_ROLE: &str = "tmux-pane";

/// Status lines `#{status}` turns on: `on` is one, a number is that many.
fn status_line_count(raw: &str) -> i64 {
    raw.parse::<i64>()
        .unwrap_or(if raw == "on" { 1 } else { 0 })
}

/// Returns the status-line top offset in rows: the number of status lines
/// occupying the top of the client when `status-position` is `top`.
pub(crate) fn parse_status_top_offset(line: &str) -> i64 {
    let mut parts = line.split_whitespace();
    let lines = status_line_count(parts.next().unwrap_or(""));
    let at_top = parts.next() == Some("top");
    if at_top { lines } else { 0 }
}

/// Client row of `status-format[0]` from `#{status} #{status-position}`. A
/// top status occupies row 0; a bottom one the last status rows, line 0
/// first.
pub(crate) fn status_format_row(status: &str, client_rows: i64) -> Option<i64> {
    let mut fields = status.split_whitespace();
    let lines = status_line_count(fields.next()?);
    if lines <= 0 || client_rows <= 0 {
        return None;
    }
    match fields.next()? {
        "top" => Some(0),
        "bottom" => Some((client_rows - lines).max(0)),
        _ => None,
    }
}

fn status_hint_row(status: &str, client_rows: i64) -> Option<i64> {
    let mut fields = status.split_whitespace();
    if !matches!(fields.next()?, "on" | "1") || client_rows <= 0 {
        return None;
    }
    let row = match fields.next()? {
        "top" => 0,
        "bottom" => client_rows - 1,
        _ => return None,
    };
    matches!(fields.next()?, "on" | "1").then_some(row)
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Pane {
    id: String,
    pub(crate) left: i64,
    pub(crate) top: i64,
    pub(crate) cols: i64,
    pub(crate) rows: i64,
    pub(crate) border: String,
    pub(crate) title: String,
}

#[derive(Debug, PartialEq, Eq)]
struct HintContext {
    server_pid: i64,
    session_id: String,
    window_id: String,
}

impl HintContext {
    pub(crate) fn parse(raw: &str) -> Option<Self> {
        let fields: Vec<_> = raw.split_whitespace().collect();
        if fields.len() != 3 {
            return None;
        }
        let server_pid = fields[0].parse::<i64>().ok().filter(|pid| *pid > 0)?;
        for (value, marker) in [(fields[1], '$'), (fields[2], '@')] {
            value.strip_prefix(marker)?.parse::<u64>().ok()?;
        }
        Some(Self {
            server_pid,
            session_id: fields[1].to_string(),
            window_id: fields[2].to_string(),
        })
    }

    fn target_id(&self, client: &TmuxClient, pane_id: &str) -> String {
        serde_json::json!([
            client.backend_id,
            client.tty,
            self.server_pid,
            self.session_id,
            self.window_id,
            pane_id,
        ])
        .to_string()
    }
}

fn parse_hint_pane(line: &str, context: &HintContext) -> Option<Pane> {
    let mut parts = line.splitn(3, TMUX_FIELD_SEP);
    let geometry = parts.next()?;
    let raw_context = parts.next()?;
    let title = parts.next().unwrap_or("");
    if HintContext::parse(raw_context).as_ref() != Some(context) {
        return None;
    }
    let fields: Vec<_> = geometry.split_whitespace().collect();
    // capture-pane without -M reads the base grid, never a displayed copy mode.
    if fields.len() != 7 || fields[6] != "0" {
        return None;
    }
    let border = fields[5];
    fields[0].strip_prefix('%')?.parse::<u64>().ok()?;
    Some(Pane {
        id: fields[0].to_string(),
        left: fields[1].parse::<i64>().ok().filter(|value| *value >= 0)?,
        top: fields[2].parse::<i64>().ok().filter(|value| *value >= 0)?,
        cols: fields[3].parse::<i64>().ok().filter(|value| *value > 0)?,
        rows: fields[4].parse::<i64>().ok().filter(|value| *value > 0)?,
        border: border.to_string(),
        title: title.to_string(),
    })
}

// Nine positional args is on the high side, but `JumpTarget` itself is the
// shape — collapsing this into a `BuildTargetArgs` struct would just rename
// the same data without making the call sites clearer.
#[allow(clippy::too_many_arguments)]
fn build_target(
    target_id: &str,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    role: &str,
    label: &str,
    pid: i64,
    priority: Priority,
) -> JumpTarget {
    let target = JumpTarget::new(target_id, Frame::new(x, y, width, height))
        .role(role)
        .label(label)
        .pid(pid)
        .priority(priority);
    if role == TERMINAL_LINK_ROLE && is_url(label) {
        target.url(label)
    } else {
        target
    }
}

/// One consistent read of a client's visible layout: its cell grid, its
/// status line and the panes of its current window, from two replies that
/// both name the server, session and window they describe.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct ClientLayout {
    pub(crate) columns: i64,
    pub(crate) rows: i64,
    pub(crate) cell_width: i64,
    pub(crate) cell_height: i64,
    /// `#{status} #{status-position} #{mouse} #{window_zoomed_flag}`.
    pub(crate) status: String,
    context: HintContext,
    /// `#{W:#{window_index} #{window_id};}`.
    windows: String,
    /// `#{T:status-format[0]}`.
    pub(crate) status_format: String,
    pub(crate) panes: Vec<Pane>,
}

impl ClientLayout {
    /// `combined` is the `display-message` reply, `pane_list` the
    /// `list-panes` one. Any malformed pane, or one from another context,
    /// rejects the read.
    pub(crate) fn parse(combined: &str, pane_list: &str) -> Option<Self> {
        let fields: Vec<&str> = combined
            .trim_end_matches(['\r', '\n'])
            .splitn(5, TMUX_FIELD_SEP)
            .collect();
        let [size, status, context, windows, status_format] = fields.as_slice() else {
            return None;
        };
        let status_fields: Vec<_> = status.split_whitespace().collect();
        // Zoom hides the ordinary pane layout; do not map it onto the client.
        if status_fields.len() != 4 || status_fields[3] != "0" {
            return None;
        }
        let context = HintContext::parse(context)?;
        let values = size
            .split_whitespace()
            .map(str::parse::<i64>)
            .collect::<Result<Vec<_>, _>>()
            .ok()?;
        let [columns, rows, cell_width, cell_height] = values.as_slice() else {
            return None;
        };
        let (columns, rows, cell_width, cell_height) = (*columns, *rows, *cell_width, *cell_height);
        if columns <= 0 || rows <= 0 {
            return None;
        }
        let panes: Vec<Pane> = pane_list
            .lines()
            .filter(|line| !line.trim().is_empty())
            .map(|line| parse_hint_pane(line, &context))
            .collect::<Option<_>>()?;
        if panes.is_empty() {
            return None;
        }
        Some(Self {
            columns,
            rows,
            cell_width,
            cell_height,
            status: status.to_string(),
            context,
            windows: windows.to_string(),
            status_format: status_format.to_string(),
            panes,
        })
    }
}

/// Read `client`'s layout. Client metadata and pane geometry run together;
/// both replies carry the live context, so a window switch between them
/// still rejects the read.
pub(crate) async fn client_layout(plugin: &Tmux, client: &TmuxClient) -> Option<ClientLayout> {
    // Pack client geometry and status onto one line separated by the literal
    // `|||` field marker rather than a `\n`. An embedded newline in a
    // `display-message -p` format is NOT reliably rendered as a line break —
    // depending on tmux server state it can collapse, in which case the client
    // dimensions and the status fields arrive on a single line and
    // `parse_two_ints` chokes on `"<height> <status>"`. The read then fails
    // and `f` silently produces zero hints over a live tmux window. `|||` is
    // literal text the server always emits verbatim (the same separator
    // `list-clients`/`list-windows` rely on), so the split is deterministic.
    let combined_format = format!(
        "#{{client_width}} #{{client_height}} #{{client_cell_width}} #{{client_cell_height}}{TMUX_FIELD_SEP}#{{status}} #{{status-position}} #{{mouse}} #{{window_zoomed_flag}}{TMUX_FIELD_SEP}#{{pid}} #{{session_id}} #{{window_id}}{TMUX_FIELD_SEP}#{{W:#{{window_index}} #{{window_id}};}}{TMUX_FIELD_SEP}#{{T:status-format[0]}}"
    );
    let pane_format = format!(
        "#{{pane_id}} #{{pane_left}} #{{pane_top}} #{{pane_width}} #{{pane_height}} #{{pane-border-status}} #{{pane_in_mode}}{TMUX_FIELD_SEP}#{{pid}} #{{session_id}} #{{window_id}}{TMUX_FIELD_SEP}#{{T:pane-border-format}}"
    );
    let display_args = [
        "display-message",
        "-c",
        &client.tty,
        "-t",
        &client.tty,
        "-p",
        &combined_format,
    ];
    let pane_args = ["list-panes", "-t", &client.tty, "-F", &pane_format];
    let (combined, pane_list) = tokio::join!(
        run_tmux_for_client(plugin, client, &display_args),
        run_tmux_for_client(plugin, client, &pane_args),
    );
    ClientLayout::parse(&combined?, &pane_list?)
}

/// `capture-pane -p` of every pane, by index. They run concurrently: one
/// subprocess per pane on the `f` hot path would otherwise run strictly in
/// sequence.
pub(crate) async fn capture_panes(
    plugin: &Tmux,
    client: &TmuxClient,
    panes: &[Pane],
) -> Vec<Option<String>> {
    let capture_runner = if client.remote {
        PaneCaptureRunner::Remote(plugin.remote_config(&client.backend_id))
    } else {
        PaneCaptureRunner::Local {
            tmux_path: plugin.resolved_tmux_path().await.map(str::to_string),
            socket_registry: std::sync::Arc::clone(&plugin.tmux_socket_registry_arc),
            socket_path: client.socket_path.clone(),
        }
    };
    let mut capture_tasks = tokio::task::JoinSet::new();
    for (i, pane) in panes.iter().enumerate() {
        let runner = capture_runner.clone();
        let pane_id = pane.id.clone();
        capture_tasks.spawn(async move { (i, runner.capture(&pane_id).await) });
    }
    let mut captures: Vec<Option<String>> = vec![None; panes.len()];
    while let Some(Ok((i, raw))) = capture_tasks.join_next().await {
        captures[i] = raw;
    }
    captures
}

pub(crate) async fn hints_for_context(
    plugin: &Tmux,
    ctx: &Context,
    req: &HintsRequest,
) -> HintsResponse {
    let Some(pid) = req.pid else {
        return HintsResponse::targets(vec![]);
    };
    let bundle_id = req.bundle_id.as_deref().unwrap_or("");
    let frame = req.front_window_frame.unwrap_or_default();
    let win_w = frame.width;
    let win_h = frame.height;
    let min_x = frame.x;
    let min_y = frame.y;
    if win_w <= 0.0 || win_h <= 0.0 {
        return HintsResponse::targets(vec![]).context_pid(pid);
    }

    let Some(client) = focused_tmux_client(plugin, ctx, pid, false).await else {
        return HintsResponse::targets(vec![]).context_pid(pid);
    };
    let Some(layout) = client_layout(plugin, &client).await else {
        return HintsResponse::targets(vec![]).context_pid(pid);
    };
    let (client_cols, client_rows) = (layout.columns, layout.rows);
    let hint_context = &layout.context;
    let panes = &layout.panes;

    let Some((cell_w, cell_h, pad_x, pad_y)) =
        resolve_geometry(bundle_id, pid, win_w, win_h, &layout, req.display_scale).await
    else {
        return HintsResponse::targets(vec![]).context_pid(pid);
    };

    let top_offset = parse_status_top_offset(&layout.status);

    // Pane chip is 3-cells wide so the hint label is readable. Anchored at
    // pane center, chip extends 1 cell left and right.
    let pane_chip_cells: i64 = 3;
    let mut pane_targets: Vec<JumpTarget> = Vec::new();

    struct RawLink {
        screen_row: i64,
        screen_col: i64,
        text: String,
        context_id: String,
        url: Option<String>,
    }
    let mut raw_links: Vec<RawLink> = Vec::new();

    let mut captures = capture_panes(plugin, &client, panes).await;
    if client_layout(plugin, &client).await.as_ref() != Some(&layout) {
        return HintsResponse::targets(vec![]).context_pid(pid);
    }
    for (i, pane) in panes.iter().enumerate() {
        let context_id = hint_context.target_id(&client, &pane.id);
        let center_col = pane.left + pane.cols / 2;
        let center_row = top_offset + pane.top + pane.rows / 2;
        let chip_x = min_x + pad_x + (center_col - pane_chip_cells / 2) as f64 * cell_w;
        let chip_y = min_y + win_h - pad_y - (center_row + 1) as f64 * cell_h;
        let target_id = format!("tmux-{pid}-p{i}");
        // A pane target delegates a plain click to the terminal.
        pane_targets.push(
            build_target(
                &target_id,
                chip_x,
                chip_y,
                pane_chip_cells as f64 * cell_w,
                cell_h,
                PANE_TARGET_ROLE,
                &pane.id,
                pid,
                // Pane chips are the structural anchors of a tmux window, so the
                // renderer paints them in the accent style. Link chips below are
                // everyday clutter and stay in the default yellow.
                Priority::Urgent,
            )
            .context_id(&context_id),
        );

        if let Some(row) =
            status_hints::pane_title_row(&pane.border, top_offset, pane.top, pane.rows)
            && (0..client_rows).contains(&row)
            && let Some(placed) = status_hints::place_format_line(&pane.title, pane.cols as usize)
        {
            pane_targets.push(
                build_target(
                    &format!("tmux-{pid}-t{i}"),
                    min_x + pad_x + (pane.left + placed.column as i64) as f64 * cell_w,
                    min_y + win_h - pad_y - (row + 1) as f64 * cell_h,
                    placed.width as f64 * cell_w,
                    cell_h,
                    "tmux-pane-title",
                    &placed.text,
                    pid,
                    Priority::High,
                )
                .context_id(&context_id),
            );
        }

        let Some(lines) = captures[i]
            .take()
            .and_then(|raw| pane_capture::parse(&raw, pane.cols as usize, pane.rows as usize))
        else {
            return HintsResponse::targets(vec![]).context_pid(pid);
        };
        for (row_idx, content) in lines.iter().enumerate() {
            for (col, text, url) in captured_links(content, pane.cols as usize) {
                raw_links.push(RawLink {
                    screen_row: top_offset + pane.top + row_idx as i64,
                    screen_col: pane.left + col as i64,
                    text,
                    context_id: context_id.clone(),
                    url,
                });
            }
        }
    }

    if let Some(row) = status_hint_row(&layout.status, client_rows)
        && let Some(spans) =
            status_hints::parse_status_hints(&layout.status_format, client_cols as usize)
    {
        let windows: HashMap<u32, &str> = layout
            .windows
            .split(';')
            .filter_map(|entry| {
                let (index, id) = entry.split_once(' ')?;
                id.strip_prefix('@')?.parse::<u64>().ok()?;
                Some((index.parse().ok()?, id))
            })
            .collect();
        for (index, span) in spans.into_iter().enumerate() {
            let Some(window_id) = windows.get(&span.index) else {
                continue;
            };
            let context_id = hint_context.target_id(&client, &format!("window:{window_id}"));
            pane_targets.push(
                build_target(
                    &format!("tmux-{pid}-w{index}"),
                    min_x + pad_x + span.column as f64 * cell_w,
                    min_y + win_h - pad_y - (row + 1) as f64 * cell_h,
                    span.width as f64 * cell_w,
                    cell_h,
                    "tmux-window",
                    &span.label,
                    pid,
                    Priority::High,
                )
                .context_id(context_id),
            );
        }
    }

    // Pane chips emit first so the hint assigner allocates the shortest
    // labels to them. Link chips sort across all panes by screen position
    // (top-to-bottom, left-to-right).
    raw_links.sort_by(|a, b| {
        a.screen_row
            .cmp(&b.screen_row)
            .then(a.screen_col.cmp(&b.screen_col))
    });
    let mut targets = pane_targets;
    for (idx, link) in raw_links.into_iter().enumerate() {
        let x = min_x + pad_x + link.screen_col as f64 * cell_w;
        let y = min_y + win_h - pad_y - (link.screen_row + 1) as f64 * cell_h;
        let target_id = format!("tmux-{pid}-l{idx}");
        // Terminal links use a generic host-understood semantic role. The host
        // sends `f` as Shift-click and `F` as Command-Shift-click so Alacritty
        // handles the link instead of forwarding a pane click to tmux.
        let target = build_target(
            &target_id,
            x,
            y,
            cell_w,
            cell_h,
            TERMINAL_LINK_ROLE,
            &link.text,
            pid,
            Priority::Normal,
        )
        .context_id(link.context_id);
        targets.push(if let Some(uri) = link.url {
            target.url(uri)
        } else {
            target
        });
    }

    HintsResponse::targets(targets).context_pid(pid)
}

#[cfg(test)]
mod tests {
    use super::*;

    use flash_plugin::{TextGridRequest, TextGridResponse};

    use crate::remote::shell_quote;
    use crate::test_support::{ExecutableFixture, client};
    use crate::text_grid::text_grid_for_context;

    #[tokio::test]
    async fn hints_include_every_pane_and_all_visible_links() {
        let fixture = ExecutableFixture::new().await;
        let binary = fixture.script(
            "tmux",
            r#"case "$1" in
display-message) printf '%s\n' '120 61 0 0|||on top on 0|||123 $0 @1|||0 @1;1 @2;|||#[range=user|0]first#[norange] #[range=window|1]second#[norange]' ;;
list-panes) printf '%s\n' '%1 0 0 60 60 off 0|||123 $0 @1' '%2 61 0 59 60 off 0|||123 $0 @1' ;;
capture-pane)
    i=0
    while test "$i" -lt 50; do
        printf 'https://example.com/%s/%s\n' "$3" "$i"
        i=$((i + 1))
    done ;;
*) exit 1 ;;
esac"#,
        ).await;
        let plugin = Tmux::default();
        plugin.tmux_path.set(Some(binary)).unwrap();
        plugin.client_snapshot().lock().unwrap().clients =
            vec![client("/dev/ttys000", "work", 42, 0)];
        let harness = flash_plugin::testing::Harness::new("tmux");
        let request = HintsRequest {
            pid: Some(42),
            front_window_frame: Some(Frame::new(100.0, 200.0, 1200.0, 610.0)),
            ..Default::default()
        };
        let response = hints_for_context(&plugin, &harness.context(), &request).await;
        assert_eq!(response.context_pid, Some(42));
        let panes: Vec<_> = response
            .targets
            .iter()
            .filter(|t| t.role.as_deref() == Some(PANE_TARGET_ROLE))
            .collect();
        assert_eq!(panes.len(), 2);
        let tabs: Vec<_> = response
            .targets
            .iter()
            .filter(|t| t.role.as_deref() == Some("tmux-window"))
            .collect();
        assert_eq!(tabs.len(), 2);
        assert_eq!(tabs[0].frame, Frame::new(100.0, 800.0, 50.0, 10.0));
        assert_eq!(tabs[1].frame, Frame::new(160.0, 800.0, 60.0, 10.0));
        assert_ne!(tabs[0].context_id, tabs[1].context_id);
        let links: Vec<_> = response
            .targets
            .iter()
            .filter(|t| t.role.as_deref() == Some(TERMINAL_LINK_ROLE))
            .collect();
        assert_eq!(links.len(), 100);
        assert_eq!(links[0].frame, Frame::new(100.0, 790.0, 10.0, 10.0));
        assert_eq!(links[1].frame, Frame::new(710.0, 790.0, 10.0, 10.0));
        assert!(
            links
                .iter()
                .any(|t| t.label.as_deref() == Some("https://example.com/%1/49"))
        );
        assert!(
            links
                .iter()
                .any(|t| t.label.as_deref() == Some("https://example.com/%2/49"))
        );

        // An unsupported status layout must not disable pane/link discovery.
        let path = fixture.0.join("tmux");
        let script = tokio::fs::read_to_string(&path).await.unwrap();
        tokio::fs::write(
            &path,
            script.replace("#[range=user|0]", "#[align=right,range=user|0]"),
        )
        .await
        .unwrap();
        let response = hints_for_context(&plugin, &harness.context(), &request).await;
        assert_eq!(response.targets.len(), 102);
        assert!(
            response
                .targets
                .iter()
                .all(|t| t.role.as_deref() != Some("tmux-window"))
        );
        fixture.cleanup().await;
    }

    #[tokio::test]
    async fn hints_recover_osc8_label_and_destination_from_visible_snapshot() {
        let fixture = ExecutableFixture::new().await;
        let binary = fixture.script("tmux", r#"case "$1" in
display-message) printf '%s\n' '80 24 0 0|||off top on 0|||123 $0 @1||||||' ;;
list-panes) printf '%s\n' '%1 0 0 80 24 off 0|||123 $0 @1' ;;
capture-pane) printf '\033[4m界 e\314\201 \033]8;id=docs;https://example.com/actual\033\\Read docs\033]8;;\007\033[0m\n' ;;
*) exit 1 ;;
esac"#).await;
        let plugin = Tmux::default();
        plugin.tmux_path.set(Some(binary)).unwrap();
        plugin.client_snapshot().lock().unwrap().clients =
            vec![client("/dev/ttys000", "work", 42, 0)];
        let harness = flash_plugin::testing::Harness::new("tmux");
        let request = HintsRequest {
            pid: Some(42),
            front_window_frame: Some(Frame::new(100.0, 200.0, 800.0, 240.0)),
            ..Default::default()
        };
        let response = hints_for_context(&plugin, &harness.context(), &request).await;
        let links: Vec<_> = response
            .targets
            .iter()
            .filter(|t| t.role.as_deref() == Some(TERMINAL_LINK_ROLE))
            .collect();
        assert_eq!(links.len(), 1);
        assert_eq!(links[0].label.as_deref(), Some("Read docs"));
        assert_eq!(links[0].url.as_deref(), Some("https://example.com/actual"));
        assert_eq!(links[0].frame, Frame::new(150.0, 430.0, 10.0, 10.0));
        fixture.cleanup().await;
    }

    #[tokio::test]
    async fn switching_or_resizing_during_capture_rejects_hint_and_text_grids() {
        for changed in [
            "80 24 0 0|||off top on 0|||123 $0 @2||||||",
            "79 24 0 0|||off top on 0|||123 $0 @1||||||",
        ] {
            let fixture = ExecutableFixture::new().await;
            let marker = shell_quote(fixture.0.join("captured").to_str().unwrap());
            let binary = fixture.script("tmux", &format!(r#"case "$1" in
display-message) if test -f {marker}; then printf '%s\n' '{changed}'; else printf '%s\n' '80 24 0 0|||off top on 0|||123 $0 @1||||||'; fi ;;
list-panes) printf '%s\n' '%1 0 0 80 24 off 0|||123 $0 @1' ;;
capture-pane) touch {marker}; printf 'https://example.com\n' ;;
*) exit 1 ;;
esac"#)).await;
            let plugin = Tmux::default();
            plugin.tmux_path.set(Some(binary)).unwrap();
            plugin.client_snapshot().lock().unwrap().clients =
                vec![client("/dev/ttys000", "work", 42, 0)];
            let harness = flash_plugin::testing::Harness::new("tmux");
            let request = HintsRequest {
                pid: Some(42),
                front_window_frame: Some(Frame::new(0.0, 0.0, 800.0, 240.0)),
                ..Default::default()
            };
            assert!(
                hints_for_context(&plugin, &harness.context(), &request)
                    .await
                    .targets
                    .is_empty()
            );
            tokio::fs::remove_file(fixture.0.join("captured"))
                .await
                .unwrap();
            let grid = text_grid_for_context(
                &plugin,
                &harness.context(),
                &TextGridRequest {
                    pid: Some(42),
                    ..Default::default()
                },
            )
            .await;
            assert_eq!(grid, TextGridResponse::default());
            fixture.cleanup().await;
        }
    }

    #[test]
    fn zoom_and_copy_mode_never_publish_the_hidden_base_grid() {
        let combined = "80 24 0 0|||off top on 0|||123 $0 @1||||||";
        let pane = "%1 0 0 80 24 off 0|||123 $0 @1";
        assert!(ClientLayout::parse(combined, pane).is_some());
        assert!(
            ClientLayout::parse(&combined.replace("off top on 0", "off top on 1"), pane).is_none()
        );
        assert!(ClientLayout::parse(combined, &pane.replace("off 0|||", "off 1|||")).is_none());
        assert!(ClientLayout::parse(combined, &pane.replace("off 0|||", "off 2|||")).is_none());
        assert!(
            ClientLayout::parse(&combined.replace("off top on 0", "off top on"), pane).is_none()
        );
    }

    #[test]
    fn status_tab_hints_require_one_visible_mouse_enabled_row() {
        assert_eq!(status_hint_row("on top on", 25), Some(0));
        assert_eq!(status_hint_row("1 bottom 1", 25), Some(24));
        for status in [
            "off top on",
            "0 bottom 1",
            "2 top on",
            "on top off",
            "on bottom 0",
            "on top",
            "on unknown on",
        ] {
            assert_eq!(status_hint_row(status, 25), None, "{status}");
        }
        assert_eq!(status_hint_row("on top on", 0), None);
    }

    #[test]
    fn only_link_targets_use_link_semantics() {
        let pane = build_target(
            "pane",
            0.0,
            0.0,
            10.0,
            10.0,
            PANE_TARGET_ROLE,
            "%1",
            42,
            Priority::Urgent,
        );
        let link = build_target(
            "link",
            0.0,
            0.0,
            10.0,
            10.0,
            TERMINAL_LINK_ROLE,
            "example.com",
            42,
            Priority::Normal,
        );

        // A pane is terminal content, a link is navigation; neither says
        // anything about the mode, which a click never changes.
        assert_eq!(pane.role.as_deref(), Some("tmux-pane"));
        assert_eq!(pane.url, None);
        assert_eq!(link.role.as_deref(), Some("FlashTerminalLink"));
    }

    #[test]
    fn tmux_http_links_publish_their_click_url() {
        for label in [
            "https://example.com/page",
            "http://example.com/page",
            "src/main.rs",
        ] {
            let target = build_target(
                "link",
                0.0,
                0.0,
                10.0,
                10.0,
                TERMINAL_LINK_ROLE,
                label,
                42,
                Priority::Normal,
            );
            assert_eq!(target.url.as_deref(), is_url(label).then_some(label));
        }
    }

    #[test]
    fn hint_context_separates_reused_pane_ids_across_live_contexts() {
        let mut client = client("/dev/ttys000", "work", 42, 0);
        let initial = HintContext::parse("123 $0 @1").unwrap();
        let original = initial.target_id(&client, "%1");
        for raw in ["124 $0 @1", "123 $1 @1", "123 $0 @2"] {
            assert_ne!(
                original,
                HintContext::parse(raw).unwrap().target_id(&client, "%1")
            );
        }
        assert_ne!(original, initial.target_id(&client, "%2"));
        client.tty = "/dev/ttys001".to_string();
        assert_ne!(original, initial.target_id(&client, "%1"));
        client.tty = "/dev/ttys000".to_string();
        client.backend_id = "remote:work".to_string();
        assert_ne!(original, initial.target_id(&client, "%1"));
    }

    #[test]
    fn hint_context_rejects_a_window_switch_between_geometry_and_pane_replies() {
        let context = HintContext::parse("123 $0 @1").unwrap();
        let pane = parse_hint_pane("%1 0 0 80 24 off 0|||123 $0 @1", &context).unwrap();
        assert_eq!(pane.id, "%1");
        assert!(parse_hint_pane("%1 0 0 80 24 off 0|||123 $0 @2", &context).is_none());
        for invalid in ["", "0 $0 @1", "123 work @1", "123 $0 1", "123 $0 @1 extra"] {
            assert!(HintContext::parse(invalid).is_none(), "{invalid}");
        }
    }
}
