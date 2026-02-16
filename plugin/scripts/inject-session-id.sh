#!/bin/bash
# Injects session_id into all claude-webhooks MCP tool calls via updatedInput

INPUT=$(cat)

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id')
TOOL_INPUT=$(echo "$INPUT" | jq '.tool_input')
UPDATED_INPUT=$(echo "$TOOL_INPUT" | jq --arg sid "$SESSION_ID" '. + {session_id: $sid}')

jq -n --argjson updatedInput "$UPDATED_INPUT" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "allow",
    updatedInput: $updatedInput
  }
}'
