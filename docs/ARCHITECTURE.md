# Architecture

A macOS port of [clawd-usage-winwidget](https://github.com/Enhed/clawd-usage-winwidget) 1.12.3.
Each Swift file names the upstream module it ports; behaviour and file formats follow upstream.

## Targets

```
Sources/ClawdCore      logic, no AppKit - tested by Tests/ClawdCoreTests
Sources/ClawdUsage     the app: AppKit windows + SwiftUI views
Resources              strings (en/ru/fr), mascot tables, skins, prompts - copied into the .app
scripts                build-app.sh, make-icon.swift, export-*.ps1 (re-export tables from upstream)
tools/smoke.sh         end-to-end check of the built app
```

## ClawdCore

| File | Upstream | What |
|---|---|---|
| `Paths.swift` | config.ps1 | App data folder, Claude Code's folder (`CLAUDE_CONFIG_DIR`), resources, error log, JSON helpers |
| `Config.swift` | config.ps1 | `config.json` as a dictionary: defaults, unknown keys kept, hot reload |
| `I18n.swift` | i18n.ps1 | `T(key, args...)` over `strings.json` + `strings-mac.json`, .NET-style `{0}` formatting, plurals |
| `ProcessRunner.swift` | - | Child processes by argv (no shell), timeouts, stream lines, own PIDs; login-shell PATH; finding `claude` |
| `Usage.swift` | usage.ps1 | `/usage` parser and probe |
| `Sessions.swift` | sessions.ps1 | Live sessions from `sessions/<pid>.json` (pid alive + `procStart` match), remote feeds |
| `Probes.swift` | account, status, version | `auth status`, status page, Claude Code version + changelog, widget releases |
| `History.swift` | history.ps1 | 7-day samples; projects from transcripts (streamed, incremental) |
| `Mascot.swift`, `MascotEngine.swift` | mascot*.ps1, hearts.ps1, skins.ps1 | Glyph-to-pixel geometry, skins, the mood/animation state machine, hearts |
| `Sky.swift` | weather.ps1, sky.ps1 | Weather probe, sun and moon math, the sky's animation state |
| `Theme.swift` | theme.ps1 | Colour tokens per theme, Halloween wallpaper |
| `Reminders.swift` | reminders.ps1, lists.ps1 | Reminder files, the "when" parser and quick-model fallback, lists |
| `Assistant.swift` | chat.ps1, tasks.ps1 | Chat over `claude -p`, reply blocks, approved zsh scripts, recurring tasks, the phone feed. Tool rules pass a grammar (`ClawdTask.isToolRule`) wherever they are read; a reply's `task` block gets its tools only through an Allow card; a task's report cannot make tasks |
| `ClawdSession.swift` | clawd-session.ps1 | Clawd's own Remote Control session on an app-owned pty |
| `Advisor.swift` | advisor.ps1 | macOS checks: disks, caches, launch agents, unused apps, uptime, memory/CPU hogs |
| `ClaudeSettings.swift` | claude-settings.ps1 | Order-preserving JSON editing of Claude Code's `settings.json` |

## ClawdUsage

| File | What |
|---|---|
| `main.swift` | Single instance (flock), `--render` mode, app start |
| `AppDelegate.swift` | Menu bar item, widget/panel/settings windows, badge, login item, notifications wiring |
| `AppModel.swift` | The tick: probes, sessions, mascot mood, tasks, reminders; display strings |
| `Windows.swift` | Borderless floating panel that sizes to its SwiftUI content (top-left anchored), mouse tracking |
| `WidgetView.swift`, `DetailsView.swift`, `MascotView.swift`, `DevMenu.swift` | The widget |
| `ClawdPanelView.swift` | Chat / Reminders / Lists panel and tips |
| `SettingsView.swift` | Settings, incl. the Claude Code tab |
| `RemindPopup.swift` | Reminder cards in the top-right corner |
| `LaunchAtLogin.swift` | "Open at login" read from and written to macOS (SMAppService), not config.json |
| `Support.swift` | Colours, notifications, hover tooltips that work while the app is inactive, scaling |
| `Render.swift` | `ClawdUsage --render <dir>`: PNGs of every view with sample data |

## Data flow

`AppModel.update()` runs every `refreshSeconds` (10 s): it starts due probes (each async, results
kept on the probe), reads sessions, feeds Clawd's mood, fires reminders, starts due tasks and reads
the phone transcript. Views observe `AppModel`; the animator (`Animator`, 60/90 ms) observes only
the mascot, sky and hearts, so a frame does not re-render the whole widget.

## Files

App data: `~/Library/Application Support/ClawdUsage/` - `config.json`, `chat-state.json`,
`tasks-state.json`, `advisor-state.json`, `clawd-state.json`, `usage-history.json`,
`update-state.json`, `widget-error.log`. Clawd's home (`clawdHome`, default `~/Clawd`):
`reminders/`, `lists/`, `tasks/`, `skins/`, `tips.md`, `chat-log.md` - the same layout as upstream.
