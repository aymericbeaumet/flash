//! The text the media commands show. Pure, so the wording is tested without a
//! player or an audio device.

use flash_plugin::{AudioDevice, AudioDirection, OutputVolume};

/// A media app `media status` asks what it is playing, through its
/// AppleScript dictionary. Only a player already running is asked, so the
/// command never launches one.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Player {
    pub name: &'static str,
    pub bundle_id: &'static str,
    /// Its tracks name an artist; TV and Podcasts episodes do not.
    pub has_artist: bool,
}

/// The players, in the order `media status` lists them. Their bundle ids are
/// the manifest's `apple_events_targets`.
pub const PLAYERS: [Player; 4] = [
    Player {
        name: "Spotify",
        bundle_id: "com.spotify.client",
        has_artist: true,
    },
    Player {
        name: "Music",
        bundle_id: "com.apple.Music",
        has_artist: true,
    },
    Player {
        name: "TV",
        bundle_id: "com.apple.TV",
        has_artist: false,
    },
    Player {
        name: "Podcasts",
        bundle_id: "com.apple.podcasts",
        has_artist: false,
    },
];

/// The players among the running `bundle_ids`, in [`PLAYERS`]' order.
pub fn running_players<'a>(bundle_ids: impl IntoIterator<Item = &'a str>) -> Vec<Player> {
    let running: Vec<&str> = bundle_ids.into_iter().collect();
    PLAYERS
        .into_iter()
        .filter(|player| running.contains(&player.bundle_id))
        .collect()
}

/// One player's answer to the host's `now_playing` operation.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NowPlaying {
    /// `playing`, `paused` or `stopped`.
    pub state: String,
    /// Empty when nothing is loaded.
    pub track: String,
}

impl NowPlaying {
    /// The state line, then the track. `None` without a state: a player that
    /// quit since it was listed answers nothing.
    pub fn parse(output: &str) -> Option<Self> {
        let (state, track) = output.split_once('\n').unwrap_or((output, ""));
        let state = state.trim().to_lowercase();
        (!state.is_empty()).then(|| Self {
            state,
            track: track.trim().to_string(),
        })
    }
}

/// `media status`: one line per running player, then the output volume.
pub fn status(players: &[(Player, Option<NowPlaying>)], volume: Option<OutputVolume>) -> String {
    let mut lines: Vec<String> = players
        .iter()
        .map(|(player, now_playing)| {
            let state = now_playing
                .as_ref()
                .map_or("unknown", |playing| playing.state.as_str());
            let line = format!("{} [{state}]", player.name);
            match now_playing {
                Some(playing) if !playing.track.is_empty() => format!("{line}: {}", playing.track),
                _ => line,
            }
        })
        .collect();
    if lines.is_empty() {
        lines.push("no media app is running".to_string());
    }
    if let Some(volume) = volume {
        let muted = if volume.muted { " (muted)" } else { "" };
        lines.push(format!("{}{muted}", volume_line(volume.percent)));
    }
    lines.join("\n")
}

/// What a volume step prints, and `media status`' last line.
pub fn volume_line(percent: u8) -> String {
    format!("volume {percent}%")
}

