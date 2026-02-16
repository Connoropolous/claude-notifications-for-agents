---
name: subscribe
description: Set up a webhook subscription for this Claude Code session to receive real-time events from GitHub, Linear, Stripe, or any custom service
---

# Webhook Subscription Setup

You are setting up a webhook subscription for this Claude Code session. Be opinionated and
automated — don't ask unnecessary questions. Generate secrets automatically, use sensible
defaults, and handle the service-side webhook registration yourself.

Use the MCP tools from the `claude-webhooks` server throughout this process.

**Critical rule**: Do NOT hallucinate CLI commands or API calls. If you are not 100% certain
of the correct command or API to register a webhook on a service, you MUST look it up first
by fetching the service's official documentation. Get canonical info before acting.

## Architecture Context

The ClaudeWebhooks system is a macOS menu bar app running an HTTP server on localhost:7842.
It receives webhooks, verifies them, and injects events into Claude Code sessions via Unix
sockets at `~/.claude/sockets/{sessionId}.sock`.

The MCP tools available are:
- `create_subscription` — register a new webhook subscription
- `list_subscriptions` — list existing subscriptions
- `delete_subscription` — remove a subscription
- `update_subscription` — modify a subscription
- `start_tunnel` — start the persistent tunnel (requires /setup-tunnel first)
- `stop_tunnel` — stop the running tunnel
- `start_quick_tunnel` — start a **temporary** tunnel (URL changes on restart, testing only)
- `get_tunnel_status` — check tunnel status and get public URL
- `get_public_webhook_url` — get the full webhook URL for a subscription

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

**If tunnel is NOT active**: You need to set one up. **Always prefer a persistent tunnel**
(`configure_tunnel`) over a quick tunnel. Quick tunnels generate a new URL every restart,
which breaks all your registered webhooks.

### Getting a Cloudflare API token

Check if the tunnel is already configured by calling `get_tunnel_status`. If it reports
active with a public URL, proceed to Step 4.

If the tunnel is not configured, tell the user:
> "You need a Cloudflare Tunnel for external webhooks. Run `/setup-tunnel` to set one up (takes ~30 seconds)."

Then stop and wait for them to do that first.

If they just need a quick test, `start_quick_tunnel` works but warn them the URL
will change on every restart, breaking any registered webhooks.

---

## Step 4: Create the Subscription

Do all of the following without asking — just do it:

1. **Generate an HMAC secret**: `python3 -c "import secrets; print(secrets.token_hex(16))"`

   **You MUST look up the correct signing method for the service.** Do not guess. Use WebFetch
   to check the canonical docs before setting these:
   - `hmac_secret`: the generated secret
   - `hmac_header`: the HTTP header the service sends the signature in

   Known services (verify these are still current):
   - GitHub: `X-Hub-Signature-256` (HMAC-SHA256, `sha256=<hex>` format)
   - Linear: `Linear-Signature` (HMAC-SHA256)
   - Stripe: `Stripe-Signature` (uses a different scheme — check docs)
   - Custom: `X-Webhook-Signature`

2. **Create the subscription**: Call `create_subscription` with:
   - `service`: detected service type (do NOT pass session_id — it is auto-injected by hook)
   - `name`: auto-generated (e.g. "github-myorg-myrepo-push")
   - `hmac_secret`: the generated secret
   - `hmac_header`: the correct header from step 1
   - `prompt`: a short instruction describing what happened and what Claude should do with it.
     The server wraps this in XML tags automatically. Example:
     `"A push event was received on myorg/myrepo. Review the changes and summarize what was pushed."`
   - `jq_filter`: (optional) a jq expression that gates which events get through. This runs
     FIRST on the raw payload. If the result is `false`, `null`, or empty, the event is silently
     dropped — it won't be injected or logged. Use `select()` expressions to filter in only the
     events you want. Examples:
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
   - `one_shot`: false (persistent, unless user said "once" or "one time")

   **Processing order**: `jq_filter` (gate) → `summary_filter` (summarize) → inject into session.

3. **Get the public webhook URL**: Call `get_public_webhook_url` with the subscription ID.

