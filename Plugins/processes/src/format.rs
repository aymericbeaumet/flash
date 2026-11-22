//! How the process values read as text: the top tables and the focused
//! app's summary. Focused details have bold headings; every external name is
//! escaped, so it cannot open a style marker or break a row.

use flash_plugin::status::{bytes_iec, duration_uptime};

use crate::table::{Process, Tree};

/// `top_count`: rows per table.
pub(crate) const TOP_COUNT_MIN: usize = 1;
pub(crate) const TOP_COUNT_MAX: usize = 20;
pub(crate) const TOP_COUNT_DEFAULT: usize = 5;
/// Visible width of the name column, conky's `top_name_width` default.
const NAME_WIDTH: usize = 15;
/// Width of a `focused_app_details` row label.
const LABEL_WIDTH: usize = 14;
/// Width of a helper's name in the focused app's table.
const HELPER_NAME_WIDTH: usize = 24;
/// Helpers listed under the focused app.
const HELPER_ROWS: usize = 5;

pub(crate) const COLLECTING: &str = "Collecting metrics…";
pub(crate) const UNAVAILABLE: &str = "Metrics unavailable";

/// One of the two tables.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum TopKind {
    /// The busiest processes by CPU.
    Cpu,
    /// The busiest processes by resident memory.
    Memory,
}

/// The app whose process tree `focused_app_details` shows.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct FocusedApp {
    pub(crate) pid: i32,
    pub(crate) bundle_id: String,
}

/// What the app says about itself, read once per process identity.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct Metadata {
    pub(crate) name: String,
    pub(crate) version: String,
    pub(crate) bundle_path: String,
    pub(crate) executable_path: String,
}

/// `#` doubled: the status language reads `##` as one literal `#`.
pub(crate) fn escaped(text: &str) -> String {
    text.replace('#', "##")
}

/// A control character or a line or paragraph separator cannot break a row.
fn one_line(text: &str) -> String {
    text.chars()
        .map(|character| {
            if character.is_control() || matches!(character, '\u{2028}' | '\u{2029}') {
                '?'
            } else {
                character
            }
        })
        .collect()
}

fn padded(text: &str, width: usize) -> String {
    let length = text.chars().count();
    format!("{text}{}", " ".repeat(width.saturating_sub(length)))
}

fn right(text: &str, width: usize) -> String {
    let length = text.chars().count();
    format!("{}{text}", " ".repeat(width.saturating_sub(length)))
}

/// A process name as one table cell: a control character cannot break the
/// row, a name wider than the column ends in an ellipsis, and a nameless
/// process shows its pid.
fn cell_name(process: &Process, width: usize) -> String {
    let name = one_line(process.name.trim());
    if name.is_empty() {
        return format!("[{}]", process.pid);
    }
    if name.chars().count() <= width {
        return name;
    }
    let mut cut: String = name.chars().take(width - 1).collect();
    cut.push('…');
    cut
}

/// The `count` busiest processes as an aligned two-column table: the name
/// padded to a fixed width, the value right-aligned. Busiest first; ties
/// break by name, then pid, so equal figures never shuffle rows. Empty when
/// there are no processes.
pub(crate) fn top_table(kind: TopKind, processes: &[Process], count: usize) -> String {
    let mut ranked: Vec<&Process> = processes.iter().collect();
    ranked.sort_by(|left, right| {
        let by_value = match kind {
            TopKind::Cpu => right.cpu_percent.total_cmp(&left.cpu_percent),
            TopKind::Memory => right.resident_bytes.cmp(&left.resident_bytes),
        };
        by_value
            .then_with(|| left.name.as_bytes().cmp(right.name.as_bytes()))
            .then_with(|| left.pid.cmp(&right.pid))
    });
    ranked.truncate(count.clamp(TOP_COUNT_MIN, TOP_COUNT_MAX));
    if ranked.is_empty() {
        return String::new();
    }
    let figures: Vec<String> = ranked
        .iter()
        .map(|process| match kind {
            TopKind::Cpu => format!("{:.1}%", process.cpu_percent.max(0.0)),
            TopKind::Memory => bytes_iec(process.resident_bytes),
        })
        .collect();
    // The widest figure in ordinary use (`100.0%`, `1023 MiB`), so the value
    // column only widens for an outlier.
    let floor = match kind {
        TopKind::Cpu => 6,
        TopKind::Memory => 8,
    };
    let figure_width = figures
        .iter()
        .map(|figure| figure.chars().count())
        .fold(floor, usize::max);
    let lines: Vec<String> = ranked
        .iter()
        .zip(&figures)
        .map(|(process, figure)| {
            format!(
                "{}  {}",
                padded(&cell_name(process, NAME_WIDTH), NAME_WIDTH),
                right(figure, figure_width)
            )
        })
        .collect();
    escaped(&lines.join("\n"))
}

