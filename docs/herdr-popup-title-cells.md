# Popup title cells: upstream proposal draft

Status: draft only; not submitted upstream. Herdr does not currently expose this contract. wooloo retains its existing title layout and pinned Unicode tables until compatible server support is available.

## Problem

Native surface clients receive `ClientShellPopupSurface.title` as a string and have to reproduce Herdr's ratatui title layout. wooloo currently vendors the `unicode-width` and `unicode-segmentation` tables used by Herdr to match grapheme boundaries, covered cells, clipping, and special Unicode behavior on macOS. Those tables have to be regenerated whenever Herdr changes the crates, and OS Unicode behavior is not an equivalent replacement.

## Proposal

Expose the server-computed popup title cell row, or a capability-negotiated equivalent carrying explicit grapheme widths and covered cells. Define the title origin and clipping room relative to the resolved popup border, and preserve the existing title string for accessibility and older clients. The client should be able to reserve its own final chrome cell (wooloo has a close button) without splitting a wide grapheme.

Use a sparse row indexed from the first cell after the left corner: absent entries leave the border intact; each lead cell carries an occupied column span and explicit continuation entries cannot render independently. A client reserving its last chrome cell should drop a complete span crossing that boundary. Existing CellData.skip is a diff-rendering flag, not an explicit continuation contract. Widths per grapheme alone cannot reproduce cross-grapheme/span width behavior (for example lam-alef). Specify how resizing recomputes the row. Keep wire-generation compatibility: do not append bytes to the existing popup payload without negotiation or a new frame version. Clients lacking the capability should retain the legacy string path.

## Acceptance cases

Compare the server-rendered title with a native surface client for ASCII, CJK, emoji/ZWJ and variation selectors, combining marks, Arabic/lam-alef, Indic conjuncts, tabs and line separators, leading zero-width clusters, and clipping at a wide symbol. Include narrow popup widths and resizing. Existing clients must continue to decode surfaces unchanged. Explicitly decide leading-zero-width behavior: wooloo currently omits unattached leading marks, while the server-computed cells would become authoritative.

## Current state

Inspected the [bundled v0.9.5 protocol](https://github.com/herdrdev/herdr/blob/v0.9.5/src/protocol/wire.rs) and [master at `5608de06`](https://github.com/herdrdev/herdr/blob/5608de0608918aba2f9d501e7793b984a0ca9cfa/src/protocol/wire.rs) on 2026-10-26: `ClientShellPopupSurface` still exposes only `title: String` for the title. This request concerns the native surface protocol, not ordinary popup PTY content or native plugin discovery.
