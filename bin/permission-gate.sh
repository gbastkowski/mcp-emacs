#!/usr/bin/env bash
# PreToolUse hook: ask the human, in Emacs, before the tool call runs.
#
# The CLI spawns this and blocks on it, which is the whole point: it is the
# one place a permission decision can still be *made* rather than merely
# reported.  `can_use_tool' is never emitted in headless mode and
# `permission_denials' only arrives at the end of the turn, long after the
# refusal -- so neither can gate anything.
#
# Stdin is the hook payload (tool_name, tool_input, tool_use_id, session_id,
# cwd, permission_mode).  We hand it to the running Emacs, which raises a
# menu buffer, and print whatever decision comes back on stdout.
#
# This script stays deliberately dumb -- read, POST, print.  The decision
# logic lives in Emacs where it can be tested without a CLI in the loop.
#
# Fail closed.  Every failure path here -- no Emacs, no server, malformed
# reply, curl missing -- prints a deny.  A gate that opens up when it breaks
# is not a gate, and this runs unattended by definition.

set -uo pipefail

port="${MCP_EMACS_PORT:-8765}"
url="http://localhost:${port}/permission-gate"

# The CLI kills the hook on its own timeout; stay under it so the human sees
# a reasoned deny rather than a hook that simply vanished.
timeout="${MCP_EMACS_GATE_TIMEOUT:-110}"

payload="$(cat)"

deny() {
  # `permissionDecisionReason' reaches the model verbatim, so it is written
  # for the model: say what happened and that retrying will not help.
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"
  exit 0
}

if ! command -v curl >/dev/null 2>&1; then
  deny "Permission gate unavailable: curl not found. Ask the human to approve this directly."
fi

response="$(printf '%s' "$payload" \
  | curl -sS --max-time "$timeout" \
         -H 'Content-Type: application/json' \
         --data-binary @- \
         "$url" 2>/dev/null)" || \
  deny "Permission gate unreachable at ${url}. Emacs may not be running, or the mcp-emacs server is stopped. Ask the human to approve this directly."

if [ -z "$response" ]; then
  deny "Permission gate returned nothing (it may have timed out waiting for the human). Not retried."
fi

# Emacs already speaks the hook's own output shape, so a decision passes
# through untouched.  Anything else is a bug on the Emacs side, and guessing
# at intent here is how a deny silently becomes an allow.
case "$response" in
  *'"permissionDecision"'*) printf '%s\n' "$response" ;;
  *) deny "Permission gate replied in an unrecognised form. Treated as denied." ;;
esac