fn row(label: &str, value: &str) -> String {
    format!("{}{}", padded(label, LABEL_WIDTH), one_line(value))
}

fn heading(title: &str) -> String {
    format!("#[bold]{}#[nobold]", escaped(&one_line(title)))
}

fn identity_rows(app: &FocusedApp) -> Vec<String> {
    let bundle = app.bundle_id.trim();
    vec![
        row(
            "Bundle",
            if bundle.is_empty() {
                "Unavailable"
            } else {
                bundle
            },
        ),
        row("PID", &app.pid.to_string()),
    ]
}

/// A compact app summary; resource totals include the currently reachable
/// descendants, while uptime belongs to the main process alone.
pub(crate) fn focused_details(
    app: &FocusedApp,
    tree: &Tree,
    metadata: &Metadata,
    physical_memory: u64,
) -> String {
    let memory_percent = tree.resident_bytes as f64 / physical_memory.max(1) as f64 * 100.0;
    let title = if metadata.name.is_empty() {
        &tree.name
    } else {
        &metadata.name
    };
    let mut identity = identity_rows(app);
    if !metadata.version.is_empty() {
        identity.insert(0, row("Version", &metadata.version));
    }
    let resources = [
        row("CPU", &format!("{:.1}% · 100% = 1 core", tree.cpu_percent)),
        row(
            "Memory",
            &format!(
                "{} ({memory_percent:.1}% of RAM)",
                bytes_iec(tree.resident_bytes)
            ),
        ),
        row(
            "Processes",
            &format!("{} · {} threads", tree.process_count, tree.thread_count),
        ),
        row("Sockets", &tree.socket_count.to_string()),
        row(
            "Running",
            &format!("{} · main process", duration_uptime(tree.uptime_seconds)),
        ),
        row(
            "Disk read",
            &format!("{} cumulative", bytes_iec(tree.disk_read_bytes)),
        ),
        row(
            "Disk written",
            &format!("{} cumulative", bytes_iec(tree.disk_write_bytes)),
        ),
    ];
    let mut sections = vec![
        format!("{}\n{}", heading(title), escaped(&identity.join("\n"))),
        format!(
            "{}\n{}",
            heading("Resources · app + descendants"),
            escaped(&resources.join("\n"))
        ),
    ];
    if !tree.descendants.is_empty() {
        let mut helpers: Vec<&Process> = tree.descendants.iter().collect();
        helpers.sort_by(|left, right| {
            right
                .cpu_percent
                .total_cmp(&left.cpu_percent)
                .then_with(|| right.resident_bytes.cmp(&left.resident_bytes))
                .then_with(|| left.pid.cmp(&right.pid))
        });
        helpers.truncate(HELPER_ROWS);
        let mut lines = vec![format!(
            "{}{:>7} {:>8} {:>10}",
            padded("Process", HELPER_NAME_WIDTH),
            "PID",
            "CPU",
            "Memory"
        )];
        lines.extend(helpers.iter().map(|helper| {
            format!(
                "{}{:>7} {:>7.1}% {:>10}",
                padded(&cell_name(helper, HELPER_NAME_WIDTH), HELPER_NAME_WIDTH),
                helper.pid,
                helper.cpu_percent,
                bytes_iec(helper.resident_bytes)
            )
        }));
        sections.push(format!(
            "{}\n{}",
            heading(&format!(
                "Busiest helpers · {} of {}",
                helpers.len(),
                tree.descendants.len()
            )),
            escaped(&lines.join("\n"))
        ));
    }
    let paths: Vec<String> = [
        ("Bundle path", &metadata.bundle_path),
        ("Executable", &metadata.executable_path),
    ]
    .into_iter()
    .filter(|(_, path)| !path.is_empty())
    .map(|(label, path)| row(label, path))
    .collect();
    if !paths.is_empty() {
        sections.push(format!(
            "{}\n{}",
            heading("Application"),
            escaped(&paths.join("\n"))
        ));
    }
    sections.join("\n\n")
}

/// The app's identity over a state line, shown while its figures are being
/// read or when they cannot be: never another app's figures.
pub(crate) fn focused_placeholder(app: &FocusedApp, state: &str) -> String {
    let mut lines = identity_rows(app);
    lines.push(state.to_string());
    escaped(&lines.join("\n"))
}

#[cfg(test)]
mod tests {
    use super::*;

    const RAM: u64 = 32 << 30;

    fn process(pid: i32, name: &str, cpu_percent: f64, resident_bytes: u64) -> Process {
        Process {
            pid,
            name: name.into(),
            cpu_percent,
            resident_bytes,
            start_abstime: 0,
        }
    }

