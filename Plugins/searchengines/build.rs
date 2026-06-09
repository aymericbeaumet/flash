// Reads the vendored `bangs.tsv` and generates a sorted `BANGS` lookup table
// the plugin binary-searches at runtime. Keeping the table out of the manifest
// lets one catch-all `shebang` provider serve the whole DuckDuckGo bang set
// without enumerating thousands of entries in JSON. Regenerate the data with
// Scripts/update-ddg-bangs.sh.

use std::collections::HashSet;
use std::env;
use std::fs;
use std::path::Path;

fn main() {
    let manifest_dir = env::var("CARGO_MANIFEST_DIR").unwrap();
    let src = Path::new(&manifest_dir).join("bangs.tsv");
    println!("cargo:rerun-if-changed={}", src.display());
    let text = fs::read_to_string(&src).expect("read bangs.tsv");

    // Fields split on whitespace (triggers and URLs never contain spaces), so
    // a hand-aligned file and `jq … @tsv` output both parse. First trigger
    // wins on a duplicate.
    let mut seen = HashSet::new();
    let mut entries: Vec<(String, String)> = Vec::new();
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let mut parts = line.split_whitespace();
        let (Some(trigger), Some(url)) = (parts.next(), parts.next()) else {
            continue;
        };
        let trigger = trigger.to_ascii_lowercase();
        if seen.insert(trigger.clone()) {
            entries.push((trigger, url.to_string()));
        }
    }
    entries.sort_by(|a, b| a.0.cmp(&b.0));

    let mut out = String::from("// @generated from bangs.tsv by build.rs — do not edit.\n");
    out.push_str("pub static BANGS: &[(&str, &str)] = &[\n");
    for (trigger, url) in &entries {
        out.push_str(&format!("    ({}, {}),\n", escape(trigger), escape(url)));
    }
    out.push_str("];\n");

    let dest = Path::new(&env::var("OUT_DIR").unwrap()).join("bangs_generated.rs");
    fs::write(&dest, out).expect("write bangs_generated.rs");
}

fn escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            _ => out.push(c),
        }
    }
    out.push('"');
    out
}
