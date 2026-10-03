//! Watches the local tmux socket directory (`tmux-$UID`) instead of rescanning
//! it on a timer.
//!
//! A tmux server starting or exiting links or unlinks its socket, a write to
//! the directory that kqueue reports as `EVFILT_VNODE`/`NOTE_WRITE`. Until the
//! first server has created the directory, its parent is watched for it to
//! appear; unrelated entries changing there are not reported. The kqueue
//! descriptor itself is registered with Tokio's reactor, so waiting costs no
//! thread and no timer, and every call is a safe `nix` wrapper.

use std::io;
use std::os::fd::{AsFd, AsRawFd, OwnedFd, RawFd};
use std::path::PathBuf;

use nix::libc::timespec;
use nix::sys::event::{EvFlags, EventFilter, FilterFlag, KEvent, Kqueue};
use tokio::io::Interest;
use tokio::io::unix::AsyncFd;

/// `Kqueue` exposes `AsFd`; Tokio's reactor wants `AsRawFd`.
struct Queue(Kqueue);

impl AsRawFd for Queue {
    fn as_raw_fd(&self) -> RawFd {
        self.0.as_fd().as_raw_fd()
    }
}

const NO_WAIT: timespec = timespec {
    tv_sec: 0,
    tv_nsec: 0,
};

/// What the directory watch currently targets.
struct Watched {
    /// Held open for as long as the kqueue watches it; closing it removes
    /// the registration.
    _directory: OwnedFd,
    /// The socket directory itself, rather than its parent.
    socket_directory: bool,
}

pub(crate) struct SocketDirWatch {
    queue: AsyncFd<Queue>,
    socket_directory: PathBuf,
    watched: Watched,
}

impl SocketDirWatch {
    pub(crate) async fn new(socket_directory: PathBuf) -> io::Result<Self> {
        // Readable only: a kqueue descriptor rejects a write filter.
        let queue = AsyncFd::with_interest(Queue(Kqueue::new()?), Interest::READABLE)?;
        let watched = watch(&queue, &socket_directory).await?;
        Ok(Self {
            queue,
            socket_directory,
            watched,
        })
    }

    /// Wait until an entry of the socket directory appears or disappears, or
    /// the directory itself does.
    pub(crate) async fn changed(&mut self) -> io::Result<()> {
        loop {
            let mut ready = self.queue.readable().await?;
            let mut events = [KEvent::new(
                0,
                EventFilter::EVFILT_VNODE,
                EvFlags::empty(),
                FilterFlag::empty(),
                0,
                0,
            ); 8];
            let count = self
                .queue
                .get_ref()
                .0
                .kevent(&[], &mut events, Some(NO_WAIT))?;
            ready.clear_ready();
            if count == 0 {
                continue;
            }
            let moved = events[..count].iter().any(|event| {
                event.fflags().intersects(
                    FilterFlag::NOTE_DELETE | FilterFlag::NOTE_RENAME | FilterFlag::NOTE_REVOKE,
                )
            });
            if self.watched.socket_directory && !moved {
                return Ok(());
            }
            // The parent changed (the socket directory may have appeared), or
            // the socket directory went away: retarget the watch.
            let was_socket_directory = self.watched.socket_directory;
            self.watched = watch(&self.queue, &self.socket_directory).await?;
            if was_socket_directory || self.watched.socket_directory {
                return Ok(());
            }
        }
    }
}

/// Watch the socket directory when it exists, else its parent.
async fn watch(queue: &AsyncFd<Queue>, socket_directory: &PathBuf) -> io::Result<Watched> {
    let (directory, socket_dir) = match tokio::fs::File::open(socket_directory).await {
        Ok(directory) => (directory, true),
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            let parent = socket_directory
                .parent()
                .ok_or_else(|| io::Error::from(io::ErrorKind::NotFound))?;
            (tokio::fs::File::open(parent).await?, false)
        }
        Err(error) => return Err(error),
    };
    let directory = OwnedFd::from(directory.into_std().await);
    let change = KEvent::new(
        directory.as_raw_fd() as usize,
        EventFilter::EVFILT_VNODE,
        EvFlags::EV_ADD | EvFlags::EV_CLEAR,
        FilterFlag::NOTE_WRITE
            | FilterFlag::NOTE_DELETE
            | FilterFlag::NOTE_RENAME
            | FilterFlag::NOTE_REVOKE,
        0,
        0,
    );
    queue
        .get_ref()
        .0
        .kevent(&[change], &mut [], Some(NO_WAIT))?;
    Ok(Watched {
        _directory: directory,
        socket_directory: socket_dir,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;
    use tokio::time::timeout;

    const QUIET: Duration = Duration::from_millis(200);
    const PROMPT: Duration = Duration::from_secs(2);

    #[tokio::test]
    async fn reports_the_directory_appearing_and_its_entries_changing_only() {
        let root = std::env::temp_dir().join(format!("flash-tmux-watch-{}", std::process::id()));
        let _ = tokio::fs::remove_dir_all(&root).await;
        tokio::fs::create_dir_all(&root).await.unwrap();
        let socket_directory = root.join("tmux-501");
        let mut watch = SocketDirWatch::new(socket_directory.clone())
            .await
            .expect("watch");
        assert!(timeout(QUIET, watch.changed()).await.is_err(), "no change");

        // Unrelated churn beside the missing directory is not a change.
        tokio::fs::write(root.join("unrelated"), b"").await.unwrap();
        assert!(timeout(QUIET, watch.changed()).await.is_err());

        // The first server creating the directory is.
        tokio::fs::create_dir(&socket_directory).await.unwrap();
        timeout(PROMPT, watch.changed())
            .await
            .expect("directory appeared")
            .unwrap();

        // A socket appearing or disappearing in it is.
        let socket = socket_directory.join("default");
        tokio::fs::write(&socket, b"").await.unwrap();
        timeout(PROMPT, watch.changed())
            .await
            .expect("entry appeared")
            .unwrap();
        tokio::fs::remove_file(&socket).await.unwrap();
        timeout(PROMPT, watch.changed())
            .await
            .expect("entry removed")
            .unwrap();

        // Once the directory is watched, its parent's churn is not.
        tokio::fs::remove_file(root.join("unrelated"))
            .await
            .unwrap();
        assert!(timeout(QUIET, watch.changed()).await.is_err());

        // The directory going away is, and the watch falls back to waiting
        // for it to reappear.
        tokio::fs::remove_dir(&socket_directory).await.unwrap();
        timeout(PROMPT, watch.changed())
            .await
            .expect("directory removed")
            .unwrap();
        tokio::fs::create_dir(&socket_directory).await.unwrap();
        timeout(PROMPT, watch.changed())
            .await
            .expect("directory reappeared")
            .unwrap();

        tokio::fs::remove_dir_all(&root).await.unwrap();
    }
}