---

## Step 5: Register the Webhook on the Service

This is the most important step. You have two strategies. Try Strategy A first.

### Strategy A: CLI / API (preferred)

Use the service's CLI or API to register the webhook programmatically. But first:

**You MUST verify the correct commands.** Do not guess. If you are not certain of the exact
CLI syntax or API format, fetch the official docs first:

- GitHub: `https://docs.github.com/en/rest/webhooks/repos#create-a-repository-webhook`
- Linear: `https://linear.app/developers/webhooks`
- Stripe: `https://docs.stripe.com/api/webhook_endpoints/create`

Use WebFetch or WebSearch to get the canonical information before running any commands.

#### GitHub — `gh` CLI

Check `gh auth status` first. If authenticated:

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

#### Linear — GraphQL API

Linear does NOT have a webhook CLI. Use the GraphQL API:

```bash
curl -X POST https://api.linear.app/graphql \
  -H "Authorization: Bearer {LINEAR_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "query": "mutation { webhookCreate(input: { url: \"{public_webhook_url}\", teamId: \"{team_id}\", resourceTypes: [\"Issue\"], secret: \"{hmac_secret}\" }) { success webhook { id enabled } } }"
  }'
```

Notes:
- Only workspace admins or OAuth apps with `admin` scope can create webhooks
- `resourceTypes` options: Comment, Issue, IssueLabel, Project, Cycle, Reaction, Documents, Initiatives, Customers, Users
- You need either a `teamId` or `allPublicTeams: true`
- Check for a LINEAR_API_KEY env var. If not available, fall back to Strategy B.

#### Stripe — `stripe` CLI

Check if `stripe` CLI is installed and authenticated. If so:

```bash
stripe webhook_endpoints create \
  --url={public_webhook_url} \
  --enabled-events={event1},{event2}
```

#### Other / Unknown services

Look up the docs with WebFetch first. If the service has an API for webhook registration,
use it. Otherwise fall back to Strategy B.

### Strategy B: Claude in Chrome (fallback)

If Strategy A is not possible (no CLI, no API key, auth failure), use Claude in Chrome
to register the webhook via the service's web UI:

1. Open the webhook settings page:
   - GitHub: `https://github.com/{owner}/{repo}/settings/hooks/new`
   - Linear: `https://linear.app/settings/api/webhooks`
   - Stripe: `https://dashboard.stripe.com/webhooks/create`

2. Use Claude in Chrome to fill in the form with:
   - Webhook/Payload URL: `{public_webhook_url}`
   - Content type: `application/json`
   - Secret: `{hmac_secret}`
   - Events: the specific events to subscribe to

3. The user supervises and confirms.

If Claude in Chrome is also not available, show the user the URL and values to enter manually.

---

## Step 6: Confirm

Show a brief summary:

```
Webhook subscription active

  Service:  GitHub (ceedaragents/cyrus)
  Events:   push
  URL:      https://{tunnel-domain}/webhook/{id}
  Secret:   {hmac_secret}
  Mode:     persistent

  Webhook registered on GitHub.
  Events will be delivered to this session in real time.
```

Done. Don't ask follow-up questions.

---

## How Events Are Delivered

When a webhook fires, the ClaudeWebhooks app wraps it in XML and injects it into this
session. The delivered message looks like:

```xml
<webhook-event service="github">
A push event was received on myorg/myrepo. Review the changes and summarize what was pushed.
<payload>
{ ... raw webhook JSON ... }
</payload>
</webhook-event>
```

The text between the opening tag and `<payload>` is the `prompt` you set at subscription
time. The server adds the XML wrapping automatically — just provide the instruction text.

---

## Notes on Arguments

The user can pass arguments directly:

- `/subscribe github pushes on myorg/myrepo` — skip straight to setup
- `/subscribe once github issues on myorg/myrepo` — one-shot mode
- `/subscribe linear all on my-workspace` — all linear events
- `/subscribe custom my-ci` — custom webhook, just generate URL

Parse the arguments and skip any steps where you already have the information.
