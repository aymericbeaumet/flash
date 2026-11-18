//! The text grid for letter search: the focused client's cells as rows and
//! columns.

use flash_plugin::{Context, TextGridLine, TextGridRequest, TextGridResponse};

use crate::clients::focused_tmux_client;
use crate::hints::{
    ClientLayout, capture_panes, client_layout, parse_status_top_offset, status_format_row,
};
use crate::{Tmux, pane_capture, status_hints};

/// The focused client's cells for a letter search: the same client, layout
/// read and pane captures as `hints`, so both see one surface.
pub(crate) async fn text_grid_for_context(
    plugin: &Tmux,
    ctx: &Context,
    req: &TextGridRequest,
) -> TextGridResponse {
    let Some(pid) = req.pid else {
        return TextGridResponse::default();
    };
    let Some(client) = focused_tmux_client(plugin, ctx, pid, false).await else {
        return TextGridResponse::default();
    };
    let Some(layout) = client_layout(plugin, &client).await else {
        return TextGridResponse::default();
    };
    let captures = capture_panes(plugin, &client, &layout.panes).await;
    if client_layout(plugin, &client).await.as_ref() != Some(&layout) {
        return TextGridResponse::default();
    }
    text_grid(&layout, &captures)
}

/// Lay one client out as grid lines. The status line and each pane-border
/// title stay formats for the host to lay out; pane text is captured cells,
/// a pane's line `n` on client row `top_offset + pane_top + n`. Blank
/// lines carry no letter and are left out; cells outside the client are
/// dropped so every line stays on the grid.
fn text_grid(layout: &ClientLayout, captures: &[Option<String>]) -> TextGridResponse {
    let cell = |value: i64| u32::try_from(value).ok();
    let (Some(columns), Some(rows)) = (cell(layout.columns), cell(layout.rows)) else {
        return TextGridResponse::default();
    };
    let on_grid = |row: i64, column: i64| {
        (0..layout.rows).contains(&row) && (0..layout.columns).contains(&column)
    };
    let top_offset = parse_status_top_offset(&layout.status);
    let mut lines = Vec::new();
    if let Some(row) = status_format_row(&layout.status, layout.rows)
        && !layout.status_format.is_empty()
        && let Some(row) = cell(row)
    {
        lines.push(TextGridLine::format(row, 0, columns, &layout.status_format));
    }
    for (pane, capture) in layout.panes.iter().zip(captures) {
        if let Some(row) =
            status_hints::pane_title_row(&pane.border, top_offset, pane.top, pane.rows)
            && on_grid(row, pane.left)
            && !pane.title.is_empty()
            && let (Some(row), Some(column), Some(width)) = (
                cell(row),
                cell(pane.left),
                cell(pane.cols.min(layout.columns - pane.left)),
            )
        {
            lines.push(TextGridLine::format(row, column, width, &pane.title));
        }
        let Some(capture) = capture else {
            continue;
        };
        let Some(capture) = pane_capture::parse(capture, pane.cols as usize, pane.rows as usize)
        else {
            return TextGridResponse::default();
        };
        for (index, line) in capture.iter().enumerate() {
            let text = &line.text;
            let row = top_offset + pane.top + index as i64;
            if !on_grid(row, pane.left) {
                break;
            }
            if text.trim().is_empty() {
                continue;
            }
            if let (Some(row), Some(column)) = (cell(row), cell(pane.left)) {
                lines.push(TextGridLine::text(row, column, text));
            }
        }
    }
    TextGridResponse::new(columns, rows, lines)
}

#[cfg(test)]
mod tests {
    use super::*;

    use crate::links::captured_links;
    use crate::test_support::{ExecutableFixture, client};

    #[test]
    fn osc_spans_own_their_labels_and_text_grid_never_exposes_control_payloads() {
        let capture = "\x1b]52;c;secret\x07\x1b[4m\x1b]8;;https://actual.example\x07https://display.example\x1b]8;;\x1b\\ plain.txt\x1b[0m";
        let lines = pane_capture::parse(capture, 80, 1).unwrap();
        assert_eq!(
            captured_links(&lines[0], 80),
            vec![
                (
                    0,
                    "https://display.example".into(),
                    Some("https://actual.example".into())
                ),
                (24, "plain.txt".into(), None),
            ]
        );
        let unsafe_capture = capture.replace("https://actual.example", "file:///tmp/secret");
        let unsafe_lines = pane_capture::parse(&unsafe_capture, 80, 1).unwrap();
        assert_eq!(
            captured_links(&unsafe_lines[0], 80),
            vec![(24, "plain.txt".into(), None)]
        );
        let layout = ClientLayout::parse(
            "80 1 0 0|||off top on 0|||123 $0 @1||||||",
            "%1 0 0 80 1 off 0|||123 $0 @1",
        )
        .unwrap();
        assert_eq!(
            text_grid(&layout, &[Some(capture.into())]),
            TextGridResponse::new(
                80,
                1,
                vec![TextGridLine::text(
                    0,
                    0,
                    "https://display.example plain.txt"
                )]
            )
        );
    }

