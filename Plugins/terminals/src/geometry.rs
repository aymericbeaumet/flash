//! Cell geometry for hint targets: the terminal window split evenly over the
//! client grid or, for Alacritty, the cell pixels it reports to tmux in a
//! supported layout.

use std::path::PathBuf;

use crate::hints::ClientLayout;
use crate::processes::process_command;
use crate::remote::executable_name;

const ALACRITTY_BUNDLES: [&str; 2] = ["org.alacritty", "io.alacritty"];

fn supported_alacritty_layout(text: &str) -> bool {
    let Ok(config) = toml::from_str::<toml::Value>(text) else {
        return false;
    };
    if config.get("import").is_some()
        || config
            .get("general")
            .and_then(|v| v.get("import"))
            .is_some()
    {
        return false;
    }
    let Some(window) = config.get("window") else {
        return false;
    };
    window.get("decorations").and_then(toml::Value::as_str) == Some("None")
        && window.get("dynamic_padding").and_then(toml::Value::as_bool) == Some(true)
}

type AlacrittyLayoutCache = Option<(String, std::time::SystemTime, bool)>;
static ALACRITTY_LAYOUT_CACHE: std::sync::LazyLock<std::sync::Mutex<AlacrittyLayoutCache>> =
    std::sync::LazyLock::new(|| std::sync::Mutex::new(None));

fn alacritty_config_override(command: &str) -> Option<Option<PathBuf>> {
    // ps does not preserve argv boundaries. Accept only unambiguous shapes;
    // never guess a quoted/spaced path or a process with geometry overrides.
    let words: Vec<_> = command.split_whitespace().collect();
    if !words
        .first()
        .is_some_and(|program| executable_name(program) == "alacritty")
    {
        return None;
    }
    let mut path = None;
    let mut index = 1;
    while index < words.len() {
        match words[index] {
            "-e" | "--command" => return (index + 1 < words.len()).then_some(path),
            "--title" | "-T" => {
                words.get(index + 1)?;
                index += 2;
            }
            "--config-file" => {
                let value = words.get(index + 1)?;
                if path.is_some() || !value.starts_with('/') {
                    return None;
                }
                path = Some(PathBuf::from(value));
                index += 2;
            }
            option if option.starts_with("--config-file=") => {
                let value = option.strip_prefix("--config-file=")?;
                if path.is_some() || !value.starts_with('/') {
                    return None;
                }
                path = Some(PathBuf::from(value));
                index += 1;
            }
            option if option.starts_with("--title=") => {
                index += 1;
            }
            _ => return None,
        }
    }
    Some(path)
}

async fn alacritty_layout_supported(pid: i64) -> bool {
    let Some(command) = process_command(pid).await else {
        return false;
    };
    let Some(config_override) = alacritty_config_override(&command) else {
        return false;
    };
    let Ok(home) = std::env::var("HOME") else {
        return false;
    };
    let paths = if let Some(path) = config_override {
        vec![path]
    } else {
        // An alternate environment's search root is not proof of the running
        // GUI instance's config. Require an explicit path for that case.
        if std::env::var("XDG_CONFIG_HOME").is_ok_and(|path| path != format!("{home}/.config")) {
            return false;
        }
        vec![
            PathBuf::from(format!("{home}/.config/alacritty/alacritty.toml")),
            PathBuf::from(format!("{home}/.config/alacritty.toml")),
            PathBuf::from(format!("{home}/.alacritty.toml")),
        ]
    };
    for path in paths {
        let Ok(metadata) = tokio::fs::metadata(&path).await else {
            continue;
        };
        if !metadata.is_file() || metadata.len() > 256 * 1024 {
            return false;
        }
        let path = path.to_string_lossy().into_owned();
        let Ok(modified) = metadata.modified() else {
            return false;
        };
        if let Some((cached_path, cached_modified, supported)) = ALACRITTY_LAYOUT_CACHE
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .as_ref()
            && *cached_path == path
            && *cached_modified == modified
        {
            return *supported;
        }
        let Ok(file) = tokio::fs::File::open(&path).await else {
            return false;
        };
        use tokio::io::AsyncReadExt;
        let mut text = String::new();
        if file
            .take(256 * 1024 + 1)
            .read_to_string(&mut text)
            .await
            .is_err()
            || text.len() > 256 * 1024
        {
            return false;
        }
        let supported = supported_alacritty_layout(&text);
        *ALACRITTY_LAYOUT_CACHE
            .lock()
            .unwrap_or_else(|e| e.into_inner()) = Some((path, modified, supported));
        return supported;
    }
    false
}

