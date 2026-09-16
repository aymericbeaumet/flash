//! Status-bar values and their hover previews.
//!
//! A status segment travels the wire as one string. [`StatusValue`] owns the
//! visible bar text as [`Markup`] plus an optional [`Preview`] document the
//! host shows on hover; [`StatusValue::render`] folds both into the
//! `#[popup=inline:…]visible#[nopopup]` form and enforces the host's marker
//! limit. Literal text enters a value through [`Markup::text`], which doubles
//! `#` so external strings can never open a marker; [`Markup::raw`] is for
//! intentional markup. The formatting helpers reproduce the bundled monitors'
//! byte-exact labels so every plugin renders the same figures the same way.

use std::borrow::Borrow;
use std::fmt;
use std::ops::{Add, AddAssign};

/// The host rejects an inline preview whose percent-encoded body exceeds this
/// many bytes (`StatusFormatDocument`).
pub const MAX_INLINE_PREVIEW_ENCODED_BYTES: usize = 16_384;

// ---------------------------------------------------------------------------
// Colours and styles
// ---------------------------------------------------------------------------

/// A tmux-style colour word.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Color {
    Default,
    /// 256-colour palette index (`colour245`).
    Palette(u8),
    /// 24-bit `#RRGGBB`.
    Rgb(u32),
}

impl Color {
    /// Section titles and metric names (yellow).
    pub const TITLE: Color = Color::Rgb(0xEBCB8B);
    /// Secondary text: row labels, table headers, metric values.
    pub const MUTED: Color = Color::Palette(245);
    /// Emphasised headings and outbound links.
    pub const ACCENT: Color = Color::Palette(178);
    /// Exhausted or critical values.
    pub const ALERT: Color = Color::Palette(196);
    /// Values trending toward a limit.
    pub const WARN: Color = Color::Rgb(0xD0_8770);
    /// Inbound transfer (download, disk read) arrows and rates.
    pub const INBOUND: Color = Color::Palette(39);
    /// Outbound transfer (upload, disk write) arrows and rates.
    pub const OUTBOUND: Color = Color::Palette(214);
}

impl fmt::Display for Color {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Color::Default => f.write_str("default"),
            Color::Palette(index) => write!(f, "colour{index}"),
            Color::Rgb(rgb) => write!(f, "#{:06X}", rgb & 0x00FF_FFFF),
        }
    }
}

/// Foreground colour plus attributes, rendered as one `#[…]` marker.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct Style {
    pub fg: Option<Color>,
    pub bold: bool,
    pub italics: bool,
    pub dim: bool,
}

impl Style {
    pub fn fg(color: Color) -> Self {
        Self {
            fg: Some(color),
            ..Self::default()
        }
    }

    pub fn bold(mut self) -> Self {
        self.bold = true;
        self
    }

    pub fn italics(mut self) -> Self {
        self.italics = true;
        self
    }

    pub fn dim(mut self) -> Self {
        self.dim = true;
        self
    }

    pub fn is_empty(&self) -> bool {
        self.fg.is_none() && !self.bold && !self.italics && !self.dim
    }
}

impl fmt::Display for Style {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let mut separator = "";
        if let Some(fg) = self.fg {
            write!(f, "fg={fg}")?;
            separator = ",";
        }
        for (enabled, name) in [
            (self.bold, "bold"),
            (self.italics, "italics"),
            (self.dim, "dim"),
        ] {
            if enabled {
                write!(f, "{separator}{name}")?;
                separator = ",";
            }
        }
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Markup
// ---------------------------------------------------------------------------

/// Rich status text in the host's marker language.
///
/// Construct literal text with [`Markup::text`] (escaped) and intentional
/// markers with [`Markup::raw`]. The `From<&str>`/`From<String>` conversions
/// are raw: they exist so a plugin can hand a ready-made value straight to
/// `Context::status`, not to smuggle external text past escaping.
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash)]
pub struct Markup(String);

impl Markup {
    pub fn new() -> Self {
        Self::default()
    }

    /// Literal text: every `#` becomes `##` so it can never open a marker.
    pub fn text(text: impl AsRef<str>) -> Self {
        Self(text.as_ref().replace('#', "##"))
    }

    /// Intentional markup inserted verbatim.
    pub fn raw(markup: impl Into<String>) -> Self {
        Self(markup.into())
    }

    /// `#[<style>]content#[default]`; an empty style returns `content` as is.
    pub fn styled(content: impl Into<Markup>, style: Style) -> Self {
        let content = content.into();
        if style.is_empty() {
            return content;
        }
        Self(format!("#[{style}]{content}#[default]"))
    }

    /// `#[fg=<color>]content#[default]`.
    pub fn colored(content: impl Into<Markup>, color: Color) -> Self {
        Self::styled(content, Style::fg(color))
    }

