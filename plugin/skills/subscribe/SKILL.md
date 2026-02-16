---
name: subscribe
description: Use when the user mentions subscribing to webhooks, listening for events, or waiting for events from external services like GitHub, Linear, Stripe, or any custom service
---

# Webhook Subscription Setup

You are setting up a webhook subscription for this Claude Code session. Once set up,
incoming webhook events will be delivered to this session automatically — as if the user
had typed a prompt. The session will be interrupted with the event content whenever a
webhook fires.

Be opinionated and automated — don't ask unnecessary questions. Handle the service-side
webhook registration yourself.

Use the MCP tools from the `claude-webhooks` server throughout this process.

**Critical rule**: Do NOT hallucinate CLI commands or API calls. If you are not 100% certain
of the correct command or API to register a webhook on a service, you MUST look it up first
by fetching the service's official documentation. Get canonical info before acting.

---

## Step 1: Check Prerequisites

1. Use `ToolSearch` with query `+claude-webhooks` to find and load all MCP tools. Do NOT use
   `listMcpResources` — it won't work. The tools are named like
   `mcp__plugin_claude-webhooks_claude-webhooks__create_subscription`. Just search and they'll
   be available to call directly.
2. Call `get_tunnel_status` to check tunnel state.
3. **DO NOT look up, echo, or pass a `session_id`.** A PreToolUse hook silently injects the
   session ID into every `claude-webhooks` MCP tool call. You will never see it and must not
   try to find it. There is no `CLAUDE_SESSION_ID` or `SESSION_ID` environment variable.
   Just call the MCP tools with the documented parameters — the hook handles the rest.

If the MCP tools are not available, tell the user:
> "The ClaudeWebhooks app isn't running. Please start it from the menu bar."

Then stop.

---

## Step 2: Ask What and Where

Ask the user ONE question with all the info you need:

> "What service do you want webhooks from, and which events?"
>
> Examples:
> - "github pushes on myorg/myrepo"
> - "linear issue updates"
> - "stripe payment events"
> - "custom webhook from my CI server"

Parse their response to extract:
- **Service type**: github, linear, stripe, or custom
- **Target**: repo name, workspace, etc.
- **Events**: which events (default to "all" if not specified)

If the user provided arguments with the /subscribe command (e.g. `/subscribe github pushes on myorg/myrepo`), use those directly — don't ask again.

---

## Step 3: Tunnel Setup (if needed)

If the service is remote (GitHub, Linear, Stripe — anything that needs to reach your machine
from the internet), check the tunnel status from Step 1.

**If tunnel is already active**: Great, proceed to Step 4.

**If tunnel is NOT active**: Tell the user:
> "You need a Cloudflare Tunnel for external webhooks. Run `/setup-tunnel` to set one up."

Then stop and wait for them to do that first.

---

## Step 4: Create Subscription and Get the Webhook URL

Create the subscription first — this gives you the webhook URL you need to register on the
service side. Call `create_subscription` with just the basics for now:
- `service`: detected service type (do NOT pass session_id — it is auto-injected by hook)
- `name`: auto-generated (e.g. "github-myorg-myrepo-push")

Then call `get_public_webhook_url` with the subscription ID to get the full public URL.

---

## Step 5: Register the Webhook on the Service

Now that you have the webhook URL, register it on the service. You also need an HMAC secret
for signature verification.

1. **Generate an HMAC secret**: `python3 -c "import secrets; print(secrets.token_hex(16))"`

2. **Look up the service's signing method.** Do not guess. Use WebFetch to check the
   canonical docs:
   - GitHub: `https://docs.github.com/en/rest/webhooks/repos#create-a-repository-webhook`
   - Linear: `https://linear.app/developers/webhooks`
   - Stripe: `https://docs.stripe.com/api/webhook_endpoints/create`

   Known services (verify these are still current):
   - GitHub: `X-Hub-Signature-256` (HMAC-SHA256, `sha256=<hex>` format)
   - Linear: `Linear-Signature` (HMAC-SHA256)
   - Stripe: `Stripe-Signature` (uses a different scheme — check docs)

3. **Register the webhook** using Strategy A or B below, passing the **webhook URL** and
   **HMAC secret** to the service.

Register the webhook on the service. Try these approaches in order. **Do NOT ask the user
which approach they prefer — just try them in order and move to the next if one fails.**

### Approach 1: CLI / API

**GitHub** — check `gh auth status`. If authenticated:
```bash
gh api repos/{owner}/{repo}/hooks --method POST \
  -f "name=web" \
  -f "config[url]={public_webhook_url}" \
  -f "config[content_type]=json" \
  -f "config[secret]={hmac_secret}" \
  -f "events[]={event1}" \
  -f "events[]={event2}" \
  -f "active=true"
```

**Stripe** — check if `stripe` CLI is installed and authenticated:
```bash
stripe webhook_endpoints create \
  --url={public_webhook_url} \
  --enabled-events={event1},{event2}
```

