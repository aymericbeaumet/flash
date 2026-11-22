//! Fixtures shared by the unit tests of several modules.

use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

use crate::clients::TmuxClient;

pub(crate) struct ExecutableFixture(pub(crate) PathBuf);

impl ExecutableFixture {
    pub(crate) async fn new() -> Self {
        static SEQUENCE: AtomicU64 = AtomicU64::new(0);
        let path = std::env::temp_dir().join(format!(
            "flash-tmux-test-{}-{}",
            std::process::id(),
            SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        tokio::fs::create_dir_all(&path).await.unwrap();
        Self(path)
    }

    pub(crate) async fn script(&self, name: &str, body: &str) -> String {
        let path = self.0.join(name);
        tokio::fs::write(&path, format!("#!/bin/sh\n{body}\n"))
            .await
            .unwrap();
        tokio::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700))
            .await
            .unwrap();
        path.to_string_lossy().into_owned()
    }
    pub(crate) async fn cleanup(self) {
        tokio::fs::remove_dir_all(self.0).await.unwrap();
    }
}

pub(crate) fn client(tty: &str, session: &str, client_pid: i64, activity: i64) -> TmuxClient {
    TmuxClient {
        tty: tty.to_string(),
        session: session.to_string(),
        client_pid,
        activity,
        backend_id: "local".to_string(),
        remote: false,
        ..TmuxClient::default()
    }
}