    fn tree(pid: i32, name: &str) -> Tree {
        Tree {
            pid,
            name: name.into(),
            cpu_percent: 0.0,
            resident_bytes: 0,
            process_count: 0,
            thread_count: 0,
            socket_count: 0,
            uptime_seconds: 0,
            disk_read_bytes: 0,
            disk_write_bytes: 0,
            start_abstime: 0,
            executable_path: String::new(),
            descendants: Vec::new(),
        }
    }

    fn app(pid: i32, bundle_id: &str) -> FocusedApp {
        FocusedApp {
            pid,
            bundle_id: bundle_id.into(),
        }
    }

    #[test]
    fn the_cpu_table_aligns_values_and_truncates_long_names() {
        let processes = [
            process(10, "WindowServer", 12.34, 0),
            process(11, "a-very-long-process-name", 3.0, 0),
            process(12, "kernel_task", 142.0, 0),
            process(13, "idle", 0.0, 0),
        ];
        assert_eq!(
            top_table(TopKind::Cpu, &processes, 3),
            "kernel_task      142.0%\n\
             WindowServer      12.3%\n\
             a-very-long-pr…    3.0%"
        );
    }

    #[test]
    fn the_memory_table_ranks_resident_bytes_and_breaks_ties_by_name() {
        let processes = [
            process(1, "beta", 0.0, 921_600),
            process(2, "Xcode", 0.0, 432_013_312),
            process(3, "firefox", 0.0, 1_610_612_736),
            process(4, "alpha", 0.0, 921_600),
        ];
        assert_eq!(
            top_table(TopKind::Memory, &processes, 5),
            "firefox           1.5 GiB\n\
             Xcode             412 MiB\n\
             alpha             900 KiB\n\
             beta              900 KiB"
        );
    }

    #[test]
    fn an_outlier_value_widens_the_value_column_for_every_row() {
        let processes = [process(1, "wide", 2345.6, 0), process(2, "idle", 0.0, 0)];
        assert_eq!(
            top_table(TopKind::Cpu, &processes, 5),
            "wide             2345.6%\nidle                0.0%"
        );
    }

    #[test]
    fn the_row_count_is_clamped_to_one_through_twenty() {
        let processes: Vec<Process> = (1..=25)
            .map(|pid| process(pid, &format!("p{pid}"), f64::from(pid), 0))
            .collect();
        let rows = |count| top_table(TopKind::Cpu, &processes, count).lines().count();
        assert_eq!(rows(5), 5);
        assert_eq!(rows(20), 20);
        assert_eq!(rows(50), 20);
        assert_eq!(rows(0), 1);
        assert_eq!(
            top_table(TopKind::Cpu, &processes[..2], 5).lines().count(),
            2
        );
        assert_eq!(top_table(TopKind::Cpu, &[], 5), "");
        assert_eq!(top_table(TopKind::Memory, &[], 5), "");
    }

    #[test]
    fn equal_figures_rank_by_name_then_pid() {
        let processes = [
            process(9, "zsh", 1.0, 0),
            process(3, "zsh", 1.0, 0),
            process(5, "Zed", 1.0, 0),
            process(7, "bash", 1.0, 0),
        ];
        let names: Vec<String> = top_table(TopKind::Cpu, &processes, 5)
            .lines()
            .map(|line| line.split_whitespace().next().unwrap().to_string())
            .collect();
        assert_eq!(names, ["Zed", "bash", "zsh", "zsh"], "bytewise, then pid");
        // A negative delta never shows as a negative share.
        assert_eq!(
            top_table(TopKind::Cpu, &[process(1, "clock", -0.4, 0)], 5),
            "clock              0.0%"
        );
    }

    #[test]
    fn external_names_cannot_open_markup_or_break_rows() {
        assert_eq!(
            top_table(TopKind::Cpu, &[process(1, "a#b", 0.0, 0)], 5),
            "a##b                0.0%"
        );
        assert_eq!(
            top_table(TopKind::Cpu, &[process(1, "bad\nname", 0.0, 0)], 5),
            "bad?name           0.0%"
        );
        assert_eq!(
            top_table(TopKind::Cpu, &[process(1, "bad\u{2028}name", 0.0, 0)], 5),
            "bad?name           0.0%"
        );
        // A nameless process shows its pid, in the same two columns.
        let nameless = top_table(TopKind::Cpu, &[process(77, "  ", 0.0, 0)], 5);
        assert_eq!(
            nameless.split_whitespace().collect::<Vec<_>>(),
            ["[77]", "0.0%"]
        );
        assert_eq!(nameless.len(), "a##b                0.0%".len() - 1);
    }

