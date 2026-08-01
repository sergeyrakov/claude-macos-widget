# Claude Usage Bar

A tiny native **macOS menu-bar widget** that shows your **Claude subscription usage** (the same
percentages `claude` shows via `/usage`) in real time — color-coded, always visible, no dock icon.

> ### Supported plans
>
> | Plan | Supported | Notes |
> |------|:---------:|-------|
> | **Max** | ✅ | Verified. |
> | **Pro** | ✅ | Same per-user limits as Max. |
> | **Team** | ⚠️ | Untested; works only if your seat exposes per-user limits. |
> | **Enterprise** | ❌ | **Not supported.** Usage is managed at the org level, so the API returns no per-user limits and the widget just sits at `✦ …`. |
>
> This tool relies on per-user 5-hour / 7-day limits, which only individual subscription plans expose.

```
┌─────────────────────────────────────────────┐
│  … other menu extras …        🟢 5h 27%   🔋 │   ← the menu bar
└─────────────────────────────────────────────┘
        click ↓
   ┌──────────────────────────────────────┐
   │ Claude usage — Max plan   (detected)│
   │ ──────────────────────────────────── │
   │ 7-day (Fable) ●            🟠         │
   │    82% used · resets in 1d 16h       │
   │ 7-day (all models)         🟡         │
   │    60% used · resets in 1d 16h       │
   │ 5-hour session             🟢         │
   │    27% used · resets in 4h 47m       │
   │ Extra-usage credits                  │
   │    $0.00 of $10.00                    │
   │ ──────────────────────────────────── │
   │ Local estimate (from ~/.claude logs) │
   │    Last 7d:  $84.20 · 21.4M tok      │
   │    Last 30d: $312.90 · 88.7M tok     │
   │ ──────────────────────────────────── │
   │ Show in menu bar            ▸        │
   │ Live · updated 14:03:00              │
   │ Refresh now                          │
   │ Quit                                 │
   └──────────────────────────────────────┘
```

- **Colored right in the menu bar** — green → yellow → orange → red as you approach a limit.
- **You pick which number is shown** (5-hour session, 7-day, scoped model, most-constraining, or a local $ estimate) — click **Show in menu bar**.
- **Reads your existing Claude Code login read-only.** It never refreshes or writes any token, so it can never disturb the CLI or log you out.
- **Self-contained.** One Swift binary + one Python helper. No Xcode, no third-party menu-bar host, no dependencies.

---

## Table of contents

