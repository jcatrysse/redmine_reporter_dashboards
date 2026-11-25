// My page: the "Issue report" and "Spent time report" blocks this plugin contributes,
// configured with a project and a template; a user without the permission sees no data.
import { e2e } from '../../.codex/e2e/lib.mjs';

const t = await e2e('my_page');
const fail = (msg) => t.problems.push(msg);

async function addBlock(value) {
  await t.go('/my/page');
  const sel = t.page.locator('#block-select');
  if (!(await sel.locator(`option[value="${value}"]`).count())) { fail(`my page offers no "${value}" block`); return false; }
  await sel.selectOption(value);
  await t.page.waitForTimeout(1500);
  await t.settle();
  t.check(`add my block ${value}`);
  return true;
}

async function configure(block, template) {
  const form = t.page.locator(`#block-${block}`);
  const project = form.locator(`select[name="settings[${block}][project_id]"]`);
  if (await project.count()) await project.selectOption({ label: 'E2E project' }).catch(() => fail(`${block}: E2E project not offered`));
  const tpl = form.locator(`select[name="settings[${block}][report_template_id]"]`);
  if (!(await tpl.count())) { fail(`${block}: no template select`); return; }
  await tpl.selectOption({ label: template }).catch(() => fail(`${block}: template "${template}" not offered`));
  await form.locator('input[type=submit]').first().click();
  await t.page.waitForTimeout(2000);
  await t.go('/my/page');
}

await t.login('manager');
if (await addBlock('report_by_issues')) {
  await t.shot('issue-block-settings', 'My page, block "Issue report" added: it asks for a project and a template');
  await configure('report_by_issues', 'E2E issue report');
  await t.page.waitForTimeout(2500);
  await t.shot('issue-block', 'The "Issue report" block renders the chosen report for the chosen project');
}
if (await addBlock('report_by_spent_time')) {
  await configure('report_by_spent_time', 'E2E time report');
  await t.page.waitForTimeout(2000);
  await t.shot('time-block', 'The "Spent time report" block renders the hours per activity');
}

// Reporter: the block can be added, but no project with the permission is offered.
await t.login('reporter');
if (await addBlock('report_by_issues')) {
  const opts = await t.page.locator('select[name="settings[report_by_issues][project_id]"] option').allInnerTexts().catch(() => []);
  if (opts.some(o => o.includes('E2E project'))) fail('reporter is offered E2E project without the report permission');
  await t.shot('reporter-block', 'Reporter adds the block: no project or template is offered, so nothing is rendered (fails closed)');
}

await t.done();
