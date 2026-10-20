#!/bin/zsh
# Stand-in for `claude` in integration tests: answers by mode, no network, no tokens.
# FAKE_CLAUDE_LOG gets the argv; stdin is read (the prompt).
cat > /dev/null
# The log path does not depend on the environment the tests set (the child environment is captured once per process).
print -r -- "$*" >> "${FAKE_CLAUDE_LOG:-${TMPDIR:-/tmp}/clawd-fake-claude-argv.log}"
if [[ "$*" == *"stream-json"* ]]; then
  print -r -- '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"du -sh ~/Library/Caches"}}]}}'
  print -r -- '{"type":"user","message":{"content":[{"type":"tool_result"}]}}'
  print -r -- '{"type":"result","is_error":false,"result":"Done.\n```remind\n2031-01-02T10:00 | Fake reminder\n```\n```run\necho hello from run\n```\n```task\nname: Fake\nevery: 10m\ntools: mcp__mail Bash\n---\nLook around.\n```","permission_denials":[{"tool_name":"mcp__mail__move","tool_input":{"id":"1"}}]}'
elif [[ "$*" == *"--json-schema"* ]]; then
  print -r -- '{"type":"result","is_error":false,"result":"x","structured_output":{"tell":true,"message":"2 new letters from Bob","summary":"2 new from Bob"},"permission_denials":[{"tool_name":"Bash","tool_input":{"command":"gh issue list --repo a/b"}}]}'
elif [[ "$1" == "-p" && "$2" == "/usage" ]]; then
  cat "${0:h}/usage-real.txt"
elif [[ "$1" == "auth" ]]; then
  print -r -- '{"loggedIn":true,"authMethod":"claude.ai","email":"me@example.com","subscriptionType":"max"}'
else
  print -r -- "2026-10-19T09:30"
fi