    /// `#[link=URL]label#[nolink]`, escaping the marker delimiters `[`, `]`
    /// and `,` inside the URL.
    pub fn link(label: impl Into<Markup>, url: &str) -> Self {
        Self(format!(
            "#[link={}]{}#[nolink]",
            marker_url(url),
            label.into()
        ))
    }

    /// `#[range=user|name]label#[norange]`, selecting a `[statusbar.click]`
    /// action.
    pub fn range(label: impl Into<Markup>, name: &str) -> Self {
        Self(format!("#[range=user|{name}]{}#[norange]", label.into()))
    }

    pub fn push(&mut self, other: impl Into<Markup>) {
        self.0.push_str(&other.into().0);
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub fn into_string(self) -> String {
        self.0
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    /// The text a reader sees: `#[…]` markers removed and `##` unescaped.
    pub fn plain(&self) -> String {
        let mut plain = String::with_capacity(self.0.len());
        let mut chars = self.0.chars().peekable();
        while let Some(ch) = chars.next() {
            if ch != '#' {
                plain.push(ch);
                continue;
            }
            match chars.peek() {
                Some('#') => {
                    chars.next();
                    plain.push('#');
                }
                Some('[') => {
                    chars.next();
                    for ch in chars.by_ref() {
                        if ch == ']' {
                            break;
                        }
                    }
                }
                _ => plain.push('#'),
            }
        }
        plain
    }
}

fn marker_url(url: &str) -> String {
    url.replace('[', "%5B")
        .replace(']', "%5D")
        .replace(',', "%2C")
}

impl fmt::Display for Markup {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl From<&str> for Markup {
    fn from(markup: &str) -> Self {
        Self::raw(markup)
    }
}

impl From<&String> for Markup {
    fn from(markup: &String) -> Self {
        Self::raw(markup.as_str())
    }
}

impl From<String> for Markup {
    fn from(markup: String) -> Self {
        Self::raw(markup)
    }
}

impl From<Markup> for String {
    fn from(markup: Markup) -> Self {
        markup.0
    }
}

impl<T: Into<Markup>> Add<T> for Markup {
    type Output = Markup;

    fn add(mut self, other: T) -> Self::Output {
        self.push(other);
        self
    }
}

impl<T: Into<Markup>> AddAssign<T> for Markup {
    fn add_assign(&mut self, other: T) {
        self.push(other);
    }
}

// ---------------------------------------------------------------------------
// Preview document
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Align {
    Left,
    Right,
}

/// One [`Table`] column: a header title, a cell width in visible characters,
/// and its alignment.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Column {
    title: String,
    width: usize,
    align: Align,
}

impl Column {
    pub fn new(title: impl Into<String>, width: usize) -> Self {
        Self {
            title: title.into(),
            width,
            align: Align::Left,
        }
    }

    pub fn right(mut self) -> Self {
        self.align = Align::Right;
        self
    }

    fn pad(&self, cell: &Markup, last: bool) -> String {
        let padding = self.width.saturating_sub(cell.plain().chars().count());
        match self.align {
            Align::Left if last => cell.0.clone(),
            Align::Left => format!("{cell}{}", " ".repeat(padding)),
            Align::Right => format!("{}{cell}", " ".repeat(padding)),
        }
    }
}

/// Fixed-width columns with a muted header row. Cells are padded by their
/// visible width, so styled cells stay aligned.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Table {
    columns: Vec<Column>,
    rows: Vec<Vec<Markup>>,
}

impl Table {
    pub fn new(columns: impl IntoIterator<Item = Column>) -> Self {
        Self {
            columns: columns.into_iter().collect(),
            rows: Vec::new(),
        }
    }

    /// Append one row; missing cells render empty, surplus cells are dropped.
    pub fn row<I, M>(mut self, cells: I) -> Self
    where
        I: IntoIterator<Item = M>,
        M: Into<Markup>,
    {
        self.rows.push(cells.into_iter().map(Into::into).collect());
        self
    }