- [What it shows](#what-it-shows)
- [Requirements](#requirements)
- [Install](#install)
- [Usage](#usage)
- [How it works](#how-it-works)
- [Security & privacy](#security--privacy)
- [Configuration](#configuration)
- [Troubleshooting](#troubleshooting)
- [Uninstall](#uninstall)
- [Limitations & disclaimers](#limitations--disclaimers)
- [Repository layout](#repository-layout)

---

## What it shows

Two independent sources:

1. **Real subscription limits** (primary) — fetched from Anthropic's usage endpoint, the same data
   behind `claude`'s `/usage` screen. Each limit carries a **percent used**, a **severity** flag, a
   **reset time**, and (for scoped limits) the **model** it applies to. Typical limits:
   - `5-hour session` — the rolling session window
   - `7-day (all models)` — the weekly cap
   - `7-day (<model>)` — a per-model weekly cap (e.g. Opus/Fable), shown when present
2. **Local cost/token estimate** (bonus) — parsed straight from your `~/.claude/projects/**/*.jsonl`
   transcripts. This is an **estimate** from public per-token pricing, useful as a "how hard am I
   leaning on Claude" signal (especially on a flat-rate subscription).

### Color thresholds

The menu-bar number **and** each dropdown limit are colored by usage:

| Usage    | Color     |
|----------|-----------|
| 0–33 %   | 🟢 green   |
| 33–66 %  | 🟡 yellow  |
| 66–90 %  | 🟠 orange  |
| > 90 %   | 🔴 red     |

A `⚠` prefix appears when Anthropic's own API flags a limit as `warning`/`critical` (independent of
the color band).

---

## Requirements

- **macOS 13+** (Ventura or later).
- **Xcode Command Line Tools** — provides `swiftc` (to build) and `/usr/bin/python3` (the agent runtime):
  ```bash
  xcode-select --install
  ```
- **Claude Code** installed and logged in (Pro/Max subscription). The widget borrows its login token.

No Xcode app, no Homebrew, no Python packages required.

---

## Install

```bash
git clone https://github.com/sergeyrakov/claude-macos-widget.git
cd claude-macos-widget
./install.sh
```

`install.sh` builds the app, copies it to `~/Applications/ClaudeUsageBar.app`, registers a
**LaunchAgent** so it starts at login, and launches it now. Re-running it is safe (idempotent).

The widget appears at the right of your menu bar. If it reads `✦ login`, your CLI token is stale —
run `claude` then `/login` once in a Terminal and it lights up automatically.

**Build only, without installing / autostart:**
```bash
./build.sh && open ClaudeUsageBar.app
```

---

## Usage

- **Click the widget** to open the dropdown: every limit with its % and reset countdown, the local
  estimate, and status.
- **Show in menu bar ▸** — choose which metric the bar displays. The choice is remembered across
  restarts (`UserDefaults`, key `menuBarMetric`). Default is **5-hour session**.
  - `5-hour session`
  - `7-day (all models)`
  - `7-day (scoped / binding model)`
  - `Most-constraining (auto)` — whichever limit is highest right now
  - `Today's cost (local estimate)`
- **Refresh now** — forces an immediate poll (handy between the minute-aligned auto-refreshes).
- **Quit** — exits until next login (or run the app again).

---

## How it works

```
        ┌──────────────────────────┐     every 5 min (aligned :00/:05/…)
        │  ClaudeUsageBar (Swift)  │  ───────────────────────────────►  spawns
        │  NSStatusItem menu-bar   │
        └──────────────────────────┘
                    │ runs
                    ▼
        ┌──────────────────────────┐   reads (read-only)   ┌──────────────────────┐
        │   usage_agent.py         │ ────────────────────► │ macOS Keychain item  │
        │   (borrows CLI token)    │                       │ "Claude Code-creds"  │
        └──────────────────────────┘                       └──────────────────────┘
                    │ GET (Bearer token)
                    ▼
        https://api.anthropic.com/api/oauth/usage
                    │ JSON { limits[], spend, ... }
                    ▼
        normalized JSON on stdout ──► Swift renders colored menu bar + dropdown
```

### The two pieces

- **`ClaudeUsageBar.swift`** — an AppKit `NSStatusItem` app (`LSUIElement`, `.accessory` activation
  policy, so no dock icon). It:
  - polls once at launch, then on a timer **aligned to the top of each minute** (re-aligns after
    the Mac wakes from sleep, since timers don't fire while asleep);
  - runs `usage_agent.py`, parses its JSON, and renders the bar + dropdown;
  - draws the menu-bar text as a **non-template `NSImage`** — because `NSStatusItem` ignores
    `attributedTitle` foreground color, rendering colored text as an image is the reliable way to get
    color *in the bar* (not just the dropdown);
  - also scans `~/.claude/projects/**/*.jsonl` for the local cost/token estimate, caching parsed
    results per-file by size+mtime so repeated scans are cheap.

- **`usage_agent.py`** — a dependency-free helper (stdlib + `curl`) that:
  - reads the Claude Code access token from the Keychain item `Claude Code-credentials`;
  - if the token is valid, `GET`s `/api/oauth/usage` with the OAuth headers and **normalizes** the
    response's `limits[]` array into `{kind, label, short, percent, severity, resets_at, is_active}`;
  - caches the last good result to `~/.config/claude-usage-widget/last_usage.json`;
  - **never refreshes or writes any token.** If the token is expired it serves the cache marked
    `stale` rather than refreshing.

### Why read-only (the important design decision)

Anthropic's OAuth **refresh** endpoint *rotates* the refresh token on every use — the old one is
invalidated immediately. If a second process (this widget) refreshed the shared token, it would
invalidate the CLI's copy and effectively log Claude Code out (and vice-versa: two processes racing
over one rotating token log each other out). So the widget **only reads** the access token the CLI
already maintains and **never refreshes it**. Consequence: while Claude Code is active its token
stays fresh and the widget is live; if the CLI has been idle long enough for the token to expire, the
widget shows the last-known numbers dimmed and marked *stale* until the CLI refreshes again — which
is exactly the window in which your usage isn't changing anyway.

> A separate, independent OAuth login for the widget was considered and rejected: a fresh grant on
> `platform.claude.com` does **not** inherit the Max-plan entitlement and instead prompts for API
> credit/billing. Borrowing the CLI token read-only is the correct approach.

---

## Security & privacy

- **No credentials in this repo.** Tokens live only in your macOS Keychain (managed by Claude Code).
  This project reads that item at runtime; it is never copied into the repo, logged, or transmitted
  anywhere except the request to Anthropic's own usage endpoint.
- **Read-only.** The widget writes **no** tokens and changes **no** Claude Code state. The only thing
  it writes is a usage cache under `~/.config/claude-usage-widget/`.
- **No telemetry.** No analytics, no network calls other than the usage endpoint.
- **Local scan is read-only** over `~/.claude/projects/**/*.jsonl` for the cost estimate.
- **Uninstall never touches your login** — see [Uninstall](#uninstall).

---

## Configuration

Everything is a small edit at the top of the source, then rebuild (`./build.sh && open ClaudeUsageBar.app`)
or re-run `./install.sh`:

| What | Where | Default |
|------|-------|---------|
| Refresh cadence | `POLL_ALIGN_MINUTES` in `ClaudeUsageBar.swift` | `5` (aligned to :00/:05/:10/…) |
| 429 backoff | `RATE_LIMIT_BACKOFF` in `ClaudeUsageBar.swift` | `15 min` |
| Color thresholds | `color(forPct:)` in `ClaudeUsageBar.swift` | 33 / 66 / 90 |
| Price table (estimate) | `basePrice(_:)` in `ClaudeUsageBar.swift` | Opus 15/75, Sonnet 3/15, Haiku 1/5 ($/M) |
| Default metric | `METRIC_KEY` register default in `applicationDidFinishLaunching` | `session` |

**Don't poll aggressively.** `/api/oauth/usage` is built for on-demand viewing and returns **HTTP 429**
under frequent polling — sub-5-minute cadences get throttled. When a 429 happens the widget keeps
showing the last good (colored) numbers and backs off for `RATE_LIMIT_BACKOFF` before trying again; it
does **not** grey out (greying is reserved for a genuinely expired login). Since limit percentages move
slowly, a 5–10 minute cadence loses nothing. Use **Refresh now** for an immediate read (it bypasses the
backoff).

---

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| Bar shows **`✦ login`** | CLI token expired/absent. Run `claude` → `/login` once in a Terminal. |
| Bar **dimmed / greyed** | Genuinely **signed out** (expired CLI login). Use Claude Code or `/login`; the widget can't refresh the token by design. A 429 does **not** grey it. |
| Numbers not updating but **still colored** | Being **rate-limited** (429) and showing the last good values while it backs off. Normal. The dropdown status line says "rate-limited, backing off". |
| **No color** in the bar | Make sure you're on the current build — coloring uses a non-template image; `attributedTitle` alone does not color the status bar. |
| Yellow hard to read on a light bar | Deepen it: change `.systemYellow` in `color(forPct:)` to e.g. `NSColor(calibratedRed: 0.80, green: 0.60, blue: 0.0, alpha: 1)`. |
| Widget didn't start at login | Check the LaunchAgent: `launchctl print gui/$(id -u)/local.claude.usagebar`. Re-run `./install.sh`. |
| Two copies running | Shouldn't happen (launch goes through `open`, which focuses the existing instance). If it does: `pkill -x ClaudeUsageBar` then reopen. |

Inspect the raw agent output anytime:
```bash
/usr/bin/python3 usage_agent.py | python3 -m json.tool
```

---

## Uninstall

```bash
./uninstall.sh
```

Stops the app, removes the LaunchAgent and the installed app, and deletes the cache under
`~/.config/claude-usage-widget/`. It **does not** touch your Claude Code login — the widget never
owned it.

---

## Limitations & disclaimers

- **Unofficial.** This uses an **undocumented** Anthropic endpoint (`/api/oauth/usage`) and the
  Claude Code OAuth client id, discovered by inspecting the CLI. Anthropic may change or remove either
  at any time, which would break the live numbers (the local estimate would still work). This project
  is not affiliated with or endorsed by Anthropic.
- **Cost is an estimate.** The local $ figure is computed from public per-token prices and cache-tier
  multipliers; treat it as a relative signal, not a bill. On a subscription you don't pay per token.
- **Percent freshness** is bounded by the poll cadence and by the CLI keeping its token fresh (see
  [Why read-only](#why-read-only-the-important-design-decision)).
- **macOS only**, Apple Silicon or Intel with the Command Line Tools.

---

## Repository layout

```
ClaudeUsageBar.swift   # the menu-bar app (AppKit / NSStatusItem)
usage_agent.py         # read-only usage fetcher (stdlib + curl), emits normalized JSON
build.sh               # compiles with swiftc and packages ClaudeUsageBar.app
install.sh             # build + install to ~/Applications + LaunchAgent (login item)
uninstall.sh           # remove app, LaunchAgent, and cache (leaves your login alone)
README.md · LICENSE · .gitignore
```

Contributions welcome. MIT licensed.
