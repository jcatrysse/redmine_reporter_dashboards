// The base plugin's issue accessors, restored 2026-11-25 (Jan, option A), in a real report:
// GEOxyz's journal idioms (journals.all, | date, user.name, | textilize, last comment, | size),
// relations, and the redmine_tags / redmine_agile / redmine_checklists / helpdesk accessors.
//   manager    every permission: both notes (the private one too), the relation into the
//              private project, and the other plugins' data where installed
//   notesless  no private notes, checklists or helpdesk: the public note only, no relation into
//              the private project (not a member there), no checklist, no ticket
//   closed     (only with redmine_view_issue_description) may see the issue but not open it:
//              no description, no journals
//   reporter / outsider: the template itself is refused
import { e2e } from '../../.codex/e2e/lib.mjs';

const t = await e2e('base_accessors');
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

async function frameHtml() {
  for (const f of t.page.frames()) {
    if (f === t.page.mainFrame()) continue;
    const html = await f.content().catch(() => '');
    if (html.includes('E2E base accessors')) return html;
  }
  return '';
}

await t.login('manager');
await t.go(`${P}/reporter/templates`);
await t.page.locator('a', { hasText: 'E2E base accessors' }).first().click();
await t.page.waitForLoadState('load');
await t.settle();
t.check('open the base accessors template');
const showUrl = t.page.url().replace(t.BASE, '');

const manager = await frameText('Last comment');
if (!/A note from the manager\./.test(manager)) fail('manager: the public note is missing');
if (!/E2E private note, manager only/.test(manager)) fail('manager: the private note is missing');
if (!/blocks #\d+ E2E private issue/.test(manager)) fail('manager: the relation into the private project is missing');
if (!/relates #\d+ E2E related issue/.test(manager)) fail('manager: the relation inside the project is missing');
if (!/Journals \(2\)/.test(manager)) fail('manager: `issue.journals.all | size` is not 2');
if (!/Last comment: E2E private note/.test(manager)) fail('manager: the last-comment idiom did not find the newest note');
if (!/<strong>manager only<\/strong>/.test(await frameHtml())) fail('manager: | textilize did not render *bold*');
const tags = /Tags: \[e2e, customer\]|Tags: \[customer, e2e\]/.test(manager);
const agile = /Story points: \[3\] Colour: \[green\]/.test(manager);
const checklist = /E2E order parts done/.test(manager);
const helpdesk = /Helpdesk: \[client@e2e\.example\]/.test(manager);
console.log(`  with data: tags ${tags}, agile ${agile}, checklist ${checklist}, helpdesk ${helpdesk}`);
await t.shot('manager', 'Manager (every permission): both notes, the private one too; both relations; tags, story points, colour, checklist and helpdesk ticket where those plugins are installed');

await t.login('notesless');
await t.go(showUrl);
await t.settle();
const notesless = await frameText('Last comment');
if (!/A note from the manager\./.test(notesless)) fail('notesless: the public note is missing');
if (/E2E private note/.test(notesless)) fail('notesless: a private note reached a member without "View private notes"');
if (/E2E private issue/.test(notesless)) fail('notesless: a relation to an issue they cannot see is shown');
if (!/relates #\d+ E2E related issue/.test(notesless)) fail('notesless: the visible relation is missing, so the check above proves nothing');
if (/E2E order parts/.test(notesless)) fail('notesless: the checklist reached a member without "View checklists"');
if (/client@e2e\.example/.test(notesless)) fail('notesless: the helpdesk ticket reached a member without "View helpdesk tickets"');
if (!/Journals \(1\)/.test(notesless)) fail('notesless: `issue.journals.all | size` is not 1');
await t.shot('notesless', 'Member without "View private notes", checklists or helpdesk: the public note only, no relation into the private project, no checklist, no ticket');

// redmine_view_issue_description: the "closed" user exists only when that plugin is installed.
if (await t.login('closed').then(() => true, () => false)) {
  await t.go(showUrl);
  await t.settle();
  const closed = await frameText('Last comment');
  if (!/Description: 0 characters/.test(closed)) fail('closed: a description reached a member who may not open the issue');
  if (!/Journals \(0\)/.test(closed)) fail('closed: journals reached a member who may not open the issue');
  if (/A note from the manager/.test(closed)) fail('closed: a note reached a member who may not open the issue');
  await t.shot('closed', 'Member who may see but not open the issue (redmine_view_issue_description): no description and no journals');
}

await t.login('reporter');
await t.go(showUrl, { status: 403 });
await t.shot('reporter-refused', 'Reporter without the report permissions: the template is refused (403)');
await t.login('outsider');
await t.go(showUrl, { status: 403 });

await t.done();
