// Whoop connector: a remote MCP server that lets Claude (claude.ai, the desktop
// and mobile apps) read the data the Whoop app collects on the phone.
//
//   phone ──POST /ingest (bearer INGEST_TOKEN)──▶ D1 ◀── /mcp (OAuth) ── Claude
//
// The phone stays the source of truth. It pushes changed days here; Claude only
// ever reads. Two separate credentials on purpose: the phone's ingest token can
// write but cannot read, and Claude's OAuth grant can read but cannot write.
//
// Routes:
//   /mcp               MCP over Streamable HTTP, OAuth-protected (apiHandler)
//   /authorize         sign-in page Claude sends you to when connecting
//   /oauth/token       token endpoint (owned by the OAuth library)
//   /oauth/register    dynamic client registration, for clients without CIMD
//   /ingest            the phone's upload endpoint
//   /                  plain liveness text, no data

import {
  AuthorizationError,
  CimdFetchError,
  OAuthProvider,
  type ConsentDescription,
  type OAuthHelpers,
} from '@cloudflare/workers-oauth-provider';
import { WebStandardStreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js';

import { PushError, parsePush, statementsFor } from './schema';
import { buildServer } from './tools';

export interface Env {
  DB: D1Database;
  OAUTH_KV: KVNamespace;
  OAUTH_PROVIDER: OAuthHelpers;
  /** The phone's upload credential. */
  INGEST_TOKEN: string;
  /** What you type on the sign-in page when Claude connects. */
  OWNER_PASSWORD: string;
  USER_TZ?: string;
}

const SCOPE = 'health:read';
const OWNER = 'isa';

// ── helpers ─────────────────────────────────────────────────────────────────

const escape = (value: string) => value.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

/** Constant-time string compare, so a wrong password or token leaks nothing
 *  through response timing. */
async function same(a: string, b: string): Promise<boolean> {
  const enc = new TextEncoder();
  const [ha, hb] = await Promise.all([
    crypto.subtle.digest('SHA-256', enc.encode(a)),
    crypto.subtle.digest('SHA-256', enc.encode(b)),
  ]);
  return crypto.subtle.timingSafeEqual(ha, hb);
}

function head(title: string): string {
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${title}</title>
<style>
  :root { color-scheme: dark; }
  body { margin: 0; background: #000; color: #fff; font: 16px/1.5 -apple-system, system-ui, sans-serif; }
  main { max-width: 420px; margin: 0 auto; padding: 48px 16px; }
  h1 { font-size: 22px; margin: 0 0 12px; }
  p { color: #b3b3b3; margin: 0 0 16px; }
  strong { color: #fff; }
  .warn { color: #ffde00; }
  .err { color: #ff4d6a; }
  input { width: 100%; box-sizing: border-box; padding: 12px; border-radius: 10px; border: 1px solid #333;
          background: #121212; color: #fff; font-size: 16px; margin: 8px 0 16px; }
  /* Allow comes first in the DOM so pressing Enter in the password field
     approves (implicit submission uses the first submit button); the row is
     reversed so it still sits on the right. */
  .row { display: flex; flex-direction: row-reverse; gap: 12px; }
  button { flex: 1; padding: 12px; border-radius: 10px; border: 0; font-size: 16px; font-weight: 600; }
  .allow { background: #00f19f; color: #000; }
  .deny { background: #222; color: #fff; }
</style></head>
<body><main>`;
}

function consentPage(details: ConsentDescription, handle: string): string {
  const name = escape(details.clientName);
  const origin = details.clientDomain
    ? `Published by <strong>${escape(details.clientDomain)}</strong>.`
    : 'This app registered itself, so its name is not verified.';
  return `${head(`Connect ${name}`)}
  <h1>Let ${name} read your Whoop data?</h1>
  <p>${origin} Access goes to <strong>${escape(details.redirectHost)}</strong>.</p>
  ${details.redirectIsLoopback ? '<p class="warn">This sends access to an app on this computer. Continue only if you just started connecting from it.</p>' : ''}
  <p>Read-only: recovery, sleep, HRV, strain, Hevy lifts, Apple Health nutrition and weight.</p>
  ${passwordForm(handle)}`;
}

function retryPage(handle: string): string {
  return `${head('Connect')}
  <h1>Wrong password</h1>
  <p class="err">That was not the connector password. Try again.</p>
  ${passwordForm(handle)}`;
}

function passwordForm(handle: string): string {
  return `<form method="post">
    <input type="hidden" name="handle" value="${escape(handle)}">
    <label for="pw">Connector password</label>
    <input id="pw" name="password" type="password" autocomplete="current-password" autofocus>
    <div class="row">
      <button class="allow" name="decision" value="approve">Allow</button>
      <button class="deny" name="decision" value="deny">Deny</button>
    </div>
  </form>
</main></body></html>`;
}

const html = (body: string, headers: Headers, status = 200) => {
  headers.set('Content-Type', 'text/html; charset=utf-8');
  return new Response(body, { status, headers });
};

// ── /authorize ──────────────────────────────────────────────────────────────

async function authorize(request: Request, env: Env): Promise<Response> {
  const oauth = env.OAUTH_PROVIDER;
  try {
    if (request.method === 'GET') {
      const authRequest = await oauth.parseAuthRequest(request);
      const details = await oauth.describeConsent(authRequest);
      const consent = await oauth.beginConsent(authRequest);
      return html(consentPage(details, consent.handle), consent.headers);
    }
    if (request.method !== 'POST') return new Response('Method not allowed', { status: 405 });

    const form = await request.formData();
    const handle = String(form.get('handle') ?? '');
    if (form.get('decision') !== 'approve') {
      const denied = await oauth.denyConsent(request, handle);
      return new Response(null, { status: 302, headers: denied.headers });
    }

    // An unset secret must never mean "an empty password is correct".
    if (!env.OWNER_PASSWORD) {
      return new Response('Connector password is not configured.', { status: 503 });
    }
    if (!(await same(String(form.get('password') ?? ''), env.OWNER_PASSWORD))) {
      // Re-show the form with the SAME handle. Approve and deny both consume a
      // handle; a mistyped password must not, or one typo would force a fresh
      // connect from Claude. The consent details were on the page just shown.
      // The delay slows guessing; there is exactly one legitimate user.
      await new Promise((r) => setTimeout(r, 1500));
      return html(retryPage(handle), new Headers(), 401);
    }

    const approved = await oauth.approveConsent(request, handle, { scope: [SCOPE] });
    const { redirectTo } = await oauth.completeAuthorization({
      request: approved.request,
      userId: OWNER,
      metadata: {},
      scope: approved.request.scope.filter((s) => s === SCOPE || s === 'offline_access'),
      props: { userId: OWNER },
    });
    approved.headers.set('Location', redirectTo);
    return new Response(null, { status: 302, headers: approved.headers });
  } catch (error) {
    if (error instanceof AuthorizationError && error.redirectTo) {
      return Response.redirect(error.redirectTo, 302);
    }
    if (error instanceof AuthorizationError || error instanceof CimdFetchError) {
      const message = error instanceof AuthorizationError ? error.description : 'This app could not be verified.';
      return new Response(message, { status: 400, headers: { 'Content-Type': 'text/plain; charset=utf-8' } });
    }
    throw error;
  }
}

// ── /ingest ─────────────────────────────────────────────────────────────────

async function ingest(request: Request, env: Env): Promise<Response> {
  if (request.method !== 'POST') return new Response('Method not allowed', { status: 405 });
  const auth = request.headers.get('Authorization') ?? '';
  const token = auth.startsWith('Bearer ') ? auth.slice(7) : '';
  if (!env.INGEST_TOKEN || !(await same(token, env.INGEST_TOKEN))) {
    return new Response('Unauthorized', { status: 401 });
  }
  // Pushes are chunked by the phone; anything this large is a bug, not data.
  const length = Number(request.headers.get('Content-Length') ?? '0');
  if (length > 2_000_000) return new Response('Payload too large', { status: 413 });

  let body;
  try {
    body = parsePush(await request.json());
  } catch (e) {
    const msg = e instanceof PushError ? e.message : 'invalid JSON';
    return Response.json({ ok: false, error: msg }, { status: 400 });
  }

  const statements: D1PreparedStatement[] = [];
  for (const t of body.tables) {
    for (const s of statementsFor(t)) statements.push(env.DB.prepare(s.sql).bind(...s.params));
  }
  const now = new Date().toISOString();
  statements.push(
    env.DB.prepare("INSERT OR REPLACE INTO meta (key, value) VALUES ('last_push', ?)").bind(now),
  );
  if (body.app_version) {
    statements.push(
      env.DB.prepare("INSERT OR REPLACE INTO meta (key, value) VALUES ('app_version', ?)").bind(body.app_version),
    );
  }
  // One batch = one transaction: a push lands whole or not at all.
  await env.DB.batch(statements);
  return Response.json({
    ok: true,
    tables: body.tables.map((t) => ({ table: t.table, days: t.days.length, rows: t.rows.length })),
  });
}

// ── /mcp ────────────────────────────────────────────────────────────────────

const mcpHandler = {
  async fetch(request: Request, env: Env): Promise<Response> {
    // Stateless server: no session to resume and nothing to push unprompted,
    // so there is no long-lived GET stream to offer (MCP lets a server say 405).
    if (request.method !== 'POST') {
      return new Response('Method not allowed', { status: 405, headers: { Allow: 'POST' } });
    }
    const server = buildServer(env);
    const transport = new WebStandardStreamableHTTPServerTransport({
      sessionIdGenerator: undefined,
      enableJsonResponse: true,
    });
    await server.connect(transport);
    return transport.handleRequest(request);
  },
};

// ── everything else ─────────────────────────────────────────────────────────

const defaultHandler = {
  async fetch(request: Request, env: Env): Promise<Response> {
    const { pathname } = new URL(request.url);
    if (pathname === '/authorize') return authorize(request, env);
    if (pathname === '/ingest') return ingest(request, env);
    if (pathname === '/') return new Response('Whoop connector. Add /mcp to Claude as a custom connector.\n');
    return new Response('Not found', { status: 404 });
  },
};

// The OAuth resource must be this Worker's own /mcp URL, which is only known
// from the request (workers.dev in production, localhost under `wrangler dev`).
// Build one provider per origin and reuse it for the isolate's lifetime.
const providers = new Map<string, OAuthProvider<Env>>();

function providerFor(origin: string): OAuthProvider<Env> {
  let p = providers.get(origin);
  if (!p) {
    p = new OAuthProvider<Env>({
      apiRoute: '/mcp',
      apiHandler: mcpHandler,
      defaultHandler,
      authorizeEndpoint: '/authorize',
      tokenEndpoint: '/oauth/token',
      clientRegistrationEndpoint: '/oauth/register',
      clientIdMetadataDocumentEnabled: true,
      scopesSupported: [SCOPE, 'offline_access'],
      requiredScopes: [SCOPE],
      resourceMetadata: {
        resource: `${origin}/mcp`,
        authorization_servers: [origin],
      },
      // A grant lasts while Claude keeps using it, and lapses after 60 idle days.
      refreshTokenTTL: 90 * 86_400,
      refreshTokenIdleTTL: 60 * 86_400,
    });
    providers.set(origin, p);
  }
  return p;
}

export default {
  fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    return providerFor(new URL(request.url).origin).fetch(request, env, ctx);
  },
} satisfies ExportedHandler<Env>;
