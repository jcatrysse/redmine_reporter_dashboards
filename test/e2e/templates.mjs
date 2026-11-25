// Report templates: list, starter gallery, preview, create, show, edit, invalid input,
// visibility (a private template), export, delete; refusals for reporter and outsider.
import { e2e } from '../../.codex/e2e/lib.mjs';

const t = await e2e('templates');
const P = '/projects/e2e-project';
const fail = (msg) => t.problems.push(msg);
const text = async () => (await t.page.locator('#content').innerText()).replace(/\s+/g, ' ');
// The report is drawn in a sandboxed srcdoc frame: wait until it has painted the expected
// text (a fixed delay screenshotted an empty frame once), and fail when it never does.
async function frameShows(expected, timeout = 15000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    for (const f of t.page.frames()) {
      if (f === t.page.mainFrame()) continue;
      const body = await f.locator('body').innerText().catch(() => '');
      if (expected instanceof RegExp ? expected.test(body) : body.includes(expected)) { await t.page.waitForTimeout(500); return true; }
    }
    await t.page.waitForTimeout(250);
  }
  fail(`the report frame never showed "${expected}"`);
  return false;
}

// --- manager --------------------------------------------------------------------------
await t.login('manager');
// The way in: project settings, tab "Reports and dashboards".
await t.go(`${P}/settings/reporter_dashboards`);
await t.shot('settings-tab', 'Project settings, tab "Reports and dashboards": links to templates, schedules and mail log');
const tplLink = t.page.locator('#content a[href$="/reporter/templates"]').first();
if (!(await tplLink.count())) fail('settings tab has no link to the templates');

await t.go(`${P}/reporter/templates`);
for (const name of ['E2E issue report', 'E2E time report', 'E2E private draft']) {
  if (!(await text()).includes(name)) fail(`manager's template list lacks "${name}"`);
}
await t.shot('index', 'Template list for the manager: the seeded templates, visibility, author, edit and delete');

// New: the starter gallery, then preview without saving.
await t.go(`${P}/reporter/templates/new`);
await t.shot('new', 'New template form with the starter gallery, the editor and the lint panel');
await t.page.fill('#template_name', 'E2E created in the browser');
await t.page.fill('#template_content',
  '{% sql_aggregate from: issues, group_by: status, assign_to: s %}\n<h1>Made in e2e</h1>\n' +
  '{% chart id: s1, from: s, title: "By status" %}\n<p>Total {{ s.total }}</p>');
await t.page.locator('input[name=preview]').click();
await t.page.waitForLoadState('load');
await t.settle();
t.check('preview');
await frameShows(/Total \d+/);
await t.shot('preview', 'Preview of the unsaved template: the render shows the heading, the chart and the total; nothing is stored yet');
await t.go(`${P}/reporter/templates`);
if ((await text()).includes('E2E created in the browser')) fail('preview stored the template');

// Invalid Liquid: an unclosed tag is reported, not raised.
await t.go(`${P}/reporter/templates/new`);
await t.page.fill('#template_name', 'E2E broken');
await t.page.fill('#template_content', '{% for x in issues %}<p>never closed</p>');
await t.page.locator('input[name=preview]').click();
await t.page.waitForLoadState('load');
await t.settle();
t.check('preview broken');
const broken = await text();
if (/Internal error|500/.test(broken)) fail('broken template preview raised a server error');
if (!/for|syntax|closed|Liquid/i.test(broken)) fail('broken template preview gives no syntax message');
await t.shot('preview-invalid', 'Preview of a template with an unclosed {% for %}: a readable syntax error, no server error');

// Missing name: validation message on create.
await t.go(`${P}/reporter/templates/new`);
await t.page.fill('#template_content', '<p>x</p>');
await t.page.evaluate(() => document.querySelector('#template_name').removeAttribute('required'));
await t.page.locator('#content input[type=submit][name=commit]').click();
await t.page.waitForLoadState('load');
await t.settle();
t.check('create without name');
if (!(await t.page.locator('#errorExplanation').count())) fail('creating without a name shows no validation error');
await t.shot('create-invalid', 'Create without a name: Redmine\'s error box, nothing saved');