    fn render_lines(&self) -> Vec<String> {
        let last = self.columns.len().saturating_sub(1);
        let mut lines = Vec::with_capacity(self.rows.len() + 1);
        if self.columns.iter().any(|column| !column.title.is_empty()) {
            let header = self
                .columns
                .iter()
                .enumerate()
                .map(|(index, column)| column.pad(&Markup::text(&column.title), index == last))
                .collect::<Vec<_>>()
                .join("  ");
            lines.push(Markup::colored(Markup::raw(header), Color::MUTED).0);
        }
        for row in &self.rows {
            let cells = self
                .columns
                .iter()
                .enumerate()
                .map(|(index, column)| {
                    let cell = row.get(index).cloned().unwrap_or_default();
                    column.pad(&cell, index == last)
                })
                .collect::<Vec<_>>()
                .join("  ");
            lines.push(cells);
        }
        lines
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum Line {
    Title(Markup),
    Note(Markup),
    Section(Markup),
    Row { label: String, value: Markup },
    Blank,
    Table(Table),
    Raw(Markup),
}

/// The hover document behind a status segment, built line by line and
/// rendered once into [`Markup`].
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Preview {
    lines: Vec<Line>,
    label_width: usize,
}

impl Default for Preview {
    fn default() -> Self {
        Self {
            lines: Vec::new(),
            label_width: Self::DEFAULT_LABEL_WIDTH,
        }
    }
}

impl Preview {
    /// Visible width of a [`Preview::row`] label column.
    pub const DEFAULT_LABEL_WIDTH: usize = 14;

    pub fn new() -> Self {
        Self::default()
    }

    /// A preview whose body is already formatted (one [`Preview::raw`] line).
    pub fn from_markup(body: impl Into<Markup>) -> Self {
        Self::new().raw(body)
    }

    /// Pad row labels to `width` visible characters instead of the default.
    pub fn label_width(mut self, width: usize) -> Self {
        self.label_width = width;
        self
    }

    /// `#[fg=#EBCB8B]title#[default]`.
    pub fn title(self, title: impl Into<Markup>) -> Self {
        self.line(Line::Title(title.into()))
    }

    /// A muted explanatory line.
    pub fn note(self, note: impl Into<Markup>) -> Self {
        self.line(Line::Note(note.into()))
    }

    /// A bold sub-heading.
    pub fn section(self, heading: impl Into<Markup>) -> Self {
        self.line(Line::Section(heading.into()))
    }

    /// `#[fg=colour245]label(padded)#[default]value`; the label is literal
    /// text.
    pub fn row(self, label: impl Into<String>, value: impl Into<Markup>) -> Self {
        self.line(Line::Row {
            label: label.into(),
            value: value.into(),
        })
    }

    pub fn blank(self) -> Self {
        self.line(Line::Blank)
    }

    pub fn table(self, table: Table) -> Self {
        self.line(Line::Table(table))
    }

    /// A line inserted verbatim.
    pub fn raw(self, line: impl Into<Markup>) -> Self {
        self.line(Line::Raw(line.into()))
    }

    fn line(mut self, line: Line) -> Self {
        self.lines.push(line);
        self
    }

    pub fn is_empty(&self) -> bool {
        self.lines.is_empty()
    }

    /// Lines joined by newlines, without a trailing newline.
    pub fn render(&self) -> Markup {
        let mut lines = Vec::with_capacity(self.lines.len());
        for line in &self.lines {
            match line {
                Line::Title(title) => lines.push(Markup::colored(title.clone(), Color::TITLE).0),
                Line::Note(note) => lines.push(Markup::colored(note.clone(), Color::MUTED).0),
                Line::Section(heading) => {
                    lines.push(Markup::styled(heading.clone(), Style::default().bold()).0)
                }
                Line::Row { label, value } => {
                    lines.push(render_row(label, value, self.label_width))
                }
                Line::Blank => lines.push(String::new()),
                Line::Table(table) => lines.extend(table.render_lines()),
                Line::Raw(raw) => lines.push(raw.0.clone()),
            }
        }
        Markup(lines.join("\n"))
    }

    /// [`Preview::render`] with markers stripped, for plain command replies.
    pub fn render_plain(&self) -> String {
        self.render().plain()
    }
}

fn render_row(label: &str, value: &Markup, width: usize) -> String {
    let padding = width.saturating_sub(label.chars().count());
    let label = Markup::raw(format!("{}{}", Markup::text(label), " ".repeat(padding)));
    format!("{}{value}", Markup::colored(label, Color::MUTED))
}

// ---------------------------------------------------------------------------
// Status values
// ---------------------------------------------------------------------------

/// The percent-encoded preview would exceed
/// [`MAX_INLINE_PREVIEW_ENCODED_BYTES`]; the host would drop the marker.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PreviewTooLarge {
    pub encoded_bytes: usize,
}

impl fmt::Display for PreviewTooLarge {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "status preview encodes to {} bytes; the host accepts at most {}",
            self.encoded_bytes, MAX_INLINE_PREVIEW_ENCODED_BYTES
        )
    }
}

impl std::error::Error for PreviewTooLarge {}

/// One status segment: the visible bar text and its optional hover preview.
/// An empty visible value clears the segment host-side.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct StatusValue {
    pub visible: Markup,
    pub preview: Option<Preview>,
}

impl StatusValue {
    pub fn text(visible: impl Into<Markup>) -> Self {
        Self {
            visible: visible.into(),
            preview: None,
        }
    }

    /// Clears the segment.
    pub fn empty() -> Self {
        Self::default()
    }

    pub fn with_preview(mut self, preview: Preview) -> Self {
        self.preview = Some(preview);
        self
    }

