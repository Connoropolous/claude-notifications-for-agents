# Claude Notifications for Agents

Receive real-time webhooks from GitHub, Linear, Stripe, and other services directly in your Claude Code sessions.

![ClaudeWebhooks menu bar app](screenshot.png)

## How It Works

1. A macOS menu bar app runs a local HTTP server
2. A Cloudflare Tunnel exposes it to the internet
3. External services send webhooks to your tunnel URL
4. Signatures are verified (HMAC-SHA256) to ensure only authentic events are accepted
5. Events are delivered into your Claude Code session as prompts — as if a user typed them

## Quick Start

### 1. Build the app

```bash
cd ClaudeWebhooks
swift build -c release
open .build/*/release/ClaudeWebhooks
```

### 2. Set up a tunnel

In Claude Code, run `/setup-tunnel` and follow the prompts. You'll need:
- `cloudflared` installed (`brew install cloudflared`)
- A Cloudflare account with a domain

### 3. Subscribe to events

In Claude Code, run `/subscribe` and tell it what you want:

```
/subscribe github pushes on myorg/myrepo
/subscribe linear issue updates
/subscribe stripe payment events
```

The skill handles everything: generates secrets, creates the subscription, registers the webhook on the service.

## What Gets Delivered

When a webhook fires, Claude sees something like:

```xml
<webhook-event service="github" event-id="ABC123">
A push event was received on myorg/myrepo. Review the changes.
<payload>
{"branch":"refs/heads/main","pusher":"connor","commits":[{"message":"fix bug"}]}
</payload>
</webhook-event>
```

Payloads are summarized to save context window space. Claude can fetch the full payload with the `get_event_payload` tool.

## Components

| | |
|---|---|
| **ClaudeWebhooks/** | macOS menu bar app (Swift) |
| **plugin/** | Claude Code plugin with `/subscribe` and `/setup-tunnel` skills |
| **cli.js** | Socket patch for the `@anthropic-ai/claude-agent-sdk` npm package's `cli.js` ([view diff](https://github.com/Connoropolous/claude-notifications-for-agents/compare/03d21f1..b8e03d0)) |

## Requirements

- macOS 14+
- `cloudflared` for tunnel
- `jq` for payload filtering
- A domain on Cloudflare DNS
