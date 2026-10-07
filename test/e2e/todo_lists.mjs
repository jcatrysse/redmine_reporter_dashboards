// To-do lists of redmine_issue_todo_lists2 in a report template (Jan, 2026-10-07, round 2):
// offered by this plugin, with the permissions of whoever views the report.
//   manager   may view to-do lists: the template shows the seeded list and the positions
//   listless  may read the report, not the to-do lists: same issues, no list, count 0
//   reporter / outsider: the template itself is refused
// Without the todo plugin the same template renders with every count 0, no error.
import { e2e } from '../../.codex/e2e/lib.mjs';

const t = await e2e('todo_lists');
const P = '/projects/e2e-project';
const fail = (msg) => t.problems.push(msg);

async function frameText(expected, timeout = 15000) {
  const end = Date.now() + timeout;
  let body = '';
  while (Date.now() < end) {
    for (const f of t.page.frames()) {
      if (f === t.page.mainFrame()) continue;
      body = await f.locator('body').innerText().catch(() => '');
      if (body.includes(expected)) { await t.page.waitForTimeout(500); return body; }
    }
    await t.page.waitForTimeout(250);
  }
  fail(`the report frame never showed "${expected}"`);
  return body;
}

async function openTemplate() {
  await t.go(`${P}/reporter/templates`);
  await t.page.locator('a', { hasText: 'E2E to-do lists' }).first().click();
  await t.page.waitForLoadState('load');
  await t.settle();
  t.check('open the to-do list template');
  return t.page.url().replace(t.BASE, '');
}

// The todo plugin's route exists (an anonymous visitor is sent to the login page) or not (404).
await t.anonymous();
const probe = await t.page.request.get(`${t.BASE}${P}/issue_todo_lists`, { maxRedirects: 0 });
const installed = probe.status() !== 404;
console.log(`  redmine_issue_todo_lists2 ${installed ? 'installed' : 'not installed'}`);

await t.login('manager');
const showUrl = await openTemplate();
const managerBody = await frameText('E2E to-do lists');
if (installed) {
  if (!/E2E sprint \(position 1\)/.test(managerBody)) fail('manager: the seeded list and its position are not in the report');
  if (!/E2E sprint \(position 2\)/.test(managerBody)) fail('manager: the second listed issue is not in the report');
  await t.shot('manager', 'Manager (may view to-do lists): each issue shows the "E2E sprint" list with its position, and the count');
  await t.go(`${P}/issue_todo_lists`);
  await t.shot('manager-lists', 'Manager: the todo plugin\'s own list page, the same "E2E sprint" list');
} else {
  if (/position/.test(managerBody)) fail('without the todo plugin the report still shows a list');
  await t.shot('manager-without-plugin', 'Without redmine_issue_todo_lists2: the same template renders, every count 0, no error');
}

if (installed) {
  await t.login('listless');
  await t.go(showUrl);
  await t.settle();
  const listlessBody = await frameText('E2E to-do lists');
  if (/E2E sprint/.test(listlessBody)) fail('listless: a member without "View to-do lists" sees the list in the report');
  if (!/#\d+ /.test(listlessBody)) fail('listless: the report shows no issues at all, so the check above proves nothing');
  await t.shot('listless', 'Member without "View to-do lists": the same report, the same issues, no list and count 0');
  await t.go(`${P}/issue_todo_lists`, { status: 403 });
  await t.shot('listless-lists-refused', 'The same member: the todo plugin itself refuses its list page (403), consistent with the report');
}

await t.login('reporter');
await t.go(showUrl, { status: 403 });
await t.shot('reporter-refused', 'Reporter without the report permissions: the template is refused (403)');
await t.login('outsider');
await t.go(showUrl, { status: 403 });

await t.done();
