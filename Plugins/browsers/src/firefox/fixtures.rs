//! Builders shared by the Firefox engine's unit tests.

use super::strip::{AxWindow, Strip, Tab};

pub(super) fn tab(root: usize, title: &str, url: &str) -> Tab {
    Tab {
        root,
        title: title.into(),
        url: url.into(),
        ..Tab::default()
    }
}

/// `windows` AX windows (none main) holding `tabs`.
pub(super) fn strip(windows: usize, tabs: Vec<Tab>) -> Strip {
    Strip {
        windows: vec![AxWindow::default(); windows],
        tabs,
    }
}
