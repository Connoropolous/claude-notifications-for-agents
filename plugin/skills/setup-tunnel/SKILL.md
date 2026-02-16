---
name: setup-tunnel
description: Set up a persistent Cloudflare Tunnel so external services can send webhooks to this machine
---

# Cloudflare Tunnel Setup

You are setting up a persistent Cloudflare Tunnel that forwards external webhook traffic
to the local ClaudeWebhooks server on port 7842. This gives a stable public URL that
survives restarts.

The user only needs to authenticate once in their browser. You handle the rest.

---

## Step 0: Load MCP Tools

Use `ToolSearch` with query `+claude-webhooks` to find and load all MCP tools. Do NOT use
`listMcpResources`. The tools are needed in later steps (`start_tunnel`, `get_tunnel_status`).

---

## Step 1: Check cloudflared

Run `which cloudflared` to check if it's installed. The ClaudeWebhooks app auto-downloads
cloudflared to `~/Library/Application Support/ClaudeWebhooks/bin/cloudflared` — check there
too if the system one isn't found.

If neither exists, download it:
```bash
mkdir -p ~/Library/Application\ Support/ClaudeWebhooks/bin
curl -L -o /tmp/cloudflared.tgz "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-amd64.tgz"
tar -xzf /tmp/cloudflared.tgz -C ~/Library/Application\ Support/ClaudeWebhooks/bin/
chmod +x ~/Library/Application\ Support/ClaudeWebhooks/bin/cloudflared
rm /tmp/cloudflared.tgz
```

Use the correct architecture (`amd64` for Intel, `arm64` for Apple Silicon). Check with `uname -m`.

Store the path to cloudflared for subsequent commands.

---

## Step 2: Authenticate

Check if `~/.cloudflared/cert.pem` exists. If it does, skip this step.

If not, run:
```bash
cloudflared tunnel login
```

This opens a browser window. Tell the user:
> "A browser window will open for Cloudflare authentication. Please log in and authorize the tunnel."

Wait for the command to complete. It creates `~/.cloudflared/cert.pem`.

---

## Step 3: Create the tunnel

Check if a tunnel named `claude-webhooks` already exists:
```bash
cloudflared tunnel list --output json
```

If it exists, use the existing tunnel ID. If not, create one:
```bash
cloudflared tunnel create claude-webhooks
```

Parse the tunnel ID (UUID) from the output.

---

## Step 4: Create a DNS route

**This step is required.** Named tunnels are NOT accessible via `<id>.cfargotunnel.com` —
that only works for quick tunnels. You MUST create a DNS CNAME route to make the tunnel
reachable.

Ask the user which domain they have in Cloudflare:

> "Which domain do you have in Cloudflare? I'll create a `webhooks.<domain>` subdomain for the tunnel."

Then create the DNS route:
```bash
cloudflared tunnel route dns claude-webhooks webhooks.<domain>
```

The hostname (e.g. `webhooks.example.com`) will be the stable public URL.

---

## Step 5: Write the config

Write `~/.config/cloudflared/config.yml`:

```yaml
tunnel: <tunnel-id>
credentials-file: /Users/<username>/.cloudflared/<tunnel-id>.json
ingress:
  - hostname: webhooks.<domain>
    service: http://localhost:7842
  - service: http_status:404
```

Use the actual home directory path, tunnel ID, and the hostname from Step 4.

**Important:** The config MUST include:
- A `hostname` in the first ingress rule matching the DNS route
- A catch-all `http_status:404` rule at the end (cloudflared requires this)

---

## Step 6: Start the tunnel via the app

Call the `start_tunnel` MCP tool. This tells the ClaudeWebhooks menu bar app to start
the tunnel process using the config you just wrote. The app manages the process lifecycle
(health checks, auto-restart, etc.) and the UI will update to show the tunnel status.

Then call `get_tunnel_status` to get the public URL.

---

## Step 7: Confirm

Display the result:

> "Tunnel is active. Public URL: https://webhooks.\<domain\>"
>
> "You can now run /subscribe to set up webhook subscriptions. The tunnel URL is stable
> across restarts."

---

## Notes

- The tunnel URL is stable across restarts — it won't change.
- Credentials are stored at `~/.cloudflared/cert.pem` and `~/.cloudflared/<tunnel-id>.json`.
- Config is at `~/.config/cloudflared/config.yml`.
- To delete the tunnel later: `cloudflared tunnel delete claude-webhooks`.
