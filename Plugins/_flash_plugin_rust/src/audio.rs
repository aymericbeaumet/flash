//! The host's audio devices (`host.audio_devices`): CoreAudio stays in the
//! resident, and a plugin holding the `audio_devices` capability lists the
//! devices, selects a default, steps the output volume and toggles its mute
//! through these typed calls.

use serde_json::{Value, json};

use crate::context::Context;

/// Every `operation` of `host.audio_devices` (`protocol.json`
/// `audio_devices.operations`).
#[cfg(test)]
pub(crate) const OPERATIONS: [&str; 5] = ["list", "select", "step_volume", "toggle_mute", "volume"];

/// macOS volume keys move the output a sixteenth at a time: the most ticks
/// one `step_volume` takes, either way (`audio_devices.max_ticks`).
pub const MAX_VOLUME_TICKS: u32 = 16;

/// Which devices a call is about.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AudioDirection {
    Input,
    Output,
}

impl AudioDirection {
    pub const ALL: [Self; 2] = [Self::Input, Self::Output];

    /// The name on the wire, and in a command (`audio input`).
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Input => "input",
            Self::Output => "output",
        }
    }
}

/// One audio device of a direction.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AudioDevice {
    /// Unique among the devices, and what a selection names.
    pub uid: String,
    pub name: String,
    /// Whether it is the direction's default device.
    pub is_default: bool,
}

/// The default output's level, as the volume bezel shows it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct OutputVolume {
    /// 0 to 100.
    pub percent: u8,
    pub muted: bool,
}

/// The host's error, or `fallback` for a failure that carries none.
fn failure(response: &Value, fallback: &str) -> String {
    response
        .get("error")
        .and_then(Value::as_str)
        .filter(|error| !error.is_empty())
        .unwrap_or(fallback)
        .to_string()
}

fn succeeded(response: &Value) -> Result<(), String> {
    if response.get("ok").and_then(Value::as_bool) == Some(true) {
        Ok(())
    } else {
        Err(failure(response, "host.audio_devices failed"))
    }
}

fn percent(response: &Value) -> Result<u8, String> {
    response
        .get("percent")
        .and_then(Value::as_u64)
        .filter(|percent| *percent <= 100)
        .map(|percent| percent as u8)
        .ok_or_else(|| "host.audio_devices response missing percent".to_string())
}

fn muted(response: &Value) -> Result<bool, String> {
    response
        .get("muted")
        .and_then(Value::as_bool)
        .ok_or_else(|| "host.audio_devices response missing muted".to_string())
}

/// The devices of a `list` reply; one malformed device refuses them all.
pub(crate) fn devices_from_response(response: &Value) -> Result<Vec<AudioDevice>, String> {
    succeeded(response)?;
    let malformed = || "host.audio_devices response has a malformed device".to_string();
    response
        .get("devices")
        .and_then(Value::as_array)
        .ok_or_else(|| "host.audio_devices response missing devices".to_string())?
        .iter()
        .map(|device| {
            Some(AudioDevice {
                uid: device
                    .get("uid")?
                    .as_str()
                    .filter(|uid| !uid.is_empty())?
                    .to_string(),
                name: device.get("name")?.as_str()?.to_string(),
                is_default: device.get("default")?.as_bool()?,
            })
        })
        .map(|device| device.ok_or_else(malformed))
        .collect()
}

pub(crate) fn percent_from_response(response: &Value) -> Result<u8, String> {
    succeeded(response)?;
    percent(response)
}

pub(crate) fn muted_from_response(response: &Value) -> Result<bool, String> {
    succeeded(response)?;
    muted(response)
}

pub(crate) fn volume_from_response(response: &Value) -> Result<OutputVolume, String> {
    succeeded(response)?;
    Ok(OutputVolume {
        percent: percent(response)?,
        muted: muted(response)?,
    })
}

impl Context {
    /// The audio devices of `direction`, sorted by name, the default marked
    /// (`host.audio_devices` `list`). Requires the `audio_devices` capability,
    /// as every call here does.
    pub async fn audio_devices(
        &self,
        direction: AudioDirection,
    ) -> Result<Vec<AudioDevice>, String> {
        let params = json!({ "operation": "list", "direction": direction.as_str() });
        devices_from_response(&self.call_host("host.audio_devices", params).await)
    }

    /// Make the device `uid` the default of `direction` (`select`).
    pub async fn select_audio_device(
        &self,
        direction: AudioDirection,
        uid: &str,
    ) -> Result<(), String> {
        let params = json!({
            "operation": "select", "direction": direction.as_str(), "uid": uid,
        });
        succeeded(&self.call_host("host.audio_devices", params).await)
    }

    /// Move the default output `ticks` macOS volume-key ticks, up when
    /// positive and down when negative, and clear its mute (`step_volume`).
    /// Answers the percent the bezel would show. `ticks` is clamped to
    /// [`MAX_VOLUME_TICKS`] either way, the whole scale; zero is refused.
    pub async fn step_output_volume(&self, ticks: i32) -> Result<u8, String> {
        if ticks == 0 {
            return Err("a volume step moves at least one tick".to_string());
        }
        let bound = MAX_VOLUME_TICKS as i32;
        let params = json!({ "operation": "step_volume", "ticks": ticks.clamp(-bound, bound) });
        percent_from_response(&self.call_host("host.audio_devices", params).await)
    }

