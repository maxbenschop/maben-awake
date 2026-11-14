# Changelog

Every release of Maben Awake. The newest version is at the top. `release.sh` uses the section for the version it
builds as the GitHub release notes, the app shows it under About, and awake.maben.gg/changelog is built from this file.

## 1.7.1 · not released yet

- The menu no longer scrolls a tiny bit when everything in it fits.

## 1.7 · 14 November 2026

- Uses much less CPU: with the lid open and the menu closed, Maben Awake no longer checks every app every 3 seconds or redraws the closed menu every second.
- Freezes more of a frozen app: the helpers macOS starts for it, such as the page processes of browsers built on WebKit, are frozen with it.
- When you open the lid after the screen was kept unlocked, the screen locks, so whoever opens it has to log in. You can turn this off in Settings, Lid & Power.
- New option: freeze apps while the screen is locked. On by default on Macs without a lid, such as a Mac mini or iMac.
- Back at the Mac, the menu shows what happened while you were away: how long the Mac stayed awake, which agents worked, and the battery used.
- If an update keeps crashing, Maben Awake goes back to the version before it by itself.
- Opening the lid or unlocking the screen wakes frozen apps straight away.
- `awake status` checks that everything is set up.

## 1.6 · 11 November 2026

- Work an AI leaves running in the background, such as a build, tests or a server, keeps the Mac awake until it finishes, up to 8 hours after the AI's last turn. The AI no longer has to ask with `awake run`. This needs Claude Code; other agents keep the 30 minutes from before. While only background work is left, apps stay frozen and the menu doesn't say an AI is working.
- A frozen app wakes when an AI's command uses it in more ways: through System Events, JavaScript for Automation, quitting it, `pkill` or `killall`, its bundle ID or its `.app`. Opening a link wakes the default browser if it's frozen. These only ever wake an app that is frozen.
- If a command fails or times out while apps are frozen, Claude Code is told which apps are frozen. An app the error itself names is woken straight away, so trying again works.
- An app the AI is building (one running from outside Applications) is no longer quit when the AI is done with it.
- `awake list` shows which apps are frozen.
- Claude Code hooks from an earlier version get the new failure hook by themselves.

## 1.5 · 10 November 2026

- Works with nine more agents: Cursor, Gemini CLI, GitHub Copilot (in the terminal and in VS Code), OpenCode, Qwen Code, Droid, Devin, Augment and Kiro. Settings shows the ones set up on your Mac, each with a Connect button.
- Cursor, Droid, Devin, Augment and Kiro are marked Not tested yet: they are built from their documentation. If one doesn't keep your Mac awake, tell us on the support page.
- If you use Codex: it asks to review the hooks again after this update. Run `/hooks` in Codex once.
- The menu names the agent that is working, such as Cursor is working.
- An app woken with `awake need` inside any of these agents freezes again when that agent's turn ends, as with Claude Code.
- Two Codex sessions started within a minute of each other no longer share one request.
- The app no longer uses its old name, Sleepwalker, for its files. Requests, logs, hooks and the launch agent move to Maben Awake names by themselves; the lid-open failsafe asks for your password once to do the same.

## 1.4.1 · 10 November 2026

- Checks for updates when the Mac wakes, if the last check was more than 6 hours ago, so a Mac that sleeps most of the day still updates promptly.

## 1.4 · 10 November 2026

- Updates itself from GitHub. Settings has an Update button, and new versions can install automatically while the lid is open and no agent is working.
- The menu bar icon turns green when an update is waiting.
- Settings redesigned in the Maben style: faster, shorter text, one accent colour, and ⌘1–⌘5 to switch pages.
- The menu uses the same dark Maben look.

## 1.3 · 9 November 2026

- New freeze icon, a crystal snowflake, the same as on the website.

## 1.2 · 9 November 2026

- New icon: the Maben mark on green, the same green as the website.

## 1.1 · 9 November 2026

- Works with OpenAI's Codex: connect it in Settings, then run `/hooks` in Codex once to trust the hooks. Codex shows as Codex is working in the menu.
- A Codex turn you interrupt releases its request straight away.

## 1.0 · 9 November 2026

First public version.

- Keeps the Mac awake while Claude Code works, through hooks you install from Settings.
- The `awake` command for other tools and scripts: `run`, `hold`, `need`, `list` and `log`.
- With the lid closed: stays awake, freezes apps no agent is using, sets the screen to brightness 0 and keeps it unlocked.
- Lets the Mac sleep below 20% battery, or when it gets seriously hot.
- Restarts itself after a crash, and a separate service brings the screen and apps back when you open the lid, even if the app hangs.
- Asks to be moved to Applications when opened from Downloads.
- Runs on Apple silicon and Intel, macOS 13 or later. Signed and notarized by Apple.