    #[tokio::test]
    async fn text_grid_reads_the_focused_client_it_hints() {
        let fixture = ExecutableFixture::new().await;
        let binary = fixture
            .script(
                "tmux",
                r#"case "$1" in
display-message) printf '%s\n' '20 6 0 0|||on top on 0|||123 $0 @1|||0 @1;|||#[fg=colour178 bold]za' ;;
list-panes) printf '%s\n' '%1 0 0 9 5 top 0|||123 $0 @1|||#[align=centre] t' '%2 10 0 10 5 off 0|||123 $0 @1|||' ;;
capture-pane) printf '%s\nb\n' "$3" ;;
*) exit 1 ;;
esac"#,
            )
            .await;
        let plugin = Tmux::default();
        plugin.tmux_path.set(Some(binary)).unwrap();
        plugin.client_snapshot().lock().unwrap().clients =
            vec![client("/dev/ttys000", "work", 42, 0)];
        let harness = flash_plugin::testing::Harness::new("tmux");
        let request = TextGridRequest {
            pid: Some(42),
            ..Default::default()
        };
        let grid = text_grid_for_context(&plugin, &harness.context(), &request).await;
        assert_eq!(
            grid,
            TextGridResponse::new(
                20,
                6,
                vec![
                    TextGridLine::format(0, 0, 20, "#[fg=colour178 bold]za"),
                    TextGridLine::format(0, 0, 9, "#[align=centre] t"),
                    TextGridLine::text(1, 0, "%1"),
                    TextGridLine::text(2, 0, "b"),
                    TextGridLine::text(1, 10, "%2"),
                    TextGridLine::text(2, 10, "b"),
                ],
            )
        );
        assert_eq!(
            text_grid_for_context(&plugin, &harness.context(), &TextGridRequest::default()).await,
            TextGridResponse::default()
        );
        fixture.cleanup().await;
    }

    #[test]
    fn text_grid_rows_follow_the_status_line_and_pane_border_titles() {
        let top = ClientLayout::parse(
            "20 6 0 0|||on top on 0|||123 $0 @1|||0 @1;|||#[fg=colour178 bold]za",
            "%7 10 1 9 4 top 0|||123 $0 @1|||#[align=centre] a\n\
             %8 0 1 9 4 off 0|||123 $0 @1|||#[align=left]hidden",
        )
        .unwrap();
        assert_eq!(
            text_grid(&top, &[Some("xa\n\n  \nb\n".into()), Some("left\n".into())]),
            TextGridResponse::new(
                20,
                6,
                vec![
                    // A top status sits on row 0 and pushes every pane down.
                    TextGridLine::format(0, 0, 20, "#[fg=colour178 bold]za"),
                    // A top border is the row above the pane's content.
                    TextGridLine::format(1, 10, 9, "#[align=centre] a"),
                    TextGridLine::text(2, 10, "xa"),
                    TextGridLine::text(5, 10, "b"),
                    TextGridLine::text(2, 0, "left"),
                ],
            )
        );

        let bottom = ClientLayout::parse(
            "9 5 0 0|||on bottom on 0|||123 $0 @1||||||#[align=left]s",
            "%1 0 0 9 3 bottom 0|||123 $0 @1|||#[align=left]t",
        )
        .unwrap();
        assert_eq!(
            text_grid(&bottom, &[Some("a\nb\nc\n".into())]),
            TextGridResponse::new(
                9,
                5,
                vec![
                    // A bottom status is the last row; a bottom border the
                    // row after the pane, which shows only its own rows.
                    TextGridLine::format(4, 0, 9, "#[align=left]s"),
                    TextGridLine::format(3, 0, 9, "#[align=left]t"),
                    TextGridLine::text(0, 0, "a"),
                    TextGridLine::text(1, 0, "b"),
                    TextGridLine::text(2, 0, "c"),
                ],
            )
        );
        assert_eq!(
            text_grid(&bottom, &[Some("a\nb\nc\nd\n".into())]),
            TextGridResponse::default()
        );
        assert_eq!(status_format_row("2 bottom on", 10), Some(8));
        assert_eq!(status_format_row("off top on", 10), None);
        assert_eq!(status_format_row("on left on", 10), None);
    }

    /// A window larger than its client keeps every line on the client's
    /// grid: a title is cut at the right edge, rows below it are dropped.
    #[test]
    fn text_grid_lines_stay_on_the_client_grid() {
        let layout = ClientLayout::parse(
            "10 3 0 0|||off top on 0|||123 $0 @1||||||",
            "%1 5 0 9 4 bottom 0|||123 $0 @1|||t",
        )
        .unwrap();
        assert_eq!(
            text_grid(&layout, &[Some("a\nb\nc\nd\n".into())]),
            TextGridResponse::new(
                10,
                3,
                vec![
                    TextGridLine::text(0, 5, "a"),
                    TextGridLine::text(1, 5, "b"),
                    TextGridLine::text(2, 5, "c"),
                ],
            )
        );
        let wide = ClientLayout::parse(
            "10 6 0 0|||off top on 0|||123 $0 @1||||||",
            "%1 5 0 9 4 bottom 0|||123 $0 @1|||t",
        )
        .unwrap();
        assert_eq!(
            text_grid(&wide, &[None]).lines,
            vec![TextGridLine::format(4, 5, 5, "t")]
        );
        assert!(ClientLayout::parse("10 6 0 0|||off top on 0|||123 $0 @1||||||", "").is_none());
    }
}