    /// The wire string: the visible text alone, or
    /// `#[popup=inline:<encoded preview>]visible#[nopopup]` when a non-empty
    /// preview fits the host's limit.
    pub fn render(&self) -> Result<String, PreviewTooLarge> {
        let body = self
            .preview
            .as_ref()
            .map(Preview::render)
            .filter(|body| !body.is_empty());
        let Some(body) = body else {
            return Ok(self.visible.0.clone());
        };
        let encoded = percent_encode(body.as_str());
        if encoded.len() > MAX_INLINE_PREVIEW_ENCODED_BYTES {
            return Err(PreviewTooLarge {
                encoded_bytes: encoded.len(),
            });
        }
        Ok(format!(
            "#[popup=inline:{encoded}]{}#[nopopup]",
            self.visible
        ))
    }
}

impl From<&str> for StatusValue {
    fn from(visible: &str) -> Self {
        Self::text(visible)
    }
}

impl From<&String> for StatusValue {
    fn from(visible: &String) -> Self {
        Self::text(visible)
    }
}

impl From<String> for StatusValue {
    fn from(visible: String) -> Self {
        Self::text(visible)
    }
}

impl From<Markup> for StatusValue {
    fn from(visible: Markup) -> Self {
        Self::text(visible)
    }
}

/// RFC 3986 unreserved bytes pass through; every other UTF-8 byte becomes
/// uppercase `%XX`, so markup, newlines and non-ASCII text survive the
/// `#[popup=inline:…]` marker byte for byte.
fn percent_encode(body: &str) -> String {
    const HEX: &[u8; 16] = b"0123456789ABCDEF";
    let mut encoded = String::with_capacity(body.len());
    for byte in body.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b'~') {
            encoded.push(char::from(byte));
        } else {
            encoded.push('%');
            encoded.push(char::from(HEX[usize::from(byte >> 4)]));
            encoded.push(char::from(HEX[usize::from(byte & 0x0f)]));
        }
    }
    encoded
}

// ---------------------------------------------------------------------------
// Publish-if-changed and bounded history
// ---------------------------------------------------------------------------

/// Remembers the last published value so unchanged renders stay off the wire.
#[derive(Clone, Debug)]
pub struct Published<T> {
    last: Option<T>,
}

impl<T> Default for Published<T> {
    fn default() -> Self {
        Self { last: None }
    }
}

impl<T: PartialEq> Published<T> {
    pub fn new() -> Self {
        Self::default()
    }

    /// Store `next` and return it when it differs from the last stored value.
    pub fn update(&mut self, next: T) -> Option<&T> {
        if self.last.as_ref() == Some(&next) {
            return None;
        }
        self.last = Some(next);
        self.last.as_ref()
    }

    pub fn last(&self) -> Option<&T> {
        self.last.as_ref()
    }

    /// Forget the last value so the next update publishes unconditionally.
    pub fn reset(&mut self) {
        self.last = None;
    }
}

/// The newest `N` samples of a metric, oldest first.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct History<const N: usize> {
    samples: Vec<f64>,
}

impl<const N: usize> History<N> {
    pub const CAPACITY: usize = N;

    pub fn new() -> Self {
        Self::default()
    }

    /// Append a sample, dropping the oldest beyond `N`.
    pub fn push(&mut self, value: f64) {
        if self.samples.len() == N {
            self.samples.remove(0);
        }
        self.samples.push(value);
    }

    pub fn iter(&self) -> std::iter::Copied<std::slice::Iter<'_, f64>> {
        self.samples.iter().copied()
    }

    pub fn as_slice(&self) -> &[f64] {
        &self.samples
    }

    pub fn len(&self) -> usize {
        self.samples.len()
    }

    pub fn is_empty(&self) -> bool {
        self.samples.is_empty()
    }

    pub fn clear(&mut self) {
        self.samples.clear();
    }
}

impl<'a, const N: usize> IntoIterator for &'a History<N> {
    type Item = f64;
    type IntoIter = std::iter::Copied<std::slice::Iter<'a, f64>>;

    fn into_iter(self) -> Self::IntoIter {
        self.iter()
    }
}

// ---------------------------------------------------------------------------
// Formatting helpers
// ---------------------------------------------------------------------------

const IEC_UNITS: [&str; 6] = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"];
const BARS: [char; 8] = ['▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'];

fn scaled_iec(bytes: f64, separator: &str) -> String {
    let mut value = bytes.max(0.0);
    let mut unit = 0;
    while value >= 1024.0 && unit < IEC_UNITS.len() - 1 {
        value /= 1024.0;
        unit += 1;
    }
    let number = if unit == 0 || value >= 10.0 {
        format!("{value:.0}")
    } else {
        format!("{value:.1}")
    };
    format!("{number}{separator}{}", IEC_UNITS[unit])
}

/// Binary units with a space: `900 KiB`, `1.5 GiB`.
pub fn bytes_iec(bytes: u64) -> String {
    scaled_iec(bytes as f64, " ")
}