    #[test]
    fn focused_app_details_format_live_and_lifetime_figures() {
        let mut firefox = tree(4242, "firefox");
        firefox.cpu_percent = 12.5;
        firefox.resident_bytes = RAM / 16;
        firefox.process_count = 9;
        firefox.thread_count = 42;
        firefox.socket_count = 7;
        firefox.uptime_seconds = 7_384;
        firefox.disk_read_bytes = 536_870_912;
        firefox.disk_write_bytes = 67_108_864;
        assert_eq!(
            focused_details(
                &app(4242, "org.mozilla.firefox"),
                &firefox,
                &Metadata::default(),
                RAM
            ),
            "#[bold]firefox#[nobold]\n\
             Bundle        org.mozilla.firefox\n\
             PID           4242\n\
             \n\
             #[bold]Resources · app + descendants#[nobold]\n\
             CPU           12.5% · 100% = 1 core\n\
             Memory        2.0 GiB (6.2% of RAM)\n\
             Processes     9 · 42 threads\n\
             Sockets       7\n\
             Running       2h 3m · main process\n\
             Disk read     512 MiB cumulative\n\
             Disk written  64 MiB cumulative"
        );
    }

    #[test]
    fn focused_identity_cannot_inject_extra_rows_or_terminal_controls() {
        assert_eq!(
            focused_placeholder(&app(7, "com.example.#[bold]\n\u{1b}[31m"), UNAVAILABLE),
            "Bundle        com.example.##[bold]??[31m\nPID           7\nMetrics unavailable"
        );
    }

    #[test]
    fn focused_details_keep_application_metadata_literal_and_rank_only_five_helpers() {
        let mut editor = tree(42, "editor");
        editor.cpu_percent = 215.0;
        editor.resident_bytes = 1024;
        editor.process_count = 7;
        editor.thread_count = 12;
        editor.socket_count = 3;
        editor.uptime_seconds = 60;
        editor.disk_read_bytes = 4;
        editor.disk_write_bytes = 5;
        editor.descendants = vec![
            process(9, "slow", 1.0, 0),
            process(8, "busy", 30.0, 0),
            process(7, "tie-less-memory", 20.0, 1),
            process(6, "tie-low-pid", 20.0, 3),
            process(5, "zero", 0.0, 0),
            process(10, "tie-high-pid", 20.0, 3),
        ];
        let text = focused_details(
            &app(42, "com.example.Editor"),
            &editor,
            &Metadata {
                name: "Editor #[bold]\nTitle".into(),
                version: "2.1 (42)".into(),
                bundle_path: "/Applications/Editor.app".into(),
                executable_path: "/Applications/Editor.app/Contents/MacOS/editor".into(),
            },
            RAM,
        );
        assert_eq!(
            text,
            "#[bold]Editor ##[bold]?Title#[nobold]\n\
             Version       2.1 (42)\n\
             Bundle        com.example.Editor\n\
             PID           42\n\
             \n\
             #[bold]Resources · app + descendants#[nobold]\n\
             CPU           215.0% · 100% = 1 core\n\
             Memory        1.0 KiB (0.0% of RAM)\n\
             Processes     7 · 12 threads\n\
             Sockets       3\n\
             Running       1m · main process\n\
             Disk read     4 B cumulative\n\
             Disk written  5 B cumulative\n\
             \n\
             #[bold]Busiest helpers · 5 of 6#[nobold]\n\
             Process                     PID      CPU     Memory\n\
             busy                          8    30.0%        0 B\n\
             tie-low-pid                   6    20.0%        3 B\n\
             tie-high-pid                 10    20.0%        3 B\n\
             tie-less-memory               7    20.0%        1 B\n\
             slow                          9     1.0%        0 B\n\
             \n\
             #[bold]Application#[nobold]\n\
             Bundle path   /Applications/Editor.app\n\
             Executable    /Applications/Editor.app/Contents/MacOS/editor"
        );
    }

    #[test]
    fn the_focused_placeholder_never_shows_another_apps_figures_or_opens_markup() {
        assert_eq!(
            focused_placeholder(&app(99, "com.example.Editor"), COLLECTING),
            "Bundle        com.example.Editor\nPID           99\nCollecting metrics…"
        );
        assert_eq!(
            focused_placeholder(&app(7, "com.example.#[dev]"), UNAVAILABLE),
            "Bundle        com.example.##[dev]\nPID           7\nMetrics unavailable"
        );
        assert_eq!(
            focused_placeholder(&app(7, " "), UNAVAILABLE),
            "Bundle        Unavailable\nPID           7\nMetrics unavailable"
        );
    }

    #[test]
    fn units_are_the_status_formatters() {
        assert_eq!(bytes_iec(0), "0 B");
        assert_eq!(bytes_iec(1023), "1023 B");
        assert_eq!(bytes_iec(921_600), "900 KiB");
        assert_eq!(bytes_iec(1_610_612_736), "1.5 GiB");
        assert_eq!(duration_uptime(42), "42s");
        assert_eq!(duration_uptime(300), "5m");
        assert_eq!(duration_uptime(7_384), "2h 3m");
        assert_eq!(duration_uptime(93_600), "1d 2h");
    }
}
