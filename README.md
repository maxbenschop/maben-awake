# Sleepwalker

A tiny macOS menu bar app: keep the Mac awake for the apps your AI agent needs
(T3 Code, Dia, Docker…) and freeze everything else so it uses no CPU.

<p>
  <img src="docs/screenshots/menu-busy-light.png" width="300" alt="Menu">
  <img src="docs/screenshots/menu-busy-dark.png" width="300" alt="Menu in dark mode">
</p>

## Build & install

```sh
./build.sh install    # builds, copies to /Applications, launches
```

Needs Xcode command line tools (`xcode-select --install`). macOS 13+.

## How it works

- **Keep Mac awake** – holds a `PreventUserIdleSystemSleep` power assertion.
  The display still turns off; only the system stays up.
- **Only while a checked app is running** – the assertion is released as soon
  as none of your checked apps are running, so the Mac sleeps normally again.
- **Freeze unneeded apps while lid is closed** – only with the lid closed,
  apps that no AI needs are sent `SIGSTOP` (with their helper processes). They
  use zero CPU. Opening the lid thaws everything. Apps that are still starting
  up (first 15 s) are never frozen. Everything is also resumed when you quit
  Sleepwalker, and a fresh start thaws anything a crashed instance left frozen.
- **Screen brightness to 0 while lid is closed** – the previous brightness is
  saved and restored when the lid opens (or at next launch if the app died).
- Per-app modes – your choices are remembered per app (by bundle ID).
- **Launch at login** – in Settings; enabled automatically on first run.

## Menu and Settings

The menu shows what's keeping the Mac awake, a switch to keep it awake by
hand, quick toggles (freeze apps, dim screen, lid closed), active AI requests
with live countdowns, and every running app with its mode.

**Settings…** (⌘,) has these tabs:

| Tab | What's there |
|---|---|
| General | manual keep-awake, "only while an Always on app runs", open at login |
| Apps | modes for running *and* remembered apps, search, reset per app or all |
| Lid & Power | lid-closed mode (or its one-time setup), battery cutoff, freezing, dimming |
| AI | whether the Claude Code hooks and `awake` CLI are installed, active requests, copyable commands, logs |
| About | version |

## Let AI ask for it (`awake` CLI)

`./build.sh install` links an `awake` command and adds Claude Code hooks to
`~/.claude/settings.json`, so **Claude Code and T3 Code keep the Mac awake
automatically while they work and let it sleep again when they stop**:

| Hook | What it does |
|---|---|
| `UserPromptSubmit`, `PreToolUse` | hold a 10‑minute lease named `claude-<session>` (refreshed on every tool call) |
| `Stop`, `SessionEnd` | release the lease |

Leases show up in the menu as *AI requests* with a countdown and an ✕ to
release them by hand. Any script can use the same mechanism:

```sh
awake hold build 30            # keep awake for 30 min
awake release build
awake run tests -- npm test    # keep awake while a command runs
awake list
```

Leases are just files in `~/Library/Application Support/Sleepwalker/leases/`,
so a lease can never outlive its expiry even if the tool crashes.

## Safety

- **Crash safety** – runs as a launchd agent (`~/Library/LaunchAgents/com.maxbenschop.sleepwalker.agent.plist`,
  KeepAlive on crash). If it crashes or is force-killed, launchd restarts it
  within seconds and the new instance thaws every frozen app and restores
  the sleep and brightness settings. Quit from the menu stays quit.
- **External display** – "away" means lid closed *and* no external display.
  In clamshell mode (lid closed, external monitor) nothing is frozen or dimmed.
- **Heat check** – if macOS reports a *serious* or *critical* thermal state
  while you're away, Sleepwalker stops keeping the Mac awake so it sleeps and
  cools down (logged in `~/Library/Logs/Sleepwalker.log`). Cleared when you
  open the lid.
- **Never frozen by default** – terminals and editors (where agents run),
  AI apps, calls (Zoom, FaceTime, Teams, Discord, Meet), audio (Music,
  Spotify), password managers, VPNs, sync/backup, Docker/OrbStack/Ollama/LM
  Studio, Messages, Mail. Marked with a shield in the menu; you can still
  change their mode. Apps an AI is running inside are never frozen either.

## Per-app modes

| Mode | Behaviour |
|---|---|
| **Always on** | never frozen |
| **While AI works** | awake while any Claude turn (or `awake run`) is active |
| **When AI asks** (default) | frozen until an AI requests it with `awake need <app>`; frozen again when that AI's turn ends |

When an AI is done with an app **while the lid is closed**, Sleepwalker
cleans up after it: an app that wasn't running when the AI asked for it is
quit again, and in an app that was already open (Chromium browsers like Dia,
Chrome, Arc, Brave, Edge, Vivaldi) only the tabs the AI opened are closed.
If the lid was opened while the AI used the app, nothing is closed, since
you may have opened those tabs yourself.

The Claude Code hooks call `Sleepwalker.app/Contents/MacOS/sleepwalker-hook`,
a small compiled program (~8 ms per call; the old shell hook took ~50–60 ms).
`awake hook` forwards to it. It prints nothing, so it costs Claude no tokens.

Hooks request apps automatically for browser tools (→ default browser),
`docker`/`kubectl` commands, `osascript 'tell application "X"'` and
`open -a X`. Frozen apps are frozen together with their helper processes
(browser tabs, Electron helpers). Hook activity is logged to
`~/Library/Logs/Sleepwalker-hooks.log`.

## Testing

`tests/deep-test.sh` runs a ~2 minute end-to-end test (auto-freeze, helper
processes, CPU while frozen, wake on request, expiry, owner crash, two
requesters, closed-lid power state) and writes a report to the Desktop. `tests/lid-test.sh` checks the real
lid close/open cycle, `tests/cleanup-test.sh` the tab/app cleanup (run it while no other AI
session is using the browser, or its tab checks are correctly skipped),
`tests/hook-equivalence-test.py` compares the compiled hook with the shell
version, and `tests/live-session-test.sh` runs a real headless Claude session.
Dia note: reading page content via AppleScript JavaScript needs Dia launched
with `--enable-applescript-javascript`; the test reads the tab title/URL from
Dia and fetches the text over HTTP instead.

UI snapshots: `swift build && .build/debug/Sleepwalker --snapshot /tmp/snaps`
renders the menu and every Settings tab (light and dark) to PNGs with canned
data. It never starts the real app, so it's safe while Sleepwalker is running.

## Notes

- Frozen apps can't receive network messages or notifications while frozen.
  Don't freeze things like Messages if you want notifications.
- **Lid closed** – macOS ignores normal keep-awake requests when the lid
  closes, so Sleepwalker uses `pmset disablesleep`. Click the *Lid closed…*
  tile in the menu (or *Set Up…* in Settings → Lid & Power) once; it asks for
  your password and installs
  `/etc/sudoers.d/awakekeeper`, which allows only
  `pmset -a disablesleep 0|1` without a password. Closed-lid sleep is blocked
  only while Sleepwalker is keeping the Mac awake, below 10% battery (adjustable
  in Settings) it's re-enabled, and quitting the app always re-enables it. Remove with
  `sudo Resources/install-lid-helper.sh --uninstall`.
- Docker Desktop's actual engine runs in helper processes, not the main app,
  and Sleepwalker only touches regular (Dock-visible) apps, so checking Docker
  is enough.
