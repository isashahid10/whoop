// End-to-end check against a running connector (wrangler dev or deployed).
//   node test/e2e.mjs <base-url> <ingest-token> <password> [pushes.json]
// Uploads the given push chunks, walks the OAuth flow the way Claude does
// (register, authorize with PKCE, sign in, exchange the code), then calls tools.
import { createHash, randomBytes } from 'node:crypto';
import { readFileSync } from 'node:fs';

const [base, ingestToken, password, pushFile] = process.argv.slice(2);
const b64url = (buf) => buf.toString('base64url');
const must = (cond, msg) => { if (!cond) { console.error('FAIL', msg); process.exit(1); } };

if (pushFile) {
  for (const chunk of JSON.parse(readFileSync(pushFile, 'utf8'))) {
    const r = await fetch(`${base}/ingest`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${ingestToken}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(chunk),
    });
    const body = await r.json();
    must(r.ok && body.ok, `ingest ${r.status} ${JSON.stringify(body)}`);
  }
  console.log('ingest ok');
}
const bad = await fetch(`${base}/ingest`, { method: 'POST', headers: { Authorization: 'Bearer nope' }, body: '{}' });
must(bad.status === 401, 'ingest accepted a wrong token');

const redirect = 'http://localhost:9999/cb';
const reg = await (await fetch(`${base}/oauth/register`, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ client_name: 'e2e', redirect_uris: [redirect], token_endpoint_auth_method: 'none' }),
})).json();
must(reg.client_id, `register ${JSON.stringify(reg)}`);

const verifier = b64url(randomBytes(32));
const challenge = b64url(createHash('sha256').update(verifier).digest());
const q = new URLSearchParams({
  response_type: 'code', client_id: reg.client_id, redirect_uri: redirect, scope: 'health:read',
  state: 'st', code_challenge: challenge, code_challenge_method: 'S256', resource: `${base}/mcp`,
});
const authPage = await fetch(`${base}/authorize?${q}`);
const html = await authPage.text();
must(authPage.ok, `authorize GET ${authPage.status} ${html.slice(0, 200)}`);
const handle = html.match(/name="handle" value="([^"]+)"/)?.[1];
const cookie = authPage.headers.getSetCookie().map((c) => c.split(';')[0]).join('; ');
must(handle, 'no handle on the consent page');

const post = (pw) => fetch(`${base}/authorize`, {
  method: 'POST', redirect: 'manual',
  headers: { 'Content-Type': 'application/x-www-form-urlencoded', Cookie: cookie, Origin: base },
  body: new URLSearchParams({ handle, password: pw, decision: 'approve' }),
});
const wrong = await post('not-it');
must(wrong.status === 401, `wrong password gave ${wrong.status}`);
const ok = await post(password);
const loc = ok.headers.get('Location');
must(ok.status === 302 && loc?.startsWith(redirect), `approve ${ok.status} ${loc} ${await ok.text()}`);
const code = new URL(loc).searchParams.get('code');

const tok = await (await fetch(`${base}/oauth/token`, {
  method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
  body: new URLSearchParams({
    grant_type: 'authorization_code', code, redirect_uri: redirect, client_id: reg.client_id,
    code_verifier: verifier, resource: `${base}/mcp`,
  }),
})).json();
must(tok.access_token, `token ${JSON.stringify(tok)}`);
console.log('oauth ok, scope:', tok.scope, 'refresh:', Boolean(tok.refresh_token));

let id = 0;
const rpc = async (method, params) => {
  const r = await fetch(`${base}/mcp`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${tok.access_token}`, 'Content-Type': 'application/json',
      Accept: 'application/json, text/event-stream', 'MCP-Protocol-Version': '2025-06-18',
    },
    body: JSON.stringify({ jsonrpc: '2.0', id: ++id, method, params }),
  });
  const body = await r.json();
  must(r.ok && !body.error, `${method} ${r.status} ${JSON.stringify(body).slice(0, 300)}`);
  return body.result;
};
const init = await rpc('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'e2e', version: '1' } });
console.log('server:', init.serverInfo.name, init.protocolVersion);
const tools = await rpc('tools/list', {});
console.log('tools:', tools.tools.map((t) => t.name).join(', '));
const call = async (name, args = {}) => {
  const res = await rpc('tools/call', { name, arguments: args });
  const text = res.content[0].text;
  console.log(`\n# ${name} ${JSON.stringify(args)}${res.isError ? ' (isError)' : ''}\n${process.env.E2E_FULL ? text : text.slice(0, 700)}`);
  return res;
};
await call('overview');
await call('get_days', { start_date: '2026-10-20', end_date: '2026-10-24' });
await call('get_lift_sessions', { start_date: '2026-09-20', end_date: '2026-09-30' });
await call('get_lifts', { start_date: '2026-09-01', end_date: '2026-09-30', exercise: 'squat' });
await call('get_sleep', { date: '2026-10-24' });
await call('run_sql', { sql: `SELECT a.date, a.value AS protein_g, b.value AS next_readiness FROM metric a JOIN metric b
  ON b.key='readiness' AND b.date = date(a.date,'+1 day') WHERE a.key='hk_protein_g' ORDER BY a.date` });
const refused = await call('run_sql', { sql: 'DELETE FROM metric' });
must(refused.isError, 'run_sql allowed a DELETE');
console.log('\nE2E PASS');
