# Whoop connector

A remote MCP server on Cloudflare Workers that lets Claude read what the Whoop
app collects: band recovery, HRV, sleep and strain, Hevy lifts, Apple Health
(nutrition, weight, phone steps), weather and calendar load. Claude has no
Apple Health connector of its own, and it cannot reach a phone, so the app
pushes a copy here and Claude reads it.

```
phone (lib/integrations/claude_connector.dart)
   └─ POST /ingest, bearer INGEST_TOKEN ─▶ D1 ◀─ /mcp, OAuth ─ Claude
```

- The phone is the source of truth. It pushes changed days only (hashed per
  table and day), so normal use stays far inside D1's free write quota.
- Two credentials on purpose: the ingest token can write but not read; the
  OAuth grant Claude holds can read but not write.
- Every tool is read-only. `run_sql` only accepts a single SELECT
  (`src/sqlguard.ts`).
- Raw sensor data (`decoded_*`, `raw_*`) never leaves the phone.

Deployed to the owner's Cloudflare account (pinned by
`account_id` in `wrangler.jsonc`). Free plan: Workers, D1, KV.

## Add it to Claude

claude.ai → Settings → Connectors → Add custom connector, URL
`https://<your-worker-url>/mcp`, then Connect. The page
that opens asks for the connector password (`.secrets.local`, OWNER_PASSWORD).
Once added on claude.ai it is available in the desktop and mobile apps too. The
grant renews itself while used and lapses after 60 idle days.

## Phone side

`.env` in the edge root needs:

```
CONNECTOR_URL=https://<your-worker-url>
CONNECTOR_TOKEN=<INGEST_TOKEN from .secrets.local>
```

Then rebuild. Profile → Claude connector shows the last push and has
"Push now" and "Re-send all" (use the latter after a fresh deploy or a
`kAlgoVersion` bump that re-derives history).

## Develop

```
npm install
npm run typecheck && npm test                    # unit tests, no network
npx wrangler d1 migrations apply whoop --local
npx wrangler dev                                 # .dev.vars holds local secrets
node test/e2e.mjs http://localhost:8787 <ingest> <password> [pushes.json]
```

`test/e2e.mjs` walks the whole thing the way Claude does: upload, register,
authorize with PKCE, sign in, exchange the code, call every kind of tool, and
check that `run_sql` refuses a DELETE.

## Deploy

```
npx wrangler d1 migrations apply whoop --remote   # after adding a migration
npx wrangler deploy
npx wrangler secret put OWNER_PASSWORD            # only to rotate
npx wrangler secret put INGEST_TOKEN              # then update .env and rebuild
```
