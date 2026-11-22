# herdr-core manual tests

What the unit tests cannot check about herdr-core sessions: real programs, real windows and real hosts. It covers the exit criteria left in the [backend plan](proposals/herdr-core-backend.md#phases) for phases 3 to 6, and what changed after the last manual pass (PR #159 at `6fb310f`), including the review fixes that came after it.

It is written for an agent or a person driving the development build. Record each result in [Results](#results) with a screenshot, and report failures with the steps, what happened, and the app's log.

> Never use the `default` Herdr or herdr-core session, nor your main one, and never the installed wooloo (`dev.wooloo.app`). Everything here uses the `wooloo-ui-test` session and a test build with its own bundle identifier, `dev.wooloo.core-review`.
>
> Before typing into any window, read its connection in the status bar at the bottom (`Local · wooloo-ui-test …`). If a window shows another session, send it no input: close it, record what opened it, and go on with the remaining cases.
>
> Open the test app only as section 1 does, after its `defaults write`, and never after Cleanup. Launched without those preferences, it saves its window on the `default` session, and a later launch may reopen that window there.

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
| 2.4 | An agent CLI (`claude`, `codex` or another you have): start it, type a short prompt, scroll, resize. Then press ⌃C once and look at the screen, and press it again within a second. Press ⌃C on the physical keyboard: an automation tool's synthetic ⌃C may arrive as a plain `c` | Its interface draws and resizes correctly; typing, paste (⌘V) and keys such as ⌥←, ⌃C and Escape reach it. The first ⌃C shows the program's reaction (for Codex, a "press again to quit" hint); the second quits it |
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
| 5.6 | Restart the app with both windows open | The windows come back on `wooloo-ui-test` as macOS's "Close windows when quitting an application" setting says (with it on, the default, only the front one); the front one types, the other watches |

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
| 7.2 | `hc server stop`, wait 10 s, then start a core again (`hc ls` starts one) | The app reconnects, starting the core again if it is still stopped. Panes wooloo created come back at the same address with a fresh shell; terminals started elsewhere follow their own keep setting |
| 7.3 | Turn **Settings → Appearance → herdr-core (preview)** off and on | Off hides the herdr-core option for new connections (Manage Connections and setup); connections already made stay. On brings the option back |
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

Previous run: `50090e9`, 2026-11-19 — 15 OK, 2 failed (3.4 typing right after ⌘F reached the shell; 5.1 a new window opened `default`), 7 partial, 18 not run. Both failures are addressed in the commit after it.

Attempt: `d03fa6d`, 2026-11-20 — no results. Run through `codex exec` with stdin closed, Computer Use was denied access to the app, so no case that needs the window could be checked. Run it from an interactive Codex session and approve access to wooloo when asked.

Commit tested: `d2187b0` (application source identical to `d03fa6d`; only this test plan changed) · Date: 2026-11-20 · herdr-core: 0.1.21

macOS 26.6.2 (25G83), Xcode 26.6 (17F113). 23 OK, 6 Fail, 7 Partial, 6 Not run. Build succeeded. Failure steps and observations are in the corresponding rows. Screenshots, the filtered app logs (app.log and app-errors.log), and the hang report are in `/private/tmp/wooloo-core-review-shots`.

Review of this run: 3.4 (the terminal took the keyboard back before the field showed, or the keyboard was released from the key window instead of the window the command ran in) and 3.8 (the bar did not search again when the selected pane changed) are addressed in the commit after it. 7.3 is not a failure: the setting affects new connections only, and its expected result is corrected above. 2.4 is not an app failure: Computer Use sent `c` instead of ⌃C. The hang in 7.4 happened while quitting after the tab drag of 6.1, and 5.6 lost its second window in that same quit; both, and the Connected label in 7.2, are in `TODO.md`.

| Case | OK / Fail / Partial / Not run | Notes / screenshot |
|------|-------------------------------|--------------------|
| 2.1 | OK | Vim opened /etc/services, accepted movement and clicks, selected text on drag, scrolled and quit. vim-click.png, vim-drag.png, vim-wheel.png |
| 2.2 | OK | Wheel moved less, /tcp and n highlighted matches, and q restored the shell. less-wheel.png, less-search.png, less-exit.png |
| 2.3 | Partial | htop redrew after window zoom. Clicked CPU%, but did not establish the resulting sort order independently. htop-resized.png, sort-cpu.png |
| 2.4 | Fail | With Codex at its prompt, type a draft, paste a second word, move left and send Control-C twice. Computer Use inserted literal c characters, with no quit hint or exit. Repeated with Control_L+c. Physical-keyboard behavior remains unverified. ctrl-first.png, ctrl-double.png |
| 2.5 | OK | The accented Latin characters, CJK pair and modified emoji displayed without overlap. The gap after the emoji was visible. width.png |
| 2.6 | OK | One device-attributes response appeared at the prompt. device.png |
| 3.1 | OK | The same numbered lines stayed in view after external echo nueva. scroll-before.png, scroll-after.png |
| 3.2 | OK | Typing x returned to the live prompt with x after the new output. scroll-live.png |
| 3.3 | Partial | In mouse-enabled Vim the wheel was routed to Vim. Could not establish wooloo scrollback above the live alternate screen to distinguish the first click. vim-first-before.png, vim-first-click.png |
| 3.4 | Fail | Focus zsh, print 300 marker lines, press ⌘F and immediately type marker without clicking. The search field stayed empty and the shell draft contained marker, wrapped across two lines. find-focus.png |
| 3.5 | OK | After external echo a and echo b, the highlight stayed on 199999 as it moved up. highlight-before.png, highlight-after.png |
| 3.6 | OK | Typed marker 2 then appended 9 twice. Final query marker 299 showed 1 of 1 on the correct row. incremental.png |
| 3.7 | OK | Escape removed the bar and highlight. The following x reached the terminal application. find-escape.png |
| 3.8 | Fail | Split a tab, print marker text in both panes, find marker on the left, click the right pane and search again in the open field. The left match and count (1 of 301) remained. Closing and reopening Find on the right moved the highlight there (1 of 3). left-selected.png, right-selected.png, right-reopened.png |
| 3.9 | OK | The newest of two reversed matches was the reverse-video output and had a visible underline. reverse-shell.png |
| 3.10 | OK | Sent seq 1 200000 externally to t15. Find remained interactive and visibly marked 199999, 1 of 1. large-final.png |
| 4.1 | OK | Calculator icon appeared with a working prompt underneath. kitty-png.png |
| 4.2 | OK | After seq 1 40 the icon had left the pane. Repeated with 14–18 lines to capture progressively tighter clipping at the top. clip14.png, clip16.png, clip18.png |
| 4.3 | OK | Scrolling back past the first numbered line revealed the icon above the command. kitty-up4.png, kitty-up5.png |
| 4.4 | OK | TIFF and GIF drew no icon. A subsequent echo printed alive. kitty-reject.png |
| 4.5 | OK | Cleared the screen while the PNG was visible. The live screen contained only the new prompt. before-clear.png, after-clear.png |
| 5.1 | OK | ⌘N opened B on Local · wooloo-ui-test. With A in front and both showing t15, B displayed desde-fuera from hc send without activation. new-window.png, observer-cleared.png |
| 5.2 | OK | Core reported 57 × 29 for A and 57 × 20 for B after switching focus. The visible shell output stayed legible. observer-cleared.png, switch-input.png |
| 5.3 | OK | Activated B from the Window menu and typed echo ahora. Core history contained one complete command and one output line. switch-input.png |
| 5.4 | Partial | Enlarged B and switched back to A. A retained its geometry. Resizing B while it remained behind A was not verified. front-original.png |
| 5.5 | Partial | Both windows switched to the remaining split tab after confirming Close. Sent distinct focus markers from each window. The prior cursor position for each window was not established for comparison. closed-A.png, closed-B.png |
| 5.6 | Fail | Leave two windows open, quit with ⌘Q, then reopen the same test bundle. After startup the Window menu listed only one wooloo window and Merge All Windows was disabled. The sole window was on the isolated session. restored-front.png |
| 6.1 | Partial | Created Spaces and tabs, split right and down, zoomed, and renamed review-layout. Spaces, tabs, name and split layout survived relaunch. After dragging the tab, the original Space still listed it. Could not verify that the drag reached the intended destination. drag-source.png, restored-layout.png |
| 6.2 | OK | Ran hc run -- /bin/zsh externally. A selected zsh tab appeared under Unfiled on the isolated connection. new-window.png |
| 6.3 | Partial | A foreground child emitted working then done with app=review. The sidebar showed working then idle in the focused pane. hc get confirmed done. Notification delivery was not verified. agent-working.png, agent-done.png |
| 6.4 | OK | Chose Mark as Unread then Pin Agent. hc get t1b returned herdr.seen=0 and herdr.pinned=1. agent-pinned.png |
| 6.5 | OK | Created splits in B, selected that tab in A and observed the same arrangement in both windows. layout-A.png, layout-B.png |
| 7.1 | OK | Restarted the isolated server with Vim open. Core still reported live Vim. The app accepted input, quit Vim and printed restart-ok. vim-restarted.png, restart-ok.png |
| 7.2 | Partial | Stopped the server, waited at least 10 s, ran hc ls and opened a fresh shell. The new shell accepted input. The intermediate screen said Connecting terminal… while the sidebar still said Connected. A disconnected state was not observed. server-stopped.png, reconnected-input.png |
| 7.3 | Fail | Turn preview off in Appearance, then open Connections. The existing wooloo-ui-test herdr-core row is still listed as connected. The new-connection form correctly hid its core checkbox and restored it when switched on. The setting itself says it applies to new connections. preview-off.png, connections-off.png, preview-on.png |
| 7.4 | Fail | After the multiwindow split, drag and quit sequence, inspect the hang directory. A new report was written at 14:30:05 UTC by PID 59525, the initial test build. No new wooloo crash report was found. The triggering action was not isolated. hang-2026-11-20-143005.txt |
| 8.1 | Not run | No SSH host available. |
| 8.2 | Not run | No SSH host available. |
| 8.3 | Not run | No SSH host available. |
| 8.4 | Not run | No SSH host available. |
| 9.1 | Not run | No second Mac available. |
| 9.2 | Not run | No second Mac available. |

### Retest at `09d6d0a`

2026-11-20 · **1 OK, 3 Fail, 0 Partial, 0 Not run.** Screenshots are in `/private/tmp/wooloo-core-review-shots/retest`.

| Case | OK, Fail, Partial or Not run | Notes and screenshots |
|------|-----------------------------|-----------------------|
| 3.4 | Fail | Clicked the title bar and terminal, pressed ⌘F and immediately typed `marker`. Attempt 1 left the field empty with no count; the shell draft read `arker`. Focused the field to close it with Escape, clicked the terminal and repeated. Attempt 2 again showed an empty field and no count; the shell draft now read `arkerarker`. Both attempts dropped the initial `m` from the visible draft. `3-4-1.png`, `3-4-2.png`. |
| 3.8 | OK | With Find open on the left, the field showed `marker` and “1 of 17”. A single click inside the right pane changed the count to “1 of 3” without retyping. The left highlight cleared and the right pane highlighted its third line. `3-8-left.png`, `3-8-right.png`. |
| 5.6 | Fail | Verified both windows on the test session and counted two entries in the Window menu. No drag preceded ⌘Q. The process exited about 0.11 s after the shortcut was requested. Reopened with the preparation command, retaining preferences. Only one window returned, on `Local · wooloo-ui-test`; the Window menu listed one entry and disabled Merge All Windows. `5-6-before.png`, `5-6-restored.png`. |
| 7.2 | Fail | After `hc server stop`, the sidebar indicator still said “Connected”, the pane said “This tab has no panes”, and the status bar said “Connecting terminal…”. The same state remained after ten seconds. `hc ls` returned zero live terminals and the original pane remained unavailable for input. A fresh zsh appeared without relaunching wooloo and printed `retest-recovered` from keyboard input. `7-2-ten-seconds.png`, `7-2-after-ls.png`, `7-2-fresh-input.png`. |

### Local verification after the fixes

2026-11-20, working tree based on `09d6d0a`, macOS 26.6.2, hc 0.1.21. Screenshots are in `/private/tmp/wooloo-core-review-shots/repair`.

| Case | Result | Observation |
|------|--------|-------------|
| 3.4 | OK | On both attempts, typing immediately after ⌘F put the complete word in the field. Closing with Escape and repeating showed `marker`, 1 of 17. `find-1.png`, `find-2.png`. |
| 5.6 | OK | After ⌘Q and relaunch, Window listed two wooloo windows, both on the isolated connection. `restored.png`, `restored-second.png`. |
| 7.2 | OK for a wooloo-created shell | Ten seconds after stop, the sidebar and status bar showed Disconnected and the pane said it was waiting for the named core. After `hc ls`, the same address (`t1q`) accepted input and printed `recovered-original-pane`. Core starts a replacement shell on a kept terminal after an explicit stop. External terminals use their creator’s keep policy. `disconnected.png`, `recovered.png`. |

Review of these fixes: the ⌘F field, the Disconnected and empty states and `keep` for terminals wooloo creates are kept. Two parts were left out. Reconnecting straight to the core's socket (read from hc's `core.lock`) depended on an hc-internal file and stopped wooloo from restarting a core that went away, so wooloo again reconnects through `hc connect`. Registering `NSQuitAlwaysKeepsWindows` overrode the system's quit setting for every user; 5.6 now expects that setting to be followed. Retest 3.4 and 7.2 with the next commit.

### Retest at `6e9d04c`

2026-11-21 to 2026-11-22 · **4 OK, 0 Fail, 0 Partial, 0 Not run.** Screenshots are in `/private/tmp/wooloo-core-review-shots/retest2`.

| Case | OK, Fail, Partial or Not run | Notes and screenshots |
|------|-----------------------------|-----------------------|
| 3.4 | OK | On both attempts, typing immediately after ⌘F put all of `marker` in Find and left the shell prompt clear. Both started at 1 of 301. Return moved to 2 of 301 and Shift-Return returned to 1 of 301. Escape closed Find between attempts. `3-4-first.png`, `3-4-second.png`. |
| 5.6 | OK | Desktop & Dock showed “Close windows when quitting an application” on. The Window menu listed two windows before ⌘Q and one after relaunch, as expected. The restored window showed `Local · wooloo-ui-test` and accepted `echo restored-input`. `5-6-before.png`, `5-6-restored.png`. |
| 7.2 | OK | Stopped the isolated core with the wooloo-created pane `t1s` selected. By the first observation the sidebar already said Connected, the status bar showed `Local · wooloo-ui-test Space`, and the pane showed a shell. The same state persisted ten seconds later. No disconnected frame was captured. Before any further hc command, the pane accepted `echo original-pane-recovered`. A subsequent `hc read t1s` confirmed its output at the original address. `7-2-stop.png`, `7-2-ten.png`, `7-2-input.png`. |
| Extra · normal exit | OK | Typed `exit` and Return in `t1s`. Its tab closed, leaving one zsh tab. `hc ls` showed only `t1q` live and one finished terminal. `extra-exit.png`. |

### SSH to OrbStack on 2026-11-22

Tested application code at `bd96a05` against a Debian arm64 container with herdr-core 0.1.21 and session `wooloo-ui-test`. The GUI connection attempt used the keyboard-fix build at `6581864`. All four SSH cases were partially verified. Two second-Mac cases were not run. The service checks used a test host process and produced logs rather than window screenshots.

| Case | Result | Observation |
|---|---|---|
| 8.1 | Partial | Added the container profile in Manage Connections. The direct OrbStack hostname gave the app “No route to host”. Via a loopback SSH forward, Wooloo's installer installed the pinned executable at `/home/review/.local/bin/herdr-core`. Wooloo's backend then created a Space and read a fixture through its remote terminal. The install confirmation was not exercised in the GUI. |
| 8.2 | Partial | The window store opened remote vim on /etc/services, observed mouse reporting, sent click, arrow and wheel input, and returned to the shell after :q. Its search found at least 30 remote markers, and its terminal surface contained a kitty PNG. Physical gestures, the find field and the drawn image were not checked visually. |
| 8.3 | Partial | The file and repository services used by the two panels found the remote Git root and read the expected fixture bytes. The visible panels were not checked. |
| 8.4 | Partial | With a real remote pane attached, closed the loopback SSH forward for 30 seconds. The window's store reported disconnection, reconnected automatically and presented the same pane ID. The test observed store and surface state directly. |
| 9.1–9.2 | Not run | A second Mac was unavailable for this run. |

Local logs: `/private/tmp/wooloo-ssh-probe.log`, `/private/tmp/wooloo-ssh-terminal.log` and `/private/tmp/wooloo-ssh-recovery2.log`.

## Cleanup

```sh
pkill -f 'core-review.*MacOS/wooloo'
HC_SESSION=wooloo-ui-test hc server stop
defaults delete dev.wooloo.core-review 2>/dev/null
rm -rf /private/tmp/wooloo-core-review
```

Do not open the test app again after this (see the note at the top).
