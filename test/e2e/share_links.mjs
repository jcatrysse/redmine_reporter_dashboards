// Share links: mint a snapshot link, open it anonymously, revoke it, revoked and unknown
// tokens refused, max_uses honoured; refusals for reporter and outsider.
import { e2e } from '../../.codex/e2e/lib.mjs';

const t = await e2e('share_links');
const P = '/projects/e2e-project';
const fail = (msg) => t.problems.push(msg);

await t.login('manager');
await t.go(`${P}/reporter/templates`);
await t.page.locator('a', { hasText: 'E2E issue report' }).first().click();
await t.page.waitForLoadState('load');
const showUrl = t.page.url().replace(t.BASE, '');
const sharesUrl = `${showUrl}/shares`;

await t.go(sharesUrl);
await t.shot('index-empty', 'Share links of "E2E issue report" before any link exists: the empty state and the create action');

async function mint(purpose, maxUses) {
  await t.go(`${sharesUrl}/new`);
  await t.page.fill('#purpose', purpose).catch(() => t.page.fill('input[name=purpose]', purpose));
  if (maxUses) await t.page.fill('input[name=max_uses]', String(maxUses)).catch(() => fail('no max_uses field'));
  await t.page.locator('#content input[type=submit]').first().click();
  await t.page.waitForLoadState('load');
  await t.settle();
  t.check(`mint ${purpose}`);
  const url = await t.page.locator('input[readonly]').first().inputValue().catch(() => '');
  if (!/\/reporter\/s\/[A-Za-z0-9_-]+/.test(url)) fail(`minting "${purpose}" showed no share URL`);
  return url;
}

await t.go(`${sharesUrl}/new`);
await t.shot('new', 'The new share link form: purpose, expiry, use limit, public flag');
const url = await mint('E2E review', 0);
await t.shot('created', 'Link created: the URL is shown once, the list shows expiry, uses and the revoke action');

// Open it anonymously in a fresh context.
const path = url.replace(/^https?:\/\/[^/]+/, '');
await t.anonymous();
const res = await t.page.request.get(t.BASE + path);
const body = await res.body();
if (res.status() !== 200) fail(`anonymous share open: HTTP ${res.status()}`);
else console.log(`  share link served ${body.length} bytes, ${res.headers()['content-type']}`);
await t.go(path).catch(() => {});
await t.shot('anonymous-open', 'The share link opened anonymously serves the frozen snapshot (PDF)', { full: false });

// Unknown token.
await t.go('/reporter/s/thisIsNotAToken123', { status: 404 });
await t.shot('unknown-token', 'An unknown token: refused with 404 and nothing about the report');

// Single-use link: second use refused.
await t.login('manager');
const once = await mint('E2E single use', 1);
const oncePath = once.replace(/^https?:\/\/[^/]+/, '');
await t.anonymous();
const r1 = await t.page.request.get(t.BASE + oncePath);
const r2 = await t.page.request.get(t.BASE + oncePath);
if (r1.status() !== 200 || r2.status() === 200) fail(`single-use link: first ${r1.status()}, second ${r2.status()}`);
await t.go(oncePath, { status: r2.status() });
await t.shot('single-use-exhausted', `A single-use link opened a second time is refused (HTTP ${r2.status()})`);

// Revoke the first link, then it is refused.
await t.login('manager');
await t.go(sharesUrl);
const row = t.page.locator('tr', { hasText: 'E2E review' });
t.page.once('dialog', d => d.accept());
await row.locator('a[href*="revoke"], input[type=submit], button').first().click();
await t.page.waitForLoadState('load');
await t.settle();
t.check('revoke');
await t.shot('revoked', 'After revoking, the list marks the link revoked');
await t.anonymous();
const r3 = await t.page.request.get(t.BASE + path);
if (r3.status() === 200) fail('a revoked link still serves');
await t.go(path, { status: r3.status() });
await t.shot('revoked-open', `The revoked link is refused (HTTP ${r3.status()}) with the refusal page`);

// Reporter and outsider cannot reach the share management.
await t.login('reporter');
await t.go(sharesUrl, { status: 403 });
await t.shot('reporter-refused', 'Reporter without share permission: the share link list is refused (403)');
await t.login('outsider');
await t.go(sharesUrl, { status: 403 });

await t.done();