/// Binary units without a space, for bar summaries: `1.5GiB`.
pub fn bytes_iec_compact(bytes: f64) -> String {
    scaled_iec(bytes, "")
}

/// Binary rate: `1.5 MiB/s`.
pub fn rate_iec(bytes_per_second: f64) -> String {
    format!("{}/s", scaled_iec(bytes_per_second, " "))
}

/// Decimal rate in exactly four cells for bar labels: `  0B`, ` 12K`, `1.2M`,
/// saturating at `999P`.
pub fn rate_cells4(bytes_per_second: f64) -> String {
    const UNITS: [char; 6] = ['B', 'K', 'M', 'G', 'T', 'P'];
    let mut value = bytes_per_second.max(0.0);
    let mut unit = 0;
    while value >= 999.5 && unit < UNITS.len() - 1 {
        value /= 1000.0;
        unit += 1;
    }
    if unit > 0 && value < 9.95 {
        format!("{value:>3.1}{}", UNITS[unit])
    } else {
        format!("{:>3.0}{}", value.min(999.0), UNITS[unit])
    }
}

/// Two-digit percentage capped at 99 so bar labels keep their width:
/// ` 9%`, `10%`, `99%`.
///
/// For a FAST metric the cap is the honest trade: CPU and network readings
/// cross 100 for a single sample constantly, and a label that widens for one
/// tick shifts every run beside it. A slow metric should use [`percent`],
/// which reads true and is allowed to change width because it rarely does.
pub fn percent2(value: f64) -> String {
    let value = if value > 0.0 { value.min(99.0) } else { 0.0 };
    format!("{value:>2.0}%")
}

/// Unpadded percentage that reaches 100: `9%`, `16%`, `100%`. For a slow
/// metric such as battery charge the reading should be true and plain; it
/// crosses a width boundary so rarely that padding it would cost a column on
/// every render to spare one shift a day.
pub fn percent(value: f64) -> String {
    let value = if value > 0.0 { value.min(100.0) } else { 0.0 };
    format!("{value:.0}%")
}

/// One bar per sample on a fixed 0–100 scale (rounded).
pub fn sparkline_percent<I>(values: I) -> String
where
    I: IntoIterator,
    I::Item: Borrow<f64>,
{
    values
        .into_iter()
        .map(|value| {
            let index = (value.borrow().clamp(0.0, 100.0) / 100.0 * 7.0).round() as usize;
            BARS[index.min(BARS.len() - 1)]
        })
        .collect()
}

/// One bar per sample scaled to the window maximum (floored); an all-zero
/// window is flat.
pub fn sparkline_scaled<I>(values: I) -> String
where
    I: IntoIterator,
    I::Item: Borrow<f64>,
{
    let values: Vec<f64> = values.into_iter().map(|value| *value.borrow()).collect();
    let maximum = values.iter().copied().fold(0.0_f64, f64::max);
    values
        .iter()
        .map(|value| {
            if maximum <= f64::EPSILON {
                BARS[0]
            } else {
                let index = ((value / maximum) * (BARS.len() - 1) as f64).floor() as usize;
                BARS[index.min(BARS.len() - 1)]
            }
        })
        .collect()
}

/// Left-pad a sparkline with middle dots to `width` characters so a filling
/// history keeps a stable width.
pub fn sparkline_padded(chart: &str, width: usize) -> String {
    let padding = width.saturating_sub(chart.chars().count());
    format!("{}{chart}", "·".repeat(padding))
}

/// `24m`, `1h`, `1h 24m`.
pub fn duration_hours_minutes(minutes: u32) -> String {
    let hours = minutes / 60;
    let minutes = minutes % 60;
    match (hours, minutes) {
        (0, minutes) => format!("{minutes}m"),
        (hours, 0) => format!("{hours}h"),
        (hours, minutes) => format!("{hours}h {minutes}m"),
    }
}

/// Single coarse unit: `12min`, `3h`, `5d`.
pub fn duration_compact(seconds: u64) -> String {
    if seconds < 3_600 {
        format!("{}min", seconds / 60)
    } else if seconds < 86_400 {
        format!("{}h", seconds / 3_600)
    } else {
        format!("{}d", seconds / 86_400)
    }
}

/// Two-unit uptime: `1d 2h`, `2h 3m`, `5m`, `42s`.
pub fn duration_uptime(seconds: u64) -> String {
    let days = seconds / 86_400;
    let hours = seconds % 86_400 / 3_600;
    let minutes = seconds % 3_600 / 60;
    if days > 0 {
        format!("{days}d {hours}h")
    } else if hours > 0 {
        format!("{hours}h {minutes}m")
    } else if minutes > 0 {
        format!("{minutes}m")
    } else {
        format!("{seconds}s")
    }
}