/// `audio input` / `audio output` without a device: the default marked `*`.
pub fn devices(devices: &[AudioDevice], direction: AudioDirection) -> String {
    if devices.is_empty() {
        return format!("no audio {} devices", direction.as_str());
    }
    devices
        .iter()
        .map(|device| {
            let mark = if device.is_default { "* " } else { "  " };
            format!("{mark}{} [{}]", device.name, device.uid)
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// The device `query` names: its UID, which is unique, or a name only one
/// device has.
pub fn device_matching<'a>(
    query: &str,
    devices: &'a [AudioDevice],
) -> Result<&'a AudioDevice, String> {
    if let Some(device) = devices.iter().find(|device| device.uid == query) {
        return Ok(device);
    }
    let named: Vec<&AudioDevice> = devices
        .iter()
        .filter(|device| device.name == query)
        .collect();
    match named.as_slice() {
        [device] => Ok(device),
        [] => Err(format!("audio device not found: {query}")),
        _ => Err(format!(
            "audio device name is ambiguous, use its UID: {query}"
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn device(uid: &str, name: &str, is_default: bool) -> AudioDevice {
        AudioDevice {
            uid: uid.to_string(),
            name: name.to_string(),
            is_default,
        }
    }

    fn outputs() -> Vec<AudioDevice> {
        vec![
            device("usb-1", "USB Audio", true),
            device("usb-2", "USB Audio", false),
            device("speakers", "Studio Speakers", false),
        ]
    }

    #[test]
    fn devices_list_with_the_default_marked() {
        assert_eq!(
            devices(&outputs(), AudioDirection::Output),
            "* USB Audio [usb-1]\n  USB Audio [usb-2]\n  Studio Speakers [speakers]"
        );
        assert_eq!(
            devices(&[], AudioDirection::Input),
            "no audio input devices"
        );
        assert_eq!(
            devices(&[], AudioDirection::Output),
            "no audio output devices"
        );
    }

    #[test]
    fn a_device_is_named_by_its_uid_or_a_name_only_it_has() {
        let outputs = outputs();
        assert_eq!(
            device_matching("Studio Speakers", &outputs).unwrap().uid,
            "speakers"
        );
        assert_eq!(device_matching("usb-2", &outputs).unwrap().uid, "usb-2");
        assert_eq!(
            device_matching("USB Audio", &outputs),
            Err("audio device name is ambiguous, use its UID: USB Audio".to_string())
        );
        assert_eq!(
            device_matching("missing", &outputs),
            Err("audio device not found: missing".to_string())
        );
        // A UID wins over another device's name.
        let shadowed = vec![
            device("USB Audio", "Dock", false),
            device("usb-1", "USB Audio", true),
        ];
        assert_eq!(
            device_matching("USB Audio", &shadowed).unwrap().name,
            "Dock"
        );
    }

    #[test]
    fn a_now_playing_reply_parses() {
        let parsed = |state: &str, track: &str| {
            Some(NowPlaying {
                state: state.to_string(),
                track: track.to_string(),
            })
        };
        assert_eq!(
            NowPlaying::parse("Playing\nTrack — Artist"),
            parsed("playing", "Track — Artist")
        );
        assert_eq!(NowPlaying::parse("stopped\n"), parsed("stopped", ""));
        assert_eq!(NowPlaying::parse("paused"), parsed("paused", ""));
        assert_eq!(NowPlaying::parse(""), None);
        assert_eq!(NowPlaying::parse("\nTrack"), None);
    }

    #[test]
    fn only_the_running_players_are_listed_in_their_order() {
        let running = ["com.apple.Music", "com.spotify.client", "com.apple.Safari"];
        let names: Vec<&str> = running_players(running)
            .iter()
            .map(|player| player.name)
            .collect();
        assert_eq!(names, ["Spotify", "Music"]);
        assert!(running_players([]).is_empty());
        assert!(PLAYERS[0].has_artist && PLAYERS[1].has_artist);
        assert!(!PLAYERS[2].has_artist && !PLAYERS[3].has_artist);
    }

    #[test]
    fn status_lists_each_player_then_the_volume() {
        let playing = NowPlaying::parse("playing\nOne More Time — Daft Punk");
        let paused = NowPlaying::parse("paused\n");
        let muted = Some(OutputVolume {
            percent: 31,
            muted: true,
        });
        assert_eq!(
            status(&[(PLAYERS[0], playing), (PLAYERS[1], paused)], muted),
            "Spotify [playing]: One More Time — Daft Punk\nMusic [paused]\nvolume 31% (muted)"
        );
        assert_eq!(
            status(&[(PLAYERS[2], None)], muted),
            "TV [unknown]\nvolume 31% (muted)"
        );
        assert_eq!(
            status(&[], muted),
            "no media app is running\nvolume 31% (muted)"
        );
        let audible = Some(OutputVolume {
            percent: 44,
            muted: false,
        });
        assert_eq!(status(&[], audible), "no media app is running\nvolume 44%");
        assert_eq!(status(&[], None), "no media app is running");
    }
}
