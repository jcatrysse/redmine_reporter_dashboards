// The plugin's rake tasks, run against the same database the e2e server uses (functions
// without a page). Each command and its result go into docs/e2e/rake_tasks.md; the
// scheduler run is checked by the mail it writes and the run row it leaves in the browser.
import { e2e } from '../../.codex/e2e/lib.mjs';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const t = await e2e('rake_tasks');
const fail = (msg) => t.problems.push(msg);
const REDMINE = process.env.REDMINE_DIR || 'redmine';
const ENVNAME = process.env.RMP_SERVER_ENV || 'production';
const OUT = process.env.RMP_E2E_OUT || 'docs/e2e';
const bundleFile = path.join(REDMINE, 'tmp', 'e2e-bundle.json');
const log = [];

function rake(task, env = {}, expectStatus = 0) {
  const r = spawnSync('bundle', ['exec', 'rake', task], {
    cwd: REDMINE, encoding: 'utf8', timeout: 300000,
    env: { ...process.env, RAILS_ENV: ENVNAME, LANG: 'C.UTF-8', ...env },
  });
  const output = `${r.stdout || ''}${r.stderr || ''}`.split('\n')
    .filter(l => !/DEPRECATION|^\s*$/.test(l)).slice(0, 25).join('\n');
  const envText = Object.entries(env).map(([k, v]) => `${k}=${v} `).join('');
  log.push(`### \`${envText}rake ${task}\`\n\nexit ${r.status}\n\n\`\`\`\n${output}\n\`\`\`\n`);
  if (r.status !== expectStatus) fail(`rake ${task}: exit ${r.status}, expected ${expectStatus}`);
  return output;
}

rake('reporter_dashboards:migrate_from_reporter:plan');
rake('reporter_dashboards:lint_templates');
rake('reporter_dashboards:lint_templates', { RRD_PROJECT: 'e2e-project' });
rake('reporter_dashboards:export:bundle', { RRD_PROJECT: 'e2e-project', RRD_OUT: bundleFile });
if (!fs.existsSync(bundleFile) || !fs.readFileSync(bundleFile, 'utf8').includes('E2E issue report')) fail('export:bundle wrote no bundle with the seeded templates');
rake('reporter_dashboards:import:plan', { RRD_FILE: bundleFile, RRD_PROJECT: 'e2e-private' });
rake('reporter_dashboards:import:plan', { RRD_FILE: '/nonexistent.json', RRD_PROJECT: 'e2e-private' }, 2);
rake('reporter_dashboards:import:run', { RRD_FILE: bundleFile, RRD_PROJECT: 'e2e-private', RRD_ON_CONFLICT: 'rename', RRD_ACTOR: 'admin' });
rake('reporter_dashboards:schedules:status');
const since = Date.now();
rake('reporter_dashboards:schedules:run');
const mails = t.mails(since).filter(m => m.body.includes('E2E daily issue report'));
if (!mails.length) fail('schedules:run delivered no "E2E daily issue report" mail');
else log.push(`schedules:run wrote ${mails.length} mail(s): ${mails.map(m => m.to).join(', ')}; PDF attached: ${mails.every(m => /application\/pdf/.test(m.body))}\n`);
rake('reporter_dashboards:schedules:run'); // second run the same day: nothing due, still exit 0
rake('reporter_dashboards:schedules:status');
rake('reporter_dashboards:documents:purge', { RRD_DRY_RUN: '1' });
rake('reporter_dashboards:render:preflight', { RRD_ENGINE: 'chromium_cdp' });

fs.writeFileSync(path.join(OUT, 'rake_tasks-commands.md'), `# Rake tasks against the e2e database (${ENVNAME})\n\n${log.join('\n')}`);

// The run is visible in the browser too.
await t.login('manager');
await t.go('/projects/e2e-project/reporter/schedules');
await t.page.locator('a', { hasText: 'E2E daily issue report' }).first().click();
await t.page.waitForLoadState('load');
await t.settle();
await t.shot('schedule-after-run', 'The schedule after `rake reporter_dashboards:schedules:run`: the run is recorded as delivered, the next run moved on');

await t.done();