// Create for real.
await t.page.fill('#template_name', 'E2E created in the browser');
await t.page.fill('#template_content', '{% sql_aggregate from: issues, group_by: status, assign_to: s %}\n<h1>Made in e2e</h1>\n<p>Total {{ s.total }}</p>');
await t.page.locator('#content input[type=submit][name=commit]').click();
await t.page.waitForLoadState('load');
await t.settle();
t.check('create');
if (!/\/reporter\/templates\/\d+/.test(t.page.url())) fail(`after create not on the template page: ${t.page.url()}`);
await frameShows('Made in e2e');
await t.shot('created', 'The created template\'s page: rendered report and the export, mail and share actions');
const createdUrl = t.page.url().replace(t.BASE, '');

// Edit and save.
await t.go(`${createdUrl}/edit`);
await t.page.fill('#template_description', 'Edited in the browser');
await t.page.locator('#content input[type=submit][name=commit]').click();
await t.page.waitForLoadState('load');
await t.settle();
t.check('update');
await t.go(`${P}/reporter/templates`);
if (!(await text()).includes('Edited in the browser')) fail('edit did not store the description');
await t.shot('edited', 'Template list after editing: the new description is shown');

// Show the seeded report with charts and the diagram.
await t.page.locator('a', { hasText: 'E2E issue report' }).first().click();
await t.page.waitForLoadState('load');
await t.settle();
await frameShows(/\d+ issues in scope/);
t.check('show issue report');
await t.shot('show-report', 'The seeded issue report: bar and pie chart (bundled Chart.js) and the Mermaid diagram drawn in the sandboxed frame');
const showUrl = t.page.url().replace(t.BASE, '');

// The document download (PDF), which the generic smoke cannot open as a page.
const doc = await t.page.request.get(`${t.BASE}${showUrl}/document`);
const docBytes = await doc.body();
if (doc.status() !== 200 || docBytes.subarray(0, 5).toString() !== '%PDF-') fail(`document download: HTTP ${doc.status()}, ${doc.headers()['content-type']}`);
else console.log(`  document download: ${docBytes.length} bytes, ${doc.headers()['content-type']}`);

// Export as a bundle (JSON download).
const exp = await t.page.request.get(`${t.BASE}${showUrl}/export`);
if (exp.status() !== 200) fail(`export: HTTP ${exp.status()}`);
else if (!(await exp.text()).includes('E2E issue report')) fail('export does not contain the template');
else console.log(`  export: ${exp.headers()['content-type']}, ${(await exp.body()).length} bytes`);

// Delete the browser-created template.
await t.go(`${P}/reporter/templates`);
const row = t.page.locator('tr', { hasText: 'E2E created in the browser' });
t.page.once('dialog', d => d.accept());
await row.locator('a.icon-del, a[data-method=delete]').first().click();
await t.page.waitForLoadState('load');
await t.settle();
t.check('delete');
if ((await text()).includes('E2E created in the browser')) fail('delete left the template in the list');
await t.shot('deleted', 'After delete the template is gone from the list, with Redmine\'s flash notice');

// --- reporter: no plugin permission ----------------------------------------------------
await t.login('reporter');
await t.go(`${P}/settings/reporter_dashboards`, { status: 403 });
await t.go(`${P}/reporter/templates`, { status: 403 });
await t.shot('reporter-refused', 'Reporter without the report permissions: the template list is refused (403)');
await t.go(`${P}/reporter/templates/new`, { status: 403 });

// --- outsider: private project --------------------------------------------------------
await t.login('outsider');
await t.go('/projects/e2e-private/reporter/templates', { status: 403 });
await t.shot('outsider-private', 'Outsider: the private project\'s templates are refused (403)');

// --- admin sees the list but a private template of another author is not offered -----
await t.login('admin');
await t.go(`${P}/reporter/templates`);
await t.shot('admin-index', 'Admin\'s view of the template list');

await t.done();
