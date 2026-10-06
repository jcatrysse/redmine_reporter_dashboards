// Administration: the plugin settings page (assets, mail, engine), the render preflight
// (admin menu) with a real engine run, and the statistics JSON endpoint; refusals.
import { e2e } from '../../.codex/e2e/lib.mjs';

const t = await e2e('admin');
const fail = (msg) => t.problems.push(msg);

await t.login('admin');
await t.go('/settings/plugin/redmine_reporter_dashboards');
await t.sudo();
await t.shot('settings', 'Plugin settings: asset policy, mail limits, external addresses and the PDF engine preference');
// Save unchanged: round trip.
await t.page.locator('#content input[type=submit]').first().click();
await t.page.waitForLoadState('load');
await t.settle();
await t.sudo();
t.check('save settings');
if (!(await t.page.locator('#flash_notice').count())) fail('saving the plugin settings shows no confirmation');
await t.shot('settings-saved', 'Settings saved: Redmine\'s "Successful update" notice');

// Preflight from the admin menu.
await t.go('/admin');
if (!(await t.page.locator('a', { hasText: 'Render preflight' }).count())) fail('admin menu has no "Render preflight"');
await t.go('/admin/reporter_dashboards/preflight');
await t.shot('preflight', 'Render preflight page: the engines this host offers and the run button');
await t.page.locator('#content input[type=submit]').first().click();
await t.page.waitForLoadState('load');
await t.settle();
await t.sudo();
t.check('preflight run');
const out = (await t.page.locator('#content').innerText()).replace(/\s+/g, ' ');
console.log('  preflight: ' + out.slice(0, 400));
await t.shot('preflight-run', 'Preflight run: each engine renders a probe and reports what actually worked');

// Statistics endpoint (JSON), as admin, manager, outsider on the private project, and anonymous.
async function json(path) {
  const r = await t.page.request.get(t.BASE + path);
  let body = null;
  try { body = await r.json(); } catch { /* not json */ }
  return [r.status(), body];
}
let [s, b] = await json('/sql/stats/monthly_flow?project_id=e2e-project&months=3');
if (s !== 200 || !b || !Array.isArray(b.labels) || b.labels.length !== 3) fail(`stats as admin: ${s} ${JSON.stringify(b)}`);
else console.log(`  stats admin: total=${b.total} labels=${b.labels.join(',')}`);
[s, b] = await json('/sql/stats/monthly_flow?project_id=e2e-project&months=999');
if (s !== 200 || b.months !== 24) fail(`stats months cap: ${s} months=${b && b.months}`);
[s] = await json('/sql/stats/monthly_flow?project_id=nope');
if (s !== 404) fail(`stats unknown project: ${s}`);
await t.go('/sql/stats/monthly_flow?project_id=e2e-project&months=3');
await t.shot('stats-json', 'The monthly-flow statistics endpoint answers JSON for a visible project (months capped at 24)', { full: false });

await t.login('outsider');
[s] = await json('/sql/stats/monthly_flow?project_id=e2e-private');
if (s !== 404) fail(`stats private project as outsider: ${s}, expected 404`);
await t.go('/settings/plugin/redmine_reporter_dashboards', { status: 403 });
await t.go('/admin/reporter_dashboards/preflight', { status: 403 });
await t.shot('outsider-refused', 'A non-admin: plugin settings and preflight refused (403); the private project\'s statistics answer 404');

await t.anonymous();
const r = await t.page.request.get(t.BASE + '/sql/stats/monthly_flow?project_id=e2e-project', { maxRedirects: 0 });
if (r.status() === 200) fail('anonymous got statistics');

await t.done();
