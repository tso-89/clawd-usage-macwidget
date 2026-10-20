# Test registry

Unit tests are documented by their names (`swift test`). Integration and end-to-end tests:

| Test | Kind | What it checks | Needs |
|---|---|---|---|
| `IntegrationTests.chatRoundTrip` | integration | A chat message runs `claude -p --output-format stream-json` with the read-only rules, the reply's `remind` and `run` blocks act, its `task` block makes the task without `tools` and an Allow card for the valid ones, a refused MCP call becomes a card, an approved script runs in zsh and its output goes back with `--resume` | `Tests/Fixtures/fake-claude.sh` (no network, no tokens); `FAKE_CLAUDE_LOG` is set by the test |
| `IntegrationTests.taskRunAndGrant` | integration | A due recurring task runs with `--json-schema`, only valid tool rules from its file reach the command line (no flag-like tokens, no bare `Bash`), `--strict-mcp-config` is off when an `mcp__` rule is granted, a refused command becomes an Allow card, Allow writes the rule into the task file and resets it | fake claude |
| `IntegrationTests.usageAndAccountProbes` | integration | `/usage` and `auth status` probes parse the child's output | fake claude, `Tests/Fixtures/usage-real.txt` |
| `IntegrationTests.whenProbe` | integration | The "when" fallback asks the quick model and parses its date | fake claude |
| `tools/smoke.sh` | end-to-end | The built `.app` starts in a sandbox (own data folder, Clawd home and instance lock via `CLAWD_SMOKE`), writes `CLAWD_READY_FILE`, takes its first `/usage` sample, logs no errors | `dist/Clawd Usage.app` (built if missing), fake claude |

Fixtures: `Tests/Fixtures/usage-real.txt` (a real `/usage` reply, Claude Code 2.1.302, "Oct 18 at
12:50am" stamps), `usage-old.txt` (the older "Oct 17, 5:19am" format), `usage-zero.txt` (no
usage: no "resets", singular "1 request").

Environment variables used by tests and tools: `CLAWD_DATA_DIR` (app data folder),
`CLAWD_READY_FILE`, `CLAWD_SMOKE`, `CLAWD_SHOW` (`panel`, `remind`, `lists`, `settings` - open
at start), `CLAWD_RESOURCES`, `FAKE_CLAUDE_LOG`.