/// `█` for the filled share of `width` cells (floored), `░` for the rest.
pub fn progress_bar(fraction: f64, width: usize) -> String {
    let fraction = if fraction > 0.0 {
        fraction.min(1.0)
    } else {
        0.0
    };
    let filled = ((fraction * width as f64).floor() as usize).min(width);
    format!("{}{}", "█".repeat(filled), "░".repeat(width - filled))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn text_escapes_literal_hashes_before_rich_rendering() {
        assert_eq!(
            Markup::text("Backup #[fg=colour196] #1").as_str(),
            "Backup ##[fg=colour196] ##1"
        );
        assert_eq!(Markup::raw("#[bold]x").as_str(), "#[bold]x");
        assert_eq!(Markup::from("#[bold]x").as_str(), "#[bold]x");
    }

    #[test]
    fn colours_and_styles_render_tmux_words() {
        assert_eq!(Color::Default.to_string(), "default");
        assert_eq!(Color::MUTED.to_string(), "colour245");
        assert_eq!(Color::TITLE.to_string(), "#EBCB8B");
        assert_eq!(Color::WARN.to_string(), "#D08770");
        assert_eq!(Color::Rgb(0xFF00_00A1).to_string(), "#0000A1");
        assert_eq!(
            Style::fg(Color::ACCENT).bold().to_string(),
            "fg=colour178,bold"
        );
        assert_eq!(Style::default().italics().dim().to_string(), "italics,dim");
        assert!(Style::default().is_empty());
    }

    #[test]
    fn styled_markup_wraps_content_and_composes() {
        assert_eq!(
            Markup::colored("CPU", Color::TITLE).as_str(),
            "#[fg=#EBCB8B]CPU#[default]"
        );
        assert_eq!(
            Markup::styled(Markup::text("a#b"), Style::fg(Color::ACCENT).bold()).as_str(),
            "#[fg=colour178,bold]a##b#[default]"
        );
        assert_eq!(Markup::styled("plain", Style::default()).as_str(), "plain");
        assert_eq!(
            Markup::colored(Markup::range("BAT", "bat-prefs"), Color::TITLE).as_str(),
            "#[fg=#EBCB8B]#[range=user|bat-prefs]BAT#[norange]#[default]"
        );
        let mut joined = Markup::colored("NET", Color::TITLE) + " " + Markup::text("#1");
        joined += Markup::raw("!");
        assert_eq!(joined.to_string(), "#[fg=#EBCB8B]NET#[default] ##1!");
    }

    #[test]
    fn link_escapes_marker_delimiters_inside_the_url() {
        assert_eq!(
            Markup::link(Markup::text("Title"), "https://aggr.example/a,b]#[bold]").as_str(),
            "#[link=https://aggr.example/a%2Cb%5D#%5Bbold%5D]Title#[nolink]"
        );
    }

    #[test]
    fn plain_strips_markers_and_unescapes_hashes() {
        let markup = Markup::raw(
            "#[fg=#EBCB8B]CPU#[default]\n#[fg=colour245]Model         #[default]GPU ##[x] ##1 #x",
        );
        assert_eq!(markup.plain(), "CPU\nModel         GPU #[x] #1 #x");
        assert_eq!(
            Markup::raw("#[popup=inline:%23%5B]CPU#[nopopup]").plain(),
            "CPU"
        );
    }

    #[test]
    fn rows_match_the_monitors_detail_row_format_byte_for_byte() {
        assert_eq!(
            Preview::new().row("Total", " 19.8 %").render().as_str(),
            "#[fg=colour245]Total         #[default] 19.8 %"
        );
        assert_eq!(
            Preview::new()
                .row("Write history", "···················█")
                .render()
                .as_str(),
            "#[fg=colour245]Write history #[default]···················█"
        );
        assert_eq!(
            Preview::new()
                .label_width(6)
                .row("Wi-Fi", Markup::text("Studio #[fg=colour196]"))
                .render()
                .as_str(),
            "#[fg=colour245]Wi-Fi #[default]Studio ##[fg=colour196]"
        );
        assert_eq!(
            Preview::new().row("#1", "x").render().as_str(),
            "#[fg=colour245]##1            #[default]x"
        );
    }

    #[test]
    fn preview_lines_render_in_order_without_a_trailing_newline() {
        let preview = Preview::new()
            .title("CPU")
            .note("Updated 1min ago")
            .row("Total", " 19.8 %")
            .blank()
            .section("GPU")
            .raw("free form");
        assert_eq!(
            preview.render().as_str(),
            "#[fg=#EBCB8B]CPU#[default]\n\
#[fg=colour245]Updated 1min ago#[default]\n\
#[fg=colour245]Total         #[default] 19.8 %\n\
\n\
#[bold]GPU#[default]\n\
free form"
        );
        assert_eq!(
            preview.render_plain(),
            "CPU\nUpdated 1min ago\nTotal          19.8 %\n\nGPU\nfree form"
        );
        assert!(Preview::new().is_empty());
        assert_eq!(
            Preview::from_markup("#[bold]body#[default]\n\nmore")
                .render()
                .as_str(),
            "#[bold]body#[default]\n\nmore"
        );
    }

    #[test]
    fn tables_pad_cells_by_visible_width() {
        let table = Table::new([
            Column::new("Provider", 8),
            Column::new("Remaining", 9).right(),
            Column::new("Reset", 5),
        ])
        .row(["Claude", "53%", "5d"])
        .row([
            Markup::text("Fable"),
            Markup::colored("9%", Color::ALERT),
            Markup::text("—"),
        ])
        .row(["Codex"]);
        let expected = [
            "#[fg=colour245]Provider  Remaining  Reset#[default]".to_string(),
            format!("Claude{}53%  5d", " ".repeat(10)),
            format!("Fable{}#[fg=colour196]9%#[default]  —", " ".repeat(12)),
            format!("Codex{}", " ".repeat(16)),
        ]
        .join("\n");
        assert_eq!(Preview::new().table(table).render().as_str(), expected);
        assert!(Table::new([Column::new("", 4)])
            .row(["x"])
            .render_lines()
            .first()
            .is_some_and(|line| line == "x"));
    }

    #[test]
    fn render_percent_encodes_markup_whitespace_and_unicode() {
        let value = StatusValue::text("CPU 18%").with_preview(Preview::from_markup(
            "#[fg=#EBCB8B,bold]CPU#[default]\nCafé: 18% / 82%",
        ));
        assert_eq!(
            value.render().unwrap(),
            "#[popup=inline:%23%5Bfg%3D%23EBCB8B%2Cbold%5DCPU%23%5Bdefault%5D%0ACaf%C3%A9%3A%2018%25%20%2F%2082%25]CPU 18%#[nopopup]"
        );
        assert_eq!(percent_encode("aZ09-_.~"), "aZ09-_.~");
    }

    #[test]
    fn values_without_a_usable_preview_render_the_visible_text_alone() {
        assert_eq!(StatusValue::text("on").render().unwrap(), "on");
        assert_eq!(StatusValue::empty().render().unwrap(), "");
        assert_eq!(StatusValue::from(String::from("x")).visible.as_str(), "x");
        assert_eq!(
            StatusValue::text("NET")
                .with_preview(Preview::new())
                .render()
                .unwrap(),
            "NET"
        );
        assert_eq!(
            StatusValue::text("NET")
                .with_preview(Preview::from_markup(""))
                .render()
                .unwrap(),
            "NET"
        );
    }

    #[test]
    fn render_enforces_the_host_marker_limit_on_the_encoded_body() {
        let fits = StatusValue::text("v").with_preview(Preview::from_markup(
            "a".repeat(MAX_INLINE_PREVIEW_ENCODED_BYTES),
        ));
        assert!(fits.render().is_ok());
        let overflow = StatusValue::text("v").with_preview(Preview::from_markup(
            "a".repeat(MAX_INLINE_PREVIEW_ENCODED_BYTES + 1),
        ));
        assert_eq!(
            overflow.render(),
            Err(PreviewTooLarge {
                encoded_bytes: MAX_INLINE_PREVIEW_ENCODED_BYTES + 1
            })
        );
        // Encoded bytes, not source bytes: one space becomes three bytes.
        let encoded_overflow = StatusValue::text("v").with_preview(Preview::from_markup(
            " ".repeat(MAX_INLINE_PREVIEW_ENCODED_BYTES / 3 + 1),
        ));
        assert!(encoded_overflow.render().is_err());
    }

    #[test]
    fn iec_byte_formatters_match_the_disk_and_network_monitors() {
        assert_eq!(bytes_iec(900 * 1024), "900 KiB");
        assert_eq!(bytes_iec(1000 * 1024), "1000 KiB");
        assert_eq!(bytes_iec(1_572_864), "1.5 MiB");
        assert_eq!(bytes_iec(0), "0 B");
        assert_eq!(bytes_iec(1023), "1023 B");
        assert_eq!(bytes_iec(u64::MAX), "16384 PiB");
        assert_eq!(bytes_iec_compact(1_572_864.0), "1.5MiB");
        assert_eq!(bytes_iec_compact(2_048.0), "2.0KiB");
        assert_eq!(bytes_iec_compact(-1.0), "0B");
        assert_eq!(rate_iec(1_572_864.0), "1.5 MiB/s");
        assert_eq!(rate_iec(2_048.0), "2.0 KiB/s");
    }

    #[test]
    fn rate_cells4_uses_four_cells_at_every_decimal_unit_boundary() {
        for (rate, expected) in [
            (0.0, "  0B"),
            (9.0, "  9B"),
            (999.4, "999B"),
            (999.5, "1.0K"),
            (1_200.0, "1.2K"),
            (9_950.0, " 10K"),
            (12_000.0, " 12K"),
            (999_499.0, "999K"),
            (999_500.0, "1.0M"),
            (1e9, "1.0G"),
            (1e12, "1.0T"),
            (1e15, "1.0P"),
            (1e30, "999P"),
            (f64::INFINITY, "999P"),
            (f64::NAN, "  0B"),
            (-1.0, "  0B"),
            (f64::MAX, "999P"),
        ] {
            let rendered = rate_cells4(rate);
            assert_eq!(rendered, expected, "rate {rate}");
            assert_eq!(rendered.chars().count(), 4);
        }
    }

    #[test]
    fn percent_reads_true_without_padding() {
        for (value, expected) in [
            (0.0, "0%"),
            (9.0, "9%"),
            (16.0, "16%"),
            (99.6, "100%"),
            (100.0, "100%"),
            (250.0, "100%"),
            (-5.0, "0%"),
            (f64::NAN, "0%"),
        ] {
            assert_eq!(percent(value), expected, "value {value}");
        }
    }

    #[test]
    fn percent2_keeps_two_digits_and_caps_at_ninety_nine() {
        for (value, expected) in [
            (0.0, " 0%"),
            (9.0, " 9%"),
            (10.0, "10%"),
            (75.0, "75%"),
            (99.6, "99%"),
            (100.0, "99%"),
            (250.0, "99%"),
            (-5.0, " 0%"),
            (f64::NAN, " 0%"),
        ] {
            assert_eq!(percent2(value), expected, "value {value}");
        }
    }

    #[test]
    fn sparklines_follow_the_monitor_semantics() {
        assert_eq!(sparkline_percent([0.0, 12.5, 50.0, 87.5, 100.0]), "▁▂▅▇█");
        let clamped: &[f64] = &[150.0, -3.0, f64::NAN];
        assert_eq!(sparkline_percent(clamped), "█▁▁");
        assert_eq!(sparkline_scaled([0.0, 1.0, 2.0, 3.0]), "▁▃▅█");
        let flat: &[f64] = &[0.0, 0.0];
        assert_eq!(sparkline_scaled(flat), "▁▁");
        assert_eq!(sparkline_scaled(std::iter::empty::<f64>()), "");
        let mut history = History::<20>::new();
        history.push(0.0);
        history.push(100.0);
        assert_eq!(sparkline_percent(&history), "▁█");
        assert_eq!(
            sparkline_padded(&sparkline_percent(history.iter()), 20),
            "··················▁█"
        );
        assert_eq!(sparkline_padded("", 20), "····················");
        assert_eq!(sparkline_padded("▁▂▃", 2), "▁▂▃");
    }

    #[test]
    fn duration_helpers_match_the_three_bundled_shapes() {
        assert_eq!(duration_hours_minutes(24), "24m");
        assert_eq!(duration_hours_minutes(60), "1h");
        assert_eq!(duration_hours_minutes(84), "1h 24m");
        assert_eq!(duration_compact(0), "0min");
        assert_eq!(duration_compact(3_599), "59min");
        assert_eq!(duration_compact(3_600), "1h");
        assert_eq!(duration_compact(86_399), "23h");
        assert_eq!(duration_compact(5 * 86_400), "5d");
        assert_eq!(duration_uptime(7_384), "2h 3m");
        assert_eq!(duration_uptime(90_000), "1d 1h");
        assert_eq!(duration_uptime(300), "5m");
        assert_eq!(duration_uptime(42), "42s");
    }

    #[test]
    fn progress_bar_matches_the_quota_bar_integer_formula() {
        for percent in 0..=100_usize {
            let filled = (percent * 12 / 100).min(12);
            assert_eq!(
                progress_bar(percent as f64 / 100.0, 12),
                format!("{}{}", "█".repeat(filled), "░".repeat(12 - filled)),
                "{percent}%"
            );
        }
        assert_eq!(progress_bar(f64::NAN, 4), "░░░░");
        assert_eq!(progress_bar(-1.0, 4), "░░░░");
        assert_eq!(progress_bar(7.0, 4), "████");
        assert_eq!(progress_bar(0.5, 0), "");
    }

    #[test]
    fn published_gate_returns_only_changed_values() {
        let mut published = Published::new();
        assert_eq!(published.update("a"), Some(&"a"));
        assert_eq!(published.update("a"), None);
        assert_eq!(published.update("b"), Some(&"b"));
        assert_eq!(published.last(), Some(&"b"));
        published.reset();
        assert_eq!(published.update("b"), Some(&"b"));
    }

    #[test]
    fn history_is_bounded_and_oldest_first() {
        let mut history = History::<20>::new();
        assert!(history.is_empty());
        for value in 0..25 {
            history.push(f64::from(value) * 4.0);
        }
        assert_eq!(history.len(), History::<20>::CAPACITY);
        assert_eq!(history.as_slice().first(), Some(&20.0));
        assert_eq!(history.iter().last(), Some(96.0));
        history.clear();
        assert!(history.is_empty());
    }
}