    /// Mute or unmute the default output (`toggle_mute`). Answers whether it
    /// is muted.
    pub async fn toggle_output_mute(&self) -> Result<bool, String> {
        let params = json!({ "operation": "toggle_mute" });
        muted_from_response(&self.call_host("host.audio_devices", params).await)
    }

    /// The default output's level (`volume`).
    pub async fn output_volume(&self) -> Result<OutputVolume, String> {
        let params = json!({ "operation": "volume" });
        volume_from_response(&self.call_host("host.audio_devices", params).await)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_device_list_decodes_whole_or_not_at_all() {
        let reply = json!({ "ok": true, "devices": [
            { "uid": "built-in", "name": "MacBook Pro Speakers", "default": true },
            { "uid": "usb-1", "name": "USB Audio", "default": false },
        ] });
        assert_eq!(
            devices_from_response(&reply).unwrap(),
            [
                AudioDevice {
                    uid: "built-in".into(),
                    name: "MacBook Pro Speakers".into(),
                    is_default: true,
                },
                AudioDevice {
                    uid: "usb-1".into(),
                    name: "USB Audio".into(),
                    is_default: false,
                },
            ]
        );
        assert_eq!(
            devices_from_response(&json!({ "ok": true, "devices": [] })).unwrap(),
            []
        );
        for malformed in [
            json!({ "ok": true, "devices": [{ "name": "A", "default": true }] }),
            json!({ "ok": true, "devices": [{ "uid": "", "name": "A", "default": true }] }),
            json!({ "ok": true, "devices": [{ "uid": "a", "default": true }] }),
            json!({ "ok": true, "devices": [{ "uid": "a", "name": "A" }] }),
            json!({ "ok": true, "devices": [{ "uid": "a", "name": "A", "default": 1 }] }),
        ] {
            assert_eq!(
                devices_from_response(&malformed),
                Err("host.audio_devices response has a malformed device".to_string()),
                "{malformed}"
            );
        }
        assert_eq!(
            devices_from_response(&json!({ "ok": true })),
            Err("host.audio_devices response missing devices".to_string())
        );
        assert_eq!(
            devices_from_response(&json!({ "ok": false, "error": "CoreAudio error -50" })),
            Err("CoreAudio error -50".to_string())
        );
        assert_eq!(
            devices_from_response(&json!({ "ok": false })),
            Err("host.audio_devices failed".to_string())
        );
    }

    #[test]
    fn volume_replies_carry_a_percent_and_a_mute_state() {
        assert_eq!(
            percent_from_response(&json!({ "ok": true, "percent": 38 })),
            Ok(38)
        );
        assert_eq!(
            muted_from_response(&json!({ "ok": true, "muted": true })),
            Ok(true)
        );
        assert_eq!(
            volume_from_response(&json!({ "ok": true, "percent": 100, "muted": false })),
            Ok(OutputVolume {
                percent: 100,
                muted: false
            })
        );
        for reply in [
            json!({ "ok": true }),
            json!({ "ok": true, "percent": 101, "muted": false }),
            json!({ "ok": true, "percent": -1, "muted": false }),
            json!({ "ok": true, "percent": "38", "muted": false }),
        ] {
            assert_eq!(
                volume_from_response(&reply),
                Err("host.audio_devices response missing percent".to_string()),
                "{reply}"
            );
        }
        assert_eq!(
            volume_from_response(&json!({ "ok": true, "percent": 38 })),
            Err("host.audio_devices response missing muted".to_string())
        );
        assert_eq!(
            percent_from_response(
                &json!({ "ok": false, "error": "audio device does not support output volume" })
            ),
            Err("audio device does not support output volume".to_string())
        );
    }

    #[tokio::test]
    async fn a_volume_step_is_clamped_to_the_scale_and_never_zero() {
        use crate::testing::Harness;
        let mut harness = Harness::new("audio");
        assert_eq!(
            harness.context().step_output_volume(0).await,
            Err("a volume step moves at least one tick".to_string())
        );
        for (ticks, sent) in [(1, 1), (-3, -3), (999, 16), (-999, -16)] {
            let ctx = harness.context();
            let task = tokio::spawn(async move { ctx.step_output_volume(ticks).await });
            let (id, method, params) = harness.next_host_request().await.unwrap();
            assert_eq!(method, "host.audio_devices");
            assert_eq!(params, json!({ "operation": "step_volume", "ticks": sent }));
            assert!(harness.reply_host(id, json!({ "ok": true, "percent": 50 })));
            assert_eq!(task.await.unwrap(), Ok(50));
        }
    }

    #[test]
    fn the_audio_contract_matches_the_shared_protocol() {
        let contract: Value = serde_json::from_str(include_str!("../protocol.json")).unwrap();
        let audio = &contract["audio_devices"];
        assert_eq!(audio["operations"], json!(OPERATIONS));
        let directions: Vec<&str> = AudioDirection::ALL.iter().map(|d| d.as_str()).collect();
        assert_eq!(audio["directions"], json!(directions));
        assert_eq!(audio["max_ticks"], MAX_VOLUME_TICKS);
        assert_eq!(
            contract["methods"]["plugin_to_host_rpcs"]["host.audio_devices"],
            "audio_devices"
        );
        assert!(
            contract["capabilities"]
                .as_array()
                .unwrap()
                .contains(&Value::from("audio_devices"))
        );
    }
}
