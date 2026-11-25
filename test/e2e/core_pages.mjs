// Jan's decision 2026-10-07: with the other GEOxyz plugins installed, Project > Settings,
// the issue list and an issue page must answer 200. This plugin adds a tab to Project >
// Settings (through the controller helper chain, not ProjectsHelper), so the settings page is
// the one it can break. As admin, manager, reporter and outsider, with the refusals.
import { e2e } from '../../.codex/e2e/lib.mjs';

const t = await e2e('core_pages');
const P = '/projects/e2e-project';
const fail = (msg) => t.problems.push(msg);
const issueId = 1;

async function pages(user, { settings, settingsTab }) {
  await t.go(`${P}/settings`, { status: settings });
  if (settings === 200) {
    const tab = await t.page.locator('#content .tabs a', { hasText: 'Reports and dashboards' }).count();
    if (settingsTab && !tab) fail(`${user}: Project > Settings has no "Reports and dashboards" tab`);
    if (!settingsTab && tab) fail(`${user}: Project > Settings shows the "Reports and dashboards" tab without the permission`);
  }
  await t.shot(`${user}-settings`, `${user}: Project > Settings answers ${settings}${settings === 200 ? (settingsTab ? ', with this plugin\'s "Reports and dashboards" tab' : ', without this plugin\'s tab (no permission)') : ''}`);
  await t.go(`${P}/issues`);
  await t.shot(`${user}-issues`, `${user}: the issue list answers 200`);
  await t.go(`/issues/${issueId}`);
  await t.shot(`${user}-issue`, `${user}: an issue page answers 200`);
}

await t.login('admin');
await pages('admin', { settings: 200, settingsTab: true });
await t.go(`${P}/settings/reporter_dashboards`);
await t.shot('admin-settings-tab', 'admin: the "Reports and dashboards" settings tab itself renders');

await t.login('manager');
await pages('manager', { settings: 200, settingsTab: true });

// Reporter: core Reporter role, no project-settings permission and none of this plugin's.
await t.login('reporter');
await pages('reporter', { settings: 403, settingsTab: false });

// Outsider: no membership; the public project is readable, the private one is not.
await t.login('outsider');
await t.go(`${P}/settings`, { status: 403 });
await t.shot('outsider-settings', 'outsider: Project > Settings of the public project is refused (403)');
await t.go(`${P}/issues`);
await t.shot('outsider-issues', 'outsider: the public project\'s issue list answers 200');
await t.go('/projects/e2e-private/issues', { status: 403 });
await t.shot('outsider-private-issues', 'outsider: the private project\'s issue list is refused (403)');

await t.done();
