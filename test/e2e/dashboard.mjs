// Project dashboard: the page, its tabs, its widgets and the report widget's PDF.
// Functions: view dashboard, add/remove/move a widget, configure the report widget,
// add/rename/delete a tab, report widget PDF; refusals for reporter and outsider.
import { e2e } from '../../.codex/e2e/lib.mjs';

const t = await e2e('dashboard');
const P = '/projects/e2e-project';
const fail = (msg) => t.problems.push(msg);

// --- manager: the page, empty or not --------------------------------------------------
await t.login('manager');
await t.go(`${P}/reporter`);
if (!(await t.page.locator('#main-menu a', { hasText: 'Project dashboard' }).count())) fail('manager: no "Project dashboard" in the project menu');
await t.shot('manager-initial', 'Manager opens the project dashboard from the project menu: tab bar, widget picker and settings toggle are there');

// Add a tab through the settings box.
await t.go(`${P}/reporter?new_tab=1`);
await t.shot('new-tab-form', 'The "new tab" form in the dashboard settings box');
const title = t.page.locator('#reporter-dashboard-settings input[type=text]').first();
await title.fill('E2E tab');
await t.page.locator('#reporter-dashboard-settings input[type=submit]').first().click();
await t.settle();
t.check('create tab');
if (!(await t.page.locator('.tabs a', { hasText: 'E2E tab' }).count())) fail('the new tab "E2E tab" is not in the tab bar');
await t.shot('tab-created', 'The new tab "E2E tab" is created and selected');

// Add widgets via the picker (the select submits its form on change).
async function addBlock(value) {
  const select = t.page.locator('#reporter-block-form select');
  await select.selectOption(value);
  await t.page.waitForLoadState('load');
  await t.settle();
  t.check(`add block ${value}`);
}
for (const b of ['issuequery', 'activity', 'timelog', 'report_by_issues']) await addBlock(b);
await t.shot('widgets-added', 'Four widgets added: issue query, activity, spent time and the issue report widget (asking for its template)');

// Configure the report widget: pick the seeded template.
const tplSelect = t.page.locator('select[name="settings[report_by_issues][report_template_id]"]');
if (await tplSelect.count()) {
  await tplSelect.selectOption({ label: 'E2E issue report' });
  await t.page.locator('#report_by_issues-settings input[type=submit]').click();
  await t.page.waitForTimeout(1500);
  await t.go(t.page.url().replace(t.BASE, ''));
} else fail('report widget settings form not found');
const frame = t.page.locator('iframe').first();
if (!(await frame.count())) fail('report widget: no rendered report frame after choosing a template');
await t.page.waitForTimeout(2500); // Chart.js and Mermaid draw inside the sandboxed frame
await t.shot('report-widget', 'The report widget renders "E2E issue report" inside the dashboard, with its chart and diagram');

// Report widget PDF.
const pdfLink = t.page.locator('a[href*="report_pdf"]').first();
if (await pdfLink.count()) {
  const href = await pdfLink.getAttribute('href');
  const res = await t.page.request.get(t.BASE + href);
  const body = await res.body();
  const head = body.subarray(0, 5).toString();
  if (res.status() !== 200 || head !== '%PDF-') fail(`report widget PDF: HTTP ${res.status()}, starts with ${JSON.stringify(head)}`);
  else console.log(`  report widget PDF: ${body.length} bytes, ${res.headers()['content-type']}`);
} else fail('report widget: no PDF link');

// Move a widget and remove one.
const moveLink = t.page.locator('#reporter-project-page a[href*="move_block"], #reporter-project-page [data-method="patch"]').first();
if (await moveLink.count()) {
  await moveLink.click();
  await t.page.waitForTimeout(1500);
  await t.go(t.page.url().replace(t.BASE, ''));
  t.check('move block');
  await t.shot('widget-moved', 'After pressing a move arrow the widget order changed and the page reloads cleanly');
} else fail('no move control on the widgets');
const removeLink = t.page.locator('#reporter-project-page a[href*="remove_block"]').first();
if (await removeLink.count()) {
  t.page.once('dialog', d => d.accept());
  await removeLink.click();
  await t.page.waitForTimeout(1500);
  await t.go(t.page.url().replace(t.BASE, ''));
  t.check('remove block');
  await t.shot('widget-removed', 'A widget removed with its close control; the others stay');
} else fail('no remove control on the widgets');

// --- reporter: core Reporter role, none of the plugin's permissions -------------------
await t.login('reporter');
await t.go(`${P}`);
if (await t.page.locator('#main-menu a', { hasText: 'Project dashboard' }).count()) fail('reporter sees the dashboard menu item without the permission');
await t.go(`${P}/reporter`, { status: 403 });
await t.shot('reporter-refused', 'Reporter (no plugin permission): the dashboard is refused with 403 and the menu item is absent');

// --- outsider: the private project does not exist for them ---------------------------
await t.login('outsider');
await t.go('/projects/e2e-private/reporter', { status: 403 });
await t.shot('outsider-private', 'Outsider on the private project dashboard: refused, nothing of the project is shown');

// --- anonymous -----------------------------------------------------------------------
await t.anonymous();
await t.go(`${P}/reporter`);
if (!t.page.url().includes('/login')) fail(`anonymous was not sent to login: ${t.page.url()}`);
await t.shot('anonymous-login', 'Anonymous on the dashboard is sent to the login page');

await t.done();
