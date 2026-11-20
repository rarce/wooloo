# herdr-core manual tests

What the unit tests cannot check about herdr-core sessions: real programs, real windows and real hosts. It covers the exit criteria left in the [backend plan](proposals/herdr-core-backend.md#phases) for phases 3 to 6, and what changed after the last manual pass (PR #159 at `6fb310f`), including the review fixes that came after it.

It is written for an agent or a person driving the development build. Record each result in [Results](#results) with a screenshot, and report failures with the steps, what happened, and the app's log.

> Never use the `default` Herdr or herdr-core session, nor your main one, and never the installed wooloo (`dev.wooloo.app`). Everything here uses the `wooloo-ui-test` session and a test build with its own bundle identifier, `dev.wooloo.core-review`.
>
> Before typing into any window, read its connection in the status bar at the bottom (`Local · wooloo-ui-test …`). If a window shows another session, send it no input: close it, record what opened it, and go on with the remaining cases.

## 0. Requirements

- macOS 14 or later with Xcode 26.
- herdr-core 0.1.21 (`hc --version`) on the `PATH`, from the [official installer](https://herdr.dev/core).
- A way to see the app's windows and send clicks, keys and the scroll wheel to it, plus `screencapture` for screenshots.
- Optional: an SSH host (Linux or macOS) for section 8, and a second Mac for section 9.

## 1. Preparation

```sh
cd ~/devel/wooloo
git fetch && git switch --detach origin/main   # or the commit you were asked to test
git log -1 --oneline                            # record it in Results

xcodebuild -project wooloo.xcodeproj -scheme wooloo -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/core-review \
  WOOLOO_APP_BUNDLE_IDENTIFIER=dev.wooloo.core-review build

APP=build/core-review/Build/Products/Debug/wooloo.app
export HC_SESSION=wooloo-ui-test

# A clean test app, with herdr-core support on
pkill -f 'core-review.*MacOS/wooloo'
defaults delete dev.wooloo.core-review 2>/dev/null
defaults write dev.wooloo.core-review WoolooHerdrCoreConnections -bool true
rm -rf ~/Library/Saved\ Application\ State/dev.wooloo.core-review.savedState

mkdir -p /private/tmp/wooloo-core-review
open -n "$APP" --env WOOLOO_DISABLE_UPDATES=1
```

In the setup wizard:
1. Choose **Use herdr-core (preview)**. It shows "Found herdr-core at …".
2. In **Session**, enter `wooloo-ui-test`.
3. Click **Connect to herdr-core**. Create a Space on `/private/tmp/wooloo-core-review` if asked.

To send output to a pane from outside the app:
```sh
hc ls          # the address (tN) of the pane's terminal
T=t1           # that address
hc send $T 'for i in $(seq 1 300); do echo "line $i marker"; done'
```

The kitty image helper, used in section 4:
```sh
cat > /private/tmp/wooloo-core-review/icat.sh <<'EOF'
#!/bin/zsh
# icat.sh FILE: sends FILE as a kitty graphics image (f=100, "PNG"), in 4096-byte chunks.
data=$(base64 < "$1" | tr -d '\n'); first=1
while [[ -n $data ]]; do
  chunk=${data[1,4096]}; data=${data[4097,-1]}; more=$([[ -n $data ]] && echo 1 || echo 0)
  if (( first )); then printf '\e_Ga=T,f=100,m=%s;%s\e\\' $more $chunk; first=0
  else printf '\e_Gm=%s;%s\e\\' $more $chunk; fi
done; echo
EOF
chmod +x /private/tmp/wooloo-core-review/icat.sh
cd /private/tmp/wooloo-core-review
sips -s format png  -Z 64 /System/Applications/Calculator.app/Contents/Resources/AppIcon.icns --out test.png  >/dev/null
sips -s format tiff -Z 64 /System/Applications/Calculator.app/Contents/Resources/AppIcon.icns --out test.tiff >/dev/null
sips -s format gif  -Z 64 /System/Applications/Calculator.app/Contents/Resources/AppIcon.icns --out test.gif  >/dev/null
```

## 2. Programs (phase 4)

Run each in a pane of the herdr-core session.

| # | Steps | Expected |
|---|-------|----------|
| 2.1 | `vim -u NONE -c 'set mouse=a' /etc/services`. Move with keys, click lines, drag, use the wheel, `:q` | Correct colours and cursor. A click puts vim's cursor on that cell, a drag selects, the wheel scrolls vim. No error banner |
| 2.2 | `LESS=-R less /etc/services`. Wheel, `/tcp`, `n`, `q` | The wheel moves `less` (alternate screen), not wooloo's scrollback. The screen comes back intact after `q` |
| 2.3 | `htop` (or `top -o cpu` if htop is missing). Resize the window while it runs; in htop, click a column header | It redraws at the new size without stray lines; the click sorts by that column |
| 2.4 | An agent CLI (`claude`, `codex` or another you have): start it, type a short prompt, scroll, resize. Then press ⌃C once and look at the screen, and press it again within a second | Its interface draws and resizes correctly; typing, paste (⌘V) and keys such as ⌥←, ⌃C and Escape reach it. The first ⌃C shows the program's reaction (for Codex, a "press again to quit" hint); the second quits it |
| 2.5 | Wide and combined text: `printf 'añb 漢字 👍🏽 é\n'` | Each character takes its width; nothing overlaps or shifts the rest of the line. 👍🏽 takes 4 cells (the thumb and its skin-tone modifier, 2 each), as zsh counts it, so a wider gap before é is expected |
| 2.6 | `printf '\e[c'` | One reply only (`^[[?62;22c` or similar), no repeated garbage at the prompt |

## 3. Scrollback and find

Fill the scrollback first (section 1).

| # | Steps | Expected |
|---|-------|----------|
| 3.1 | Scroll up with the wheel; run `hc send $T 'echo nueva'` | The view stays where it is |
| 3.2 | While scrolled back, type a letter | The view returns to the bottom and the letter reaches the prompt |
| 3.3 | Open vim with `set mouse=a`, fill it with output, scroll back in wooloo first if possible, then **click** in vim | The first click only returns to the live screen: vim's cursor does not move. The next click moves it |
| 3.4 | With the terminal focused, press **⌘F** and type `marker` at once, without clicking the field | The field holds `marker` and nothing reached the shell's prompt. The newest match is highlighted, "1 of N". Return goes older, Shift-Return newer |
| 3.5 | With a highlighted match, run `hc send $T 'echo a; echo b'` | The highlight follows its text |
| 3.6 | Search `marker`, then type quickly `marker 2`, `marker 29`, `marker 299` | The count always belongs to the last query shown; no stale highlight is left |
| 3.7 | With the find bar open, press **Escape** | The bar closes, the highlight goes, and typing goes straight to the terminal (it has the keyboard back) |
| 3.8 | Split the pane. Find `marker` in the first pane, select the second and find there | Only the second pane is highlighted; the first pane's highlight is gone |
| 3.9 | Find a match that is plain reverse video: `printf '\e[7mreversed\e[0m\n'`, then find `reversed` | The match is still visibly marked (bold and underlined) |
| 3.10 | `hc send $T 'seq 1 200000'`, then find `199999` | The app stays responsive while it searches, and finds it |

## 4. Kitty images

| # | Steps | Expected |
|---|-------|----------|
| 4.1 | `./icat.sh test.png` | The icon appears at the cursor; the prompt continues below it |
| 4.2 | `seq 1 40` | The image moves up with the text and is cut at the pane's top edge |
| 4.3 | Scroll back to it | It shows again at its place |
| 4.4 | `./icat.sh test.tiff` and `./icat.sh test.gif` | **Nothing** is drawn: only PNG is accepted for `f=100`. The terminal keeps working |
| 4.5 | `clear` | The images go with the screen |

## 5. Windows and observers (phase 4)

| # | Steps | Expected |
|---|-------|----------|
| 5.1 | With window A on `wooloo-ui-test` and in front, choose **File → New Window** (window B). Check B's status bar before anything else. Then select the same tab in B, make A front, and run `hc send $T 'echo desde-fuera'` | B opens on `Local · wooloo-ui-test`, the connection of the window it was opened from. B (behind) shows the new output too |
| 5.2 | Make A and B different sizes; switch which is front | The terminal takes the front window's size each time; the other draws it without wrapping garbage |
| 5.3 | Click B and type at once: `echo ahora` + Return | Every key arrives, none lost or doubled |
| 5.4 | With B behind, resize it to be very large (full screen) and come back to A | A keeps its size; nothing in A redraws wrongly |
| 5.5 | In A, close the tab shown; B shows the same tab | Both move to another tab, and the pane the window last used in that tab has the cursor and takes typing |
| 5.6 | Restart the app with both windows open | Both come back on `wooloo-ui-test`; the front one types, the other watches |

## 6. Structure and agents (phase 5)

| # | Steps | Expected |
|---|-------|----------|
| 6.1 | Create a Space, two tabs, split a pane right and down, zoom, rename a tab, move a tab to the other Space | Every change shows at once and is still there after relaunching the app |
| 6.2 | `hc run -- /bin/zsh` from outside | The new terminal shows in **Unfiled** |
| 6.3 | In a pane, `printf '\e]7501;state=working\a'`, then `printf '\e]7501;state=done\a'` (the OSC 7501 syntax is in herdr-core's documentation; adjust if this one is refused) | The Agents list shows the state change; a notification appears if enabled |
| 6.4 | Mark that agent unread, then pinned; check `hc ls --json` (or `hc label`) | The labels `herdr.seen` / `herdr.pinned` change accordingly |
| 6.5 | With two windows (section 5), change the layout in one | The other shows the same arrangement shortly after |

## 7. Connection and recovery (phase 3)

| # | Steps | Expected |
|---|-------|----------|
| 7.1 | `hc server restart` with the app open | The app reconnects without hanging; panes keep working and vim (if open) is intact |
| 7.2 | `hc server stop`, wait 10 s, then start a core again (`hc ls` starts one) | The app shows it is disconnected, then reconnects |
| 7.3 | Turn **Settings → Appearance → herdr-core (preview)** off and on | Off hides the herdr-core connections; on brings them back |
| 7.4 | Check `~/Library/Logs/wooloo/Hangs` and `~/Library/Logs/DiagnosticReports/wooloo-*` | No new hang or crash reports from this session |

## 8. SSH host (optional, phases 3 and 6)

Needs an SSH host you may use, reachable without a password prompt. Its herdr-core session must also be `wooloo-ui-test`.

| # | Steps | Expected |
|---|-------|----------|
| 8.1 | **Manage Connections** → add the host with **herdr-core session (preview)** on, session `wooloo-ui-test`. If the host lacks `hc`, use **Install herdr-core 0.1.21 on This Host…** | The install asks first, puts `hc` in `~/.local/bin` and connects |
| 8.2 | Repeat 2.1, 3.4 and 4.1 there | Same as locally |
| 8.3 | Open files and the Git panel on that connection | They show the host's files |
| 8.4 | Drop the network for 30 s (turn Wi-Fi off and on) | The connection recovers; panes come back |

## 9. Two Macs (optional, phase 5)

Both Macs connect to the same core (one locally, the other through section 8 pointing at it).

| # | Steps | Expected |
|---|-------|----------|
| 9.1 | Change the layout on one Mac | The other shows it |
| 9.2 | Change the layout on both at nearly the same time | Both end with the same arrangement, holding both changes |

## Results

Write the results here, replacing this table's empty cells, and add a short summary above it: the commit tested, the date, herdr-core's version, the counts, and each failure with the steps to reproduce it. Keep screenshots outside the repository (for example in `/private/tmp/wooloo-core-review-shots`, which Cleanup keeps) and name them in the notes.

Previous run: `50090e9`, 2026-11-19 — 15 OK, 2 failed (3.4 typing right after ⌘F reached the shell; 5.1 a new window opened `default`), 7 partial, 18 not run. Both failures are addressed in the commit after it.

Commit tested: `……`  ·  Date: `……`  ·  herdr-core: `……`

| Case | OK / Fail / Partial / Not run | Notes / screenshot |
|------|-------------------------------|--------------------|
| 2.1 | | |
| 2.2 | | |
| 2.3 | | |
| 2.4 | | |
| 2.5 | | |
| 2.6 | | |
| 3.1 | | |
| 3.2 | | |
| 3.3 | | |
| 3.4 | | |
| 3.5 | | |
| 3.6 | | |
| 3.7 | | |
| 3.8 | | |
| 3.9 | | |
| 3.10 | | |
| 4.1 | | |
| 4.2 | | |
| 4.3 | | |
| 4.4 | | |
| 4.5 | | |
| 5.1 | | |
| 5.2 | | |
| 5.3 | | |
| 5.4 | | |
| 5.5 | | |
| 5.6 | | |
| 6.1 | | |
| 6.2 | | |
| 6.3 | | |
| 6.4 | | |
| 6.5 | | |
| 7.1 | | |
| 7.2 | | |
| 7.3 | | |
| 7.4 | | |
| 8.1 | | |
| 8.2 | | |
| 8.3 | | |
| 8.4 | | |
| 9.1 | | |
| 9.2 | | |

## Cleanup

```sh
pkill -f 'core-review.*MacOS/wooloo'
HC_SESSION=wooloo-ui-test hc server stop
defaults delete dev.wooloo.core-review 2>/dev/null
rm -rf /private/tmp/wooloo-core-review
```
