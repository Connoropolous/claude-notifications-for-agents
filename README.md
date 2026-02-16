# Claude Code Notifications for Agents

External event delivery for Claude Code sessions. Two components:

1. **cli.js patch** - Adds a Unix socket server to Claude Agent SDK sessions so they can receive external messages
2. **ClaudeWebhooks** - A macOS menu bar app + Claude Code plugin that receives webhooks from GitHub, Linear, Stripe, etc. and injects them into Claude Code sessions in real time

---

## Part 1: Socket Patch (cli.js)

A patch for `@anthropic-ai/claude-agent-sdk`'s `cli.js` that adds a socket server at `~/.claude/sockets/{agentSessionId}.sock`.

### [View the diff](https://github.com/Connoropolous/claude-notifications-for-agents/compare/03d21f1..b8e03d0)

### Socket Protocol

The socket accepts newline-delimited messages. Each line is parsed as JSON:

- **JSON string**: `"plain text"` - treated as a prompt
- **JSON object**: `{"value": "...", "mode": "prompt"}` - value is the prompt text, mode controls queuing
- **Plain text**: `hello` - falls back to raw prompt

Newlines inside JSON string values are escaped by the serializer, so multi-line content stays on a single line.

### Usage

```bash
# Find the socket for a running session
SOCK=$(ls ~/.claude/sockets/*.sock 2>/dev/null | head -1)

# Send a prompt
echo '"Hello, list the files in the current directory"' | nc -U "$SOCK"

# Send structured JSON (preserves newlines in content)
echo '{"value":"What files are in /tmp?","mode":"prompt"}' | nc -U "$SOCK"
```

---

## Part 2: ClaudeWebhooks (macOS App + Plugin)

A macOS menu bar app that receives webhooks via a Cloudflare Tunnel and injects them into Claude Code sessions via the socket protocol above.

### Architecture

```
GitHub/Linear/Stripe  -->  Cloudflare Tunnel  -->  localhost:7842  -->  WebhookProcessor  -->  Unix Socket  -->  Claude Code Session
```

- **HTTP Server** (Vapor) on `127.0.0.1:7842` - receives webhooks and MCP JSON-RPC requests
- **Cloudflare Tunnel** - routes external traffic to localhost (named tunnel with DNS route)
- **Webhook Processor** - HMAC verification, jq filtering, jq summarization, XML framing
- **Socket Injector** - delivers framed events to Claude Code sessions
- **MCP Server** - exposes tools for creating/managing subscriptions
- **Claude Code Plugin** - skills (`/subscribe`, `/setup-tunnel`) and PreToolUse hooks for session_id injection

### Features

- HMAC-SHA256 signature verification (CryptoKit)
- `jq_filter` to gate events (drop unwanted events before processing)
- `summary_filter` to extract compact summaries (keeps context window small)
- Full payloads stored in SQLite, retrievable via `get_event_payload` MCP tool
- XML-framed event delivery with configurable prompts
- Menu bar UI showing subscriptions, event counts, tunnel status
- Auto-start tunnel on launch

### Processing Pipeline

```
Webhook arrives
  --> HMAC signature verification
  --> jq_filter gate (accept/reject)
  --> Log full payload to SQLite
  --> summary_filter (compact summary via jq)
  --> XML frame with prompt
  --> Inject into session via Unix socket
```

### Building

```bash
cd ClaudeWebhooks
swift build -c release
# Binary at .build/{arch}-apple-macosx/release/ClaudeWebhooks
```

### Plugin Installation

The plugin is at `ClaudeWebhooks/plugin/`. It provides:

- `/subscribe` - Set up a webhook subscription (auto-generates secrets, registers webhooks on the service)
- `/setup-tunnel` - Configure a persistent Cloudflare Tunnel with DNS routing
- PreToolUse hook that auto-injects `session_id` into all MCP tool calls

### MCP Tools

| Tool | Description |
|------|-------------|
| `create_subscription` | Register a new webhook subscription |
| `list_subscriptions` | List existing subscriptions |
| `update_subscription` | Modify jq_filter, summary_filter, or status |
| `delete_subscription` | Remove a subscription |
| `get_event_payload` | Retrieve the full untruncated payload for an event |
| `start_tunnel` / `stop_tunnel` | Control the Cloudflare tunnel |
| `get_tunnel_status` | Check tunnel status and public URL |
| `get_public_webhook_url` | Get the full webhook URL for a subscription |

### Event Delivery Format

Events are delivered to Claude Code sessions as:

```xml
<webhook-event service="github" event-id="...">
A push event was received on myorg/myrepo. Review the changes.
<payload>
{"branch":".ref","pusher":"...","commits":[...]}
</payload>
To see the full untruncated payload, use the get_event_payload tool with event_id "...".
If this event is too noisy, use update_subscription to adjust the summary_filter or jq_filter.
</webhook-event>
```

### Requirements

- macOS 14+
- Swift 5.9+
- `cloudflared` (for tunnel)
- `jq` (for payload filtering/summarization)
- A domain with Cloudflare DNS (for named tunnel)