/// Alacritty reports actual rasterized cell pixels to tmux, including font
/// zoom and offsets. Its undecorated, dynamically padded grid is centered in
/// the captured window, with padding rounded down in physical pixels.
fn reported_geometry(
    win_w: f64,
    win_h: f64,
    cols: i64,
    rows: i64,
    cell_width: i64,
    cell_height: i64,
    display_scale: Option<f64>,
) -> Option<(f64, f64, f64, f64)> {
    let scale = display_scale.filter(|v| v.is_finite() && *v > 0.0)?;
    if cols <= 0
        || rows <= 0
        || cell_width <= 0
        || cell_height <= 0
        || !win_w.is_finite()
        || !win_h.is_finite()
    {
        return None;
    }
    let spare_x = win_w * scale - cols as f64 * cell_width as f64;
    let spare_y = win_h * scale - rows as f64 * cell_height as f64;
    if spare_x < 0.0 || spare_y < 0.0 {
        return None;
    }
    Some((
        cell_width as f64 / scale,
        cell_height as f64 / scale,
        (spare_x / 2.0).floor() / scale,
        (spare_y / 2.0).floor() / scale,
    ))
}

pub(crate) async fn resolve_geometry(
    bundle_id: &str,
    pid: i64,
    win_w: f64,
    win_h: f64,
    layout: &ClientLayout,
    display_scale: Option<f64>,
) -> Option<(f64, f64, f64, f64)> {
    if ALACRITTY_BUNDLES.contains(&bundle_id) {
        if !alacritty_layout_supported(pid).await {
            return None;
        }
        return reported_geometry(
            win_w,
            win_h,
            layout.columns,
            layout.rows,
            layout.cell_width,
            layout.cell_height,
            display_scale,
        );
    }
    Some((
        win_w / layout.columns as f64,
        win_h / layout.rows as f64,
        0.0,
        0.0,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reported_cells_fit_the_undecorated_alacritty_grid_at_display_scale() {
        assert_eq!(
            reported_geometry(2048.0, 1122.0, 256, 70, 16, 32, Some(2.0)),
            Some((8.0, 16.0, 0.0, 1.0))
        );
        assert_eq!(
            reported_geometry(803.0, 603.0, 80, 30, 20, 40, Some(2.0)),
            Some((10.0, 20.0, 1.5, 1.5))
        );
        for scale in [None, Some(0.0), Some(-1.0), Some(f64::NAN)] {
            assert!(reported_geometry(800.0, 600.0, 80, 30, 20, 40, scale).is_none());
        }
        assert!(reported_geometry(800.0, 600.0, 80, 30, 0, 40, Some(2.0)).is_none());
        assert!(reported_geometry(799.0, 600.0, 80, 30, 20, 40, Some(2.0)).is_none());
        assert!(supported_alacritty_layout(
            "[window]\ndecorations = 'None'\ndynamic_padding = true"
        ));
        for config in [
            "",
            "[window]\ndecorations = 'Full'\ndynamic_padding = true",
            "[window]\ndecorations = 'None'\ndynamic_padding = false",
            "[general]\nimport = ['other.toml']\n[window]\ndecorations = 'None'\ndynamic_padding = true",
        ] {
            assert!(!supported_alacritty_layout(config));
        }
    }

    #[test]
    fn alacritty_launch_config_is_explicit_or_unambiguous() {
        assert_eq!(
            alacritty_config_override(
                "alacritty --title fixture --config-file /tmp/fixture.toml -e tmux -o child-argument"
            ),
            Some(Some(PathBuf::from("/tmp/fixture.toml")))
        );
        assert_eq!(
            alacritty_config_override("alacritty -T fixture --command sh -c example"),
            Some(None)
        );
        assert_eq!(
            alacritty_config_override("/Applications/Alacritty.app/Contents/MacOS/alacritty"),
            Some(None)
        );
        assert_eq!(
            alacritty_config_override("alacritty --config-file /tmp/fixture.toml"),
            Some(Some(PathBuf::from("/tmp/fixture.toml")))
        );
        assert_eq!(
            alacritty_config_override("alacritty --config-file=/tmp/fixture.toml"),
            Some(Some(PathBuf::from("/tmp/fixture.toml")))
        );
        for command in [
            "alacritty -o window.decorations=Full",
            "alacritty --option window.dynamic_padding=false",
            "alacritty --config-file /tmp/has spaces.toml",
            "alacritty --config-file relative.toml",
            "alacritty --config-file /tmp/a -o window.decorations=Full",
            "other",
        ] {
            assert_eq!(alacritty_config_override(command), None, "{command}");
        }
    }
}
