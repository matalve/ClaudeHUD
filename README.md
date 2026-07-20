# ClaudeHUD

A transparent, borderless, always-on-top widget for macOS that shows what
[Claude Code](https://claude.com/claude-code) is doing in real time — a native
Swift port of [Simple-Claude-Widget](https://github.com/Ni-Cobra/Simple-Claude-Widget)
(Windows/Tauri):

- **Three flasks** — green = 5-hour session limit, blue = 7-day weekly limit,
  orange = 7-day weekly Fable limit (shifts to red as it fills). A drop falls
  into a flask whenever its percentage rises.
- **Session trackers** — one card per Claude Code session: title, model,
  effort, and current activity (thinking / waiting / bash / editing with
  +/− diff counts / approval needed). The whole widget **rings and shakes**
  while Claude waits for a permission approval; any click acknowledges it.
- Floats above all windows on every Space without stealing focus. Unlike the
  original's side-by-side layout, the flasks sit on top with the tracker list
  scrolling below them — a narrow column made for parking at the screen edge.
  The whole widget is click-through — flasks and cards are pure display, so
  clicks land on whatever is underneath. Hover to reveal the control bar
  (drag grip, scale, opacity, ring volume, close), the only part that catches
  clicks. Any click anywhere silences a ringing permission alarm. The
  position and all settings persist across launches.

## How it works

```
Claude Code                                ClaudeHUD.app
  ├─ hooks ───────► claudehud-emitter hook       │ polls every 0.6s
  └─ statusline ──► claudehud-emitter statusline │
        │                                        ▼
        └─► ~/.claude/monitor/{limits.json, sessions/*.json}
```

The app embeds `claudehud-emitter`, a small CLI that is wired into Claude
Code's hooks and statusline. Hooks (`SessionStart`, `UserPromptSubmit`,
`PreToolUse`, `PostToolUse`, `PermissionRequest`, `Notification`,
`PreCompact`, `Stop`, `SessionEnd`) update a per-session state file; the
statusline command persists rate-limit percentages. No sockets, no servers —
plain files, same architecture as the original.

Because the statusline never runs under the VS Code extension, the hooks also
spawn `claudehud-emitter usage` (throttled) to fetch rate limits from
Anthropic's own usage endpoint, using the OAuth token Claude Code already
stores in your login keychain. macOS will ask once to allow the emitter to
read it — the token is never copied, logged, or sent anywhere else. The
endpoint is undocumented and may change or break on Anthropic's side.

## Install

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
xcodegen generate
xcodebuild -scheme ClaudeHUD -configuration Release build
```

The project uses ad-hoc signing ("Sign to Run Locally"), so no Apple
Developer account is needed to build and run it locally. Set your own
`DEVELOPMENT_TEAM` in `project.yml` if you want a signed/notarized build.

Move `ClaudeHUD.app` to `/Applications`, launch it, then click
**Install Claude Code Hooks…** in the menu bar item (the gauge icon). It
backs up `~/.claude/settings.json`, merges in the hook + statusline wiring
(your own hooks and a custom statusline are left untouched), and is safe to
re-run — do so after moving the app. Restart Claude Code sessions so the
hooks load.

Enable **Start at Login** from the same menu to have the HUD come back
after a restart.

## Notes & caveats

- Rate limits refresh on Claude Code activity (hooks), on a 5-minute
  heartbeat while the widget is visible, and on wake from sleep — the flasks
  stay current even when no session is running.
- Session cards hide after 6 h of inactivity and dim after 10 min; state
  files are pruned after 24 h. Subagent tool calls are ignored so a card
  reflects the main agent.
- A busy session whose transcript ends with "[Request interrupted by user]"
  is shown as interrupted — no hook fires on user interrupts, so the widget
  tails the transcript to detect them.
- The app is not sandboxed: it reads `~/.claude/monitor`, and the emitter
  needs the keychain token for usage fetches. Everything runs locally.
- `CLAUDE_MONITOR_DIR` overrides the monitor directory the widget reads.

## License

[MIT](LICENSE). Based on
[Simple-Claude-Widget](https://github.com/Ni-Cobra/Simple-Claude-Widget)
(MIT © Ni-Cobra) — the emitter logic, state model, and widget design are
ported from it.
