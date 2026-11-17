//! Data-only operations whose AppleScript templates belong to the host.
use serde::Serialize;

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "operation", rename_all = "snake_case")]
pub enum AppleScriptOperation {
    BrowserTabs {
        bundle_id: String,
    },
    BrowserSelect {
        bundle_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        url: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        title: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        window: Option<usize>,
        #[serde(skip_serializing_if = "Option::is_none")]
        tab: Option<usize>,
    },
    BrowserTabIndex {
        bundle_id: String,
        index: i64,
    },
    BrowserTabMove {
        bundle_id: String,
        forward: bool,
    },
    ShortcutsList,
    ShortcutRun {
        name: String,
    },
    ChatSubmit {
        bundle_id: String,
    },
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn operations_match_the_wire_contract_and_contain_no_source() {
        let bundle_id = "com.apple.Safari".to_string();
        let operations = [
            AppleScriptOperation::BrowserTabs {
                bundle_id: bundle_id.clone(),
            },
            AppleScriptOperation::BrowserSelect {
                bundle_id: bundle_id.clone(),
                url: Some("https://example.com".into()),
                title: None,
                window: None,
                tab: None,
            },
            AppleScriptOperation::BrowserTabIndex {
                bundle_id: bundle_id.clone(),
                index: 1,
            },
            AppleScriptOperation::BrowserTabMove {
                bundle_id: bundle_id.clone(),
                forward: true,
            },
            AppleScriptOperation::ShortcutsList,
            AppleScriptOperation::ShortcutRun {
                name: "A\\B\"C".into(),
            },
            AppleScriptOperation::ChatSubmit { bundle_id },
        ];
        let values: Vec<serde_json::Value> = operations
            .iter()
            .map(|value| serde_json::to_value(value).unwrap())
            .collect();
        let names: Vec<_> = values
            .iter()
            .map(|value| value["operation"].clone())
            .collect();
        let contract: serde_json::Value =
            serde_json::from_str(include_str!("../protocol.json")).unwrap();
        assert_eq!(
            serde_json::json!(names),
            contract["applescript"]["operations"]
        );
        assert!(values.iter().all(|value| value.get("script").is_none()));
    }
}
