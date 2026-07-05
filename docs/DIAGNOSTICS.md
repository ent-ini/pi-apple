# Diagnostics Gateway

pi-app includes an opt-in diagnostics gateway for debugging a live macOS app instance over Tailscale.

The gateway runs inside the Mac app itself. It does **not** proxy through `pi-appd`.

## Enable

Open the macOS app:

```text
Settings -> Diagnostics Gateway -> Enable direct diagnostics gateway
```

When enabled, the app listens on TCP port `8765`.

Use the Mac's Tailscale IP/hostname from the debugging machine. In Artemiy's current tailnet the Mac is commonly reachable as:

```text
http://100.100.11.2:8765
```

## Authentication

Every request must include the same bearer token that the app uses for the Remote API / `pi-appd`.

```http
Authorization: Bearer <token>
```

The token is never printed in the Settings UI. The copied curl command uses `$APPLEPI_TOKEN`.

## Endpoints

### Health

```sh
curl -H "Authorization: Bearer $APPLEPI_TOKEN" \
  "http://100.100.11.2:8765/diagnostics/health"
```

Example response:

```json
{"ok":true,"app":"pi-app","records":124}
```

### Logs

```sh
curl -sS -H "Authorization: Bearer $APPLEPI_TOKEN" \
  "http://100.100.11.2:8765/diagnostics/logs?tail=300"
```

The response is JSONL / NDJSON, one record per line.

`tail` is optional. If omitted, the gateway returns the in-memory ring buffer.

## What is logged

The diagnostics buffer is intentionally structured and redacted. Current categories include:

- `app.lifecycle` — app startup/shutdown-level events.
- `app.status` — user-visible app status changes.
- `remote.http` — ordinary `pi-appd` HTTP requests: method, host, path, query, status, duration, errors.
- `remote.catalog-sse` — catalog SSE lifecycle.
- `remote.session-sse` — selected session SSE lifecycle and line events.
- `remote.turn-stream` — send/input stream lifecycle.
- `remote.turn-stream.event` — sampled turn stream event types.
- `send.lifecycle` / `send.remote` — prompt acceptance, remote turn start/finish/failure.
- `session.reload` — transcript reload pages and failures.
- `session.catchup` — selected-session delta/catch-up requests.
- `session.history` — `hasEarlierHistory`, Load Earlier, pagination transitions.
- `session.status` — per-chat status changes.
- `diagnostics.gateway` — gateway start and requests.

High-volume streaming text events are sampled so the ring buffer keeps useful context.

## Security model

- Disabled by default.
- Must be enabled manually in Settings.
- Protected by bearer token.
- Secret-looking values are redacted before entering the diagnostics buffer.
- Intended for Tailscale/private-network debugging, not public internet exposure.
- Disable the gateway when debugging is done.

## Troubleshooting

### Connection refused

The gateway is not listening. Check:

1. The app is running.
2. The Settings toggle is enabled.
3. The app was rebuilt from a commit that contains diagnostics gateway support.
4. The Mac is reachable over Tailscale.

On the Mac:

```sh
lsof -nP -iTCP:8765 -sTCP:LISTEN
```

### 401 Unauthorized

The bearer token is missing or does not match the stored Remote API token for the app's current daemon host.

### Empty or old logs

The buffer is in-memory and resets when the app restarts. Trigger the app behavior again, then re-run `/diagnostics/logs`.

## Quick command for Ini/homelab

On homelab, where `PI_APPD_TOKEN` is stored in the local secrets file:

```sh
set -a
source /home/agent/ai-agent/workspace/.secrets/pi-appd.env
set +a

curl -sS -H "Authorization: Bearer $PI_APPD_TOKEN" \
  "http://100.100.11.2:8765/diagnostics/logs?tail=300"
```
