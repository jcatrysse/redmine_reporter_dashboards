// Delivery: ad hoc mail of a report, the mail log, report schedules (list, new, create,
// show, edit, test send, delete); empty input and refusals. Mail goes to redmine/tmp/mails.
import { e2e } from '../../.codex/e2e/lib.mjs';

const t = await e2e('delivery');
const P = '/projects/e2e-project';
const fail = (msg) => t.problems.push(msg);
const text = async () => (await t.page.locator('#content').innerText()).replace(/\s+/g, ' ');

await t.login('manager');
await t.go(`${P}/reporter/templates`);
await t.page.locator('a', { hasText: 'E2E issue report' }).first().click();
await t.page.waitForLoadState('load');
const tplId = t.page.url().match(/templates\/(\d+)/)[1];

// --- ad hoc mail --------------------------------------------------------------------
await t.go(`${P}/reporter/mail/new?template_id=${tplId}`);
await t.shot('mail-new', 'The "send report by e-mail" form: recipients from the project, issues, subject');

// No recipient: refused with a message, nothing sent.
let since = Date.now();
await t.page.locator('#content input[type=submit]').first().click();
await t.page.waitForLoadState('load');
await t.settle();
t.check('mail without recipient', { requests: ['422'] });
if (t.mails(since).length) fail('a mail was written although no recipient was chosen');
await t.shot('mail-no-recipient', 'Sending without a recipient: an error, and no mail is written');

await t.go(`${P}/reporter/mail/new?template_id=${tplId}`);
await t.page.selectOption('#recipient_user_ids', { label: 'Manager E2E' });
await t.page.fill('#subject', 'E2E ad hoc report');
since = Date.now();
await t.page.locator('#content input[type=submit]').first().click();
await t.page.waitForLoadState('load');
await t.settle();
t.check('mail send');
await t.page.waitForTimeout(2000);
const mails = t.mails(since);
const adhoc = mails.find(m => m.body.includes('E2E ad hoc report'));
if (!adhoc) fail(`no ad hoc mail written (${mails.length} mail file(s) since send)`);
else {
  console.log(`  ad hoc mail: ${adhoc.to}, ${adhoc.body.length} bytes, PDF attached: ${/application\/pdf/.test(adhoc.body)}`);
  if (!/application\/pdf/.test(adhoc.body)) fail('the ad hoc mail has no PDF attachment');
}
await t.shot('mail-sent', 'After sending: the mail log lists the send with its recipients and status');
await t.go(`${P}/reporter/mail`);
await t.shot('mail-log', 'The mail log of the project');

// --- schedules ----------------------------------------------------------------------
await t.go(`${P}/reporter/schedules`);
if (!(await text()).includes('E2E daily issue report')) fail('seeded schedule missing from the list');
await t.shot('schedules-index', 'Report schedules of the project: the seeded daily schedule with its next run');

await t.go(`${P}/reporter/schedules/new`);
await t.shot('schedule-new', 'New schedule form: template, query, repeat, dates, subject, render-as, recipients');
await t.page.selectOption('select[name="schedule[template_id]"]', { label: 'E2E time report' });
await t.page.selectOption('select[name="schedule[repeat]"]', 'weekly').catch(() => fail('no weekly repeat'));
await t.page.fill('input[name="schedule[email_subject]"]', 'E2E weekly time report');
await t.page.selectOption('select[name="schedule[recipient_user_ids][]"]', { label: 'Manager E2E' });
await t.page.locator('#content input[type=submit]').first().click();
await t.page.waitForLoadState('load');
await t.settle();
t.check('schedule create');
if (!/schedules\/\d+/.test(t.page.url()) && !(await text()).includes('E2E weekly time report')) fail('schedule was not created');
await t.shot('schedule-created', 'The new weekly schedule is saved');

// Invalid: end date before start date.
await t.go(`${P}/reporter/schedules/new`);
await t.page.fill('input[name="schedule[email_subject]"]', 'E2E invalid dates');
await t.page.fill('input[name="schedule[start_date]"]', '2026-12-31');
await t.page.fill('input[name="schedule[end_date]"]', '2026-01-01');
await t.page.locator('#content input[type=submit]').first().click();
await t.page.waitForLoadState('load');
await t.settle();
t.check('schedule invalid', { requests: ['422'] });
if (!(await t.page.locator('#errorExplanation, .flash.error').count())) fail('an end date before the start date was accepted silently');
await t.shot('schedule-invalid', 'End date before start date: rejected with an error message');

// Test send of the seeded schedule.
await t.go(`${P}/reporter/schedules`);
await t.page.locator('a', { hasText: 'E2E daily issue report' }).first().click();
await t.page.waitForLoadState('load');
await t.settle();
await t.shot('schedule-show', 'The seeded schedule: settings, recipients, run history');
const testSend = t.page.locator('form[action$="test_send"] input[type=submit], a[href$="test_send"]').first();
if (await testSend.count()) {
  since = Date.now();
  await testSend.click();
  await t.page.waitForLoadState('load');
  await t.settle();
  t.check('test send');
  await t.page.waitForTimeout(2000);
  const sent = t.mails(since);
  if (!sent.length) fail('test send wrote no mail');
  else console.log(`  test send: ${sent.length} mail(s), first to ${sent[0].to}`);
  await t.shot('schedule-test-sent', 'After "Send a test": the flash confirms and a mail is written to the sender');
} else fail('no "Send a test" control on the schedule');

// Edit then delete the weekly schedule.
await t.go(`${P}/reporter/schedules`);
const weekly = t.page.locator('tr', { hasText: 'E2E weekly time report' });
const editLink = weekly.locator('a[href$="/edit"]').first();
if (await editLink.count()) {
  await editLink.click();
  await t.page.waitForLoadState('load');
  await t.page.fill('input[name="schedule[email_subject]"]', 'E2E weekly time report (edited)');
  await t.page.locator('#content input[type=submit]').first().click();
  await t.page.waitForLoadState('load');
  await t.settle();
  t.check('schedule update');
}
await t.go(`${P}/reporter/schedules`);
if (!(await text()).includes('(edited)')) fail('schedule edit not stored');
const del = t.page.locator('tr', { hasText: '(edited)' }).locator('a[data-method=delete], a.icon-del').first();
t.page.once('dialog', d => d.accept());
await del.click();
await t.page.waitForLoadState('load');
await t.settle();
t.check('schedule delete');
if ((await text()).includes('(edited)')) fail('schedule delete left the row');
await t.shot('schedule-deleted', 'After deleting, only the seeded schedule remains');

// --- refusals ---------------------------------------------------------------------
await t.login('reporter');
await t.go(`${P}/reporter/schedules`, { status: 403 });
await t.go(`${P}/reporter/mail/new?template_id=${tplId}`, { status: 403 });
await t.shot('reporter-refused', 'Reporter: schedules and ad hoc mail are refused (403)');
await t.login('outsider');
await t.go('/projects/e2e-private/reporter/schedules', { status: 403 });
await t.shot('outsider-private', 'Outsider: schedules of the private project are refused (403)');

await t.done();