**Linear** — check for `LINEAR_API_KEY` env var. If it exists:
```bash
curl -X POST https://api.linear.app/graphql \
  -H "Authorization: Bearer $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query":"mutation { webhookCreate(input: { url: \"{public_webhook_url}\", resourceTypes: [\"Issue\"], secret: \"{hmac_secret}\" }) { success webhook { id } } }"}'
```

If the CLI/API approach fails (not authenticated, no API key, command not found), **do NOT
ask the user for API keys or credentials.** Move immediately to Approach 2.

### Approach 2: Browser (Claude in Chrome)

Use the **Browser tool** to do it yourself. Navigate to the webhook settings page, fill in
the form, and submit it. The user supervises and approves each action.

URLs:
- GitHub: `https://github.com/{owner}/{repo}/settings/hooks/new`
- Linear: `https://linear.app/settings/api/webhooks`
- Stripe: `https://dashboard.stripe.com/webhooks/create`

Fill in:
- **URL**: `{public_webhook_url}`
- **Content type**: `application/json`
- **Secret**: `{hmac_secret}`
- **Events**: the specific events

If the Browser tool is not available, tell the user:

> "I need the Browser tool to register this webhook for you. Two things are needed:
> 1. Start Claude Code with `claude --chrome`
> 2. Install the Claude in Chrome extension: https://chromewebstore.google.com/publisher/anthropic/u308d63ea0533efcf7ba778ad42da7390
>
> Then try `/subscribe` again."

### Approach 3: Manual (last resort)

Only if the user explicitly declines to install Claude in Chrome:

> Here's what to enter in the webhook settings:
> - **URL**: `{public_webhook_url}`
> - **Content type**: `application/json`
> - **Secret**: `{hmac_secret}`
> - **Events**: {events}

Wait for the user to confirm they've registered it.

### Security warning

If the service does NOT support HMAC signature verification (no secret, no signing),
**warn the user**:

> "This service does not support webhook signature verification. Anyone who discovers
> the webhook URL could send fake events to your session. Proceed anyway?"

Only continue if they confirm.

---

## Step 6: Update Subscription with Auth and Filters

Now that the webhook is registered on the service, update the subscription with the
authentication and filtering configuration.

Call `update_subscription` with the `subscription_id` from Step 4 and these fields:
- `hmac_secret`: the generated secret from Step 5
- `hmac_header`: the correct header for the service (e.g. `X-Hub-Signature-256`)
- `prompt`: a short instruction describing what happened and what Claude should do with it.
  The server wraps this in XML tags automatically. Example:
  `"A push event was received on myorg/myrepo. Review the changes and summarize what was pushed."`
- `jq_filter`: (optional) a jq expression that gates which events get through. This runs
  FIRST on the raw payload. If the result is `false`, `null`, or empty, the event is silently
  dropped. Use `select()` expressions to filter in matching events. Examples:
  - Only PR opens: `select(.action == "opened")`
  - Only pushes to main: `select(.ref == "refs/heads/main")`
  - Only issue state changes: `select(.action == "updated" and .data.state != null)`
  - Leave unset to receive all events.
- `summary_filter`: a jq expression that extracts a compact summary from the payload.
  This runs AFTER `jq_filter` (only on events that passed the gate). The full payload is
  always stored and retrievable via `get_event_payload`. This keeps context window usage
  small. Examples:
  - GitHub push: `{branch: .ref, pusher: .pusher.name, commits: [.commits[] | {message, id: .id[:8]}], compare: .compare}`
  - GitHub PR: `{action: .action, title: .pull_request.title, number: .number, author: .pull_request.user.login, branch: .pull_request.head.ref}`
  - Linear issue: `{action: .action, title: .data.title, state: .data.state.name, assignee: .data.assignee.name}`
  - Generic fallback: `{keys: keys}`

**Processing order**: `jq_filter` (gate) → `summary_filter` (summarize) → inject into session.

---

## Step 7: Confirm

Show a brief summary:

```
Webhook subscription active!

  Service:  GitHub (ceedaragents/cyrus)
  Events:   push
  URL:      https://{tunnel-domain}/webhook/{id}
  Verified: HMAC-SHA256 via X-Hub-Signature-256
  Mode:     persistent

  Webhook registered on GitHub.

  From now on, when a push event fires, this session will be
  automatically prompted with a summary of the event.
```

Done. Don't ask follow-up questions.

---

## Notes on Arguments

The user can pass arguments directly:

- `/subscribe github pushes on myorg/myrepo` — skip straight to setup
- `/subscribe once github issues on myorg/myrepo` — one-shot mode
- `/subscribe linear all on my-workspace` — all linear events
- `/subscribe custom my-ci` — custom webhook, just generate URL

Parse the arguments and skip any steps where you already have the information.
