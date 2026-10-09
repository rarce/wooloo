#!/bin/sh
# Writes wooloo/HerdrTitleTables.swift: the character tables of the Rust crates Herdr sizes popup
# titles with (unicode-width 0.2.2 and unicode-segmentation 1.13.3, as ratatui-core 0.1.0 uses
# them), so wooloo draws titles as Herdr does on any macOS version. Needs cargo; downloads the
# two crates into cargo's registry if they are missing. Run it again when Herdr's Cargo.lock
# moves to other versions, then update the versions below and in HerdrTitle.swift.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
width_version=0.2.2
segmentation_version=1.13.3
work=$(mktemp -d /private/tmp/wooloo-title-tables.XXXXXX)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/fetch/src"
cat > "$work/fetch/Cargo.toml" <<EOF
[package]
name = "fetch"
version = "0.0.0"
edition = "2021"
[dependencies]
unicode-width = "=$width_version"
unicode-segmentation = "=$segmentation_version"
EOF
echo 'fn main() {}' > "$work/fetch/src/main.rs"
cargo fetch --quiet --manifest-path "$work/fetch/Cargo.toml"

registry=${CARGO_HOME:-$HOME/.cargo}/registry/src
width_src=$(find "$registry" -maxdepth 2 -type d -name "unicode-width-$width_version" | head -n 1)
segmentation_src=$(find "$registry" -maxdepth 2 -type d -name "unicode-segmentation-$segmentation_version" | head -n 1)
cp -R "$width_src" "$work/uw"
cp -R "$segmentation_src" "$work/us"
chmod -R u+w "$work/uw" "$work/us"

# Expose the private tables the generator reads.
sed -i '' 's/^#!\[deny(missing_docs)\]/#![allow(missing_docs)]/; s/^mod tables;/pub mod tables;/' "$work/uw/src/lib.rs"
sed -i '' 's/^struct WidthInfo(u16);/pub struct WidthInfo(pub u16);/; s/^fn lookup_width(c: char)/pub fn lookup_width(c: char)/; s/^static NON_TRANSPARENT_ZERO_WIDTHS/pub static NON_TRANSPARENT_ZERO_WIDTHS/' "$work/uw/src/tables.rs"
sed -i '' 's/^#!\[deny(missing_docs, unsafe_code)\]/#![allow(missing_docs)]/; s/^mod tables;/pub mod tables;/' "$work/us/src/lib.rs"

mkdir -p "$work/gen/src"
cat > "$work/gen/Cargo.toml" <<EOF
[package]
name = "gen"
version = "0.0.0"
edition = "2021"
[dependencies]
unicode-width = { path = "../uw" }
unicode-segmentation = { path = "../us" }
EOF
cat > "$work/gen/src/main.rs" <<'EOF'
use unicode_segmentation::tables::{derived_property::InCB_Extend, grapheme::grapheme_category, is_incb_linker};
use unicode_width::tables::*;

fn chars() -> impl Iterator<Item = char> {
    (0u32..=0x10FFFF).filter_map(char::from_u32)
}

/// Starts of the runs of equal values, as `start << 8 | value`.
fn runs(name: &str, doc: &str, value: impl Fn(char) -> u32) {
    let mut entries = Vec::new();
    let mut last = None;
    for c in chars() {
        let v = value(c);
        assert!(v < 256);
        if last != Some(v) {
            entries.push((c as u32) << 8 | v);
            last = Some(v);
        }
    }
    emit(name, doc, &entries);
}

/// A set as flattened inclusive ranges.
fn set(name: &str, doc: &str, member: impl Fn(char) -> bool) {
    let mut entries: Vec<u32> = Vec::new();
    let mut open: Option<u32> = None;
    let mut previous = 0;
    for c in chars() {
        let cp = c as u32;
        if member(c) {
            if open.is_none() || cp != previous + 1 {
                if let Some(start) = open { entries.extend([start, previous]); }
                open = Some(cp);
            }
            previous = cp;
        }
    }
    if let Some(start) = open { entries.extend([start, previous]); }
    emit(name, doc, &entries);
}

fn emit(name: &str, doc: &str, entries: &[u32]) {
    println!("    /// {doc}");
    println!("    static let {name}: [UInt32] = [");
    for row in entries.chunks(8) {
        let items: Vec<String> = row.iter().map(|v| format!("0x{v:08X}")).collect();
        println!("        {},", items.join(", "));
    }
    println!("    ]\n");
}

fn main() {
    let mut classes: Vec<(u8, u16)> = Vec::new();
    let mut class_of = |c: char| -> u32 {
        let (width, info) = lookup_width(c);
        let key = (width, info.0);
        let index = classes.iter().position(|k| *k == key).unwrap_or_else(|| {
            classes.push(key);
            classes.len() - 1
        });
        index as u32
    };
    let width_runs: Vec<u32> = {
        let mut entries = Vec::new();
        let mut last = None;
        for c in chars() {
            let v = class_of(c);
            if last != Some(v) {
                entries.push((c as u32) << 8 | v);
                last = Some(v);
            }
        }
        entries
    };
    let (major, minor, patch) = unicode_width::UNICODE_VERSION;
    println!("// Unicode {major}.{minor}.{patch} data (Unicode License V3). Do not edit.\n");
    println!("extension HerdrTitle {{");
    println!("    /// `lookup_width` results as `width | WidthInfo << 8`, indexed by `widthRuns`.");
    println!("    static let widthClasses: [UInt32] = [");
    for row in classes.chunks(8) {
        let items: Vec<String> = row.iter().map(|(w, i)| format!("0x{:06X}", (*w as u32) | (*i as u32) << 8)).collect();
        println!("        {},", items.join(", "));
    }
    println!("    ]\n");
    emit("widthRuns", "Runs of `lookup_width`, as `start << 8 | widthClasses index`.", &width_runs);
    runs("graphemeRuns", "Runs of `grapheme_category`, as `start << 8 | GraphemeCategory raw value`.", |c| grapheme_category(c).2 as u32);
    set("emojiPresentationStarts", "`starts_emoji_presentation_seq`.", starts_emoji_presentation_seq);
    set("textPresentationStarts", "`starts_non_ideographic_text_presentation_seq`.", starts_non_ideographic_text_presentation_seq);
    set("emojiModifierBases", "`is_emoji_modifier_base`.", is_emoji_modifier_base);
    set("nonTransparentZeroWidths", "`NON_TRANSPARENT_ZERO_WIDTHS`.", |c| {
        let cp = c as u32;
        NON_TRANSPARENT_ZERO_WIDTHS.iter().any(|(lo, hi)| {
            let lo = u32::from_le_bytes([lo[0], lo[1], lo[2], 0]);
            let hi = u32::from_le_bytes([hi[0], hi[1], hi[2], 0]);
            (lo..=hi).contains(&cp)
        })
    });
    set("conjunctLinkers", "`is_incb_linker`.", is_incb_linker);
    set("conjunctExtends", "`InCB_Extend`.", InCB_Extend);
    println!("}}");
}
EOF
# Write next to the generator and move into place only once it succeeded.
output=$work/HerdrTitleTables.swift
{
    echo "// Generated by scripts/herdr-title-tables.sh from unicode-width $width_version and"
    echo "// unicode-segmentation $segmentation_version (MIT OR Apache-2.0), see Vendor/HerdrTitle/LICENSES.txt."
    cargo run --quiet --release --offline --manifest-path "$work/gen/Cargo.toml"
} > "$output"
mv "$output" "$root/wooloo/HerdrTitleTables.swift"
echo "Wrote $root/wooloo/HerdrTitleTables.swift"
