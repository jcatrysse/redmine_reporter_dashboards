// UX review 2026-11: captures every before/after screenshot in ../img from a running
// Redmine (./.codex/start_server.sh, then mockup/seed.rb). "Before" is the real page;
// "after" is the same real page with ux.css + ux.js injected (and, inside report widget
// frames, report-frame.css + report-frame.js). Nothing is written to Redmine.
//
//   node docs/ux-review-2026-11/mockup/capture.mjs            # all shots
//   node docs/ux-review-2026-11/mockup/capture.mjs 03 04      # shots whose name starts so
//   python3 docs/ux-review-2026-11/mockup/compress.py          # quantise + composites
import { createRequire } from 'node:module';
import { execSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

function loadPlaywright() {
  const roots = [process.cwd() + '/', '/opt/node-tools/node_modules/', '/usr/local/lib/node_modules/', '/usr/lib/node_modules/'];
  try { roots.push(execSync('npm root -g', { stdio: ['ignore', 'pipe', 'ignore'] }).toString().trim() + '/'); } catch { /* no npm */ }
  for (const r of roots) { try { return createRequire(r)('playwright'); } catch { /* next */ } }
  throw new Error('Playwright not found');
}

const HERE = path.dirname(fileURLToPath(import.meta.url));
const OUT = path.join(HERE, '..', 'img');
const BASE = process.env.RMP_URL || 'http://127.0.0.1:3000';
const PASSWORD = process.env.RMP_USER_PASSWORD || process.env.RMP_ADMIN_PASSWORD || 'Redmine7Test!';
const PROJECT = 'e2e-project';
const P = `/projects/${PROJECT}`;
const only = process.argv.slice(2);
const read = (f) => fs.readFileSync(path.join(HERE, f), 'utf8');
const UX_CSS = read('ux.css');
const UX_JS = read('ux.js');
const FRAME_CSS = read('report-frame.css');
const FRAME_JS = read('report-frame.js');
// Technical notes a report prints for its author (hidden from readers in the mockup).
const TECH = ['^Counted in SQL', '^Versions with no issues in this report', 'rollup groups the report', 'Hours are summed in SQL', 'the time entries this report', 'Counted over'];

fs.mkdirSync(OUT, { recursive: true });
const { chromium } = loadPlaywright();
const browser = await chromium.launch();
let context, page;

// Noto Sans as data URLs, so the opaque-origin report frame can use Redmine's own font.
let fontFace = '';
async function loadFont() {
  for (const [file, weight, style] of [['NotoSans-Regular', 400, 'normal'], ['NotoSans-Bold', 700, 'normal'], ['NotoSans-Italic', 400, 'italic']]) {
    const css = await page.evaluate(() => Array.from(document.styleSheets).map((s) => s.href).filter(Boolean));
    const app = css.find((h) => /application/.test(h));
    const text = await (await page.request.get(app)).text();
    const m = text.match(new RegExp(`url\\(["']?([^)"']*${file}[^)"']*\\.woff2)`));
    if (!m) continue;
    const url = new URL(m[1], app).toString();
    const body = await (await page.request.get(url)).body();
    fontFace += `@font-face{font-family:"Noto Sans";font-weight:${weight};font-style:${style};src:url(data:font/woff2;base64,${body.toString('base64')}) format("woff2");}`;
  }
}

async function login(user) {
  if (context) await context.close();
  context = await browser.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2, bypassCSP: true, locale: 'en-GB', timezoneId: 'Europe/Brussels' });
  page = await context.newPage();
  await page.goto(`${BASE}/login`);
  await page.fill('#username', user);
  await page.fill('#password', PASSWORD);
  await Promise.all([page.waitForNavigation(), page.click('#login-submit')]);
  if (!fontFace) await loadFont();
}

async function reportFrames() { return page.frames().filter((f) => f !== page.mainFrame()); }

async function go(url) {
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto(BASE + url);
  await page.waitForLoadState('load');
  // Give every report frame the full page height so off-screen frames paint, then wait
  // for Chart.js to finish.
  const h = await page.evaluate(() => document.documentElement.scrollHeight);
  await page.setViewportSize({ width: 1440, height: Math.min(Math.max(h, 900), 12000) });
  await page.waitForTimeout(2500);
}

async function inject() {
  await page.addStyleTag({ content: UX_CSS });
  await page.addScriptTag({ content: UX_JS });
}

// Applies the widget proposal inside each report frame; returns hidden notes per box.
async function frames() {
  const notes = {};
  for (const f of await reportFrames()) {
    const handle = await f.frameElement().catch(() => null);
    if (!handle) continue;
    const info = await handle.evaluate((e) => {
      const box = e.closest('.mypage-box');
      const row = e.closest('.reporter-row');
      return { box: box ? box.id : null, perRow: row ? row.querySelectorAll(':scope > .mypage-box').length : 1 };
    });
    const chartHeight = { 1: 300, 2: 260, 3: 220 }[info.perRow] || 260;
    await f.addStyleTag({ content: fontFace + FRAME_CSS });
    const hidden = await f.evaluate(`(${FRAME_JS})(${JSON.stringify({ chartHeight, techPatterns: TECH })})`);
    if (info.box) notes[info.box] = hidden;
  }
  await page.waitForTimeout(800);
  // The frame reports its own height through postMessage; set it here as well so the
  // capture does not depend on that timing.
  for (const f of await reportFrames()) {
    const handle = await f.frameElement().catch(() => null);
    if (!handle) continue;
    const h = await f.evaluate(() => Math.ceil(document.documentElement.getBoundingClientRect().height));
    await handle.evaluate((e, hh) => { e.style.height = `${hh + 4}px`; e.style.minHeight = '0'; }, h);
  }
  return notes;
}

async function shot(name, { full = true, clip, element } = {}) {
  const file = path.join(OUT, `${name}.png`);
  if (element) {
    const loc = page.locator(element).first();
    await loc.scrollIntoViewIfNeeded();
    await page.waitForTimeout(300);
    await loc.screenshot({ path: file });
  } else if (clip) {
    await page.screenshot({ path: file, clip });
  } else {
    await page.setViewportSize({ width: 1440, height: 900 });
    await page.waitForTimeout(200);
    const h = await page.evaluate(() => document.documentElement.scrollHeight);
    await page.setViewportSize({ width: 1440, height: full ? Math.max(h, 600) : 900 });
    await page.waitForTimeout(400);
    await page.screenshot({ path: file, fullPage: full });
  }
  console.log('  ', path.relative(process.cwd(), file));
}

async function dashTabs() {
  return page.evaluate(() => Array.from(document.querySelectorAll('#content .tabs a[id^="reporter-tab-"]'))
    .filter((a) => a.id !== 'reporter-tab-add').map((a) => ({ title: a.textContent.trim(), href: a.getAttribute('href') })));
}
async function tabUrl(title) {
  await go(`${P}/reporter`);
  return page.evaluate((t) => { const a = Array.from(document.querySelectorAll('#content .tabs a')).find((x) => x.textContent.trim() === t); return a && a.getAttribute('href'); }, title);
}
const want = (prefix) => !only.length || only.some((o) => prefix.startsWith(o));

const MANAGER_TABS = ['templates', 'schedules', 'mail'];
const VIEWER_TABS = ['templates', 'schedules'];

async function navAfter(current, { variant = 'one-row', manage = MANAGER_TABS, menuLabel, keepTitle = false } = {}) {
  await inject();
  const tabs = await dashTabsCache();
  await page.evaluate((o) => window.UX.nav(o), { project: PROJECT, current, variant, dashTabs: tabs, manage, menuLabel, keepTitle });
}
let cachedTabs = null;
async function dashTabsCache() { return cachedTabs; }

// --------------------------------------------------------------------------------------
await login('manager');
await go(`${P}/reporter`);
cachedTabs = await dashTabs();
const chartsUrl = await tabUrl('Charts');
const versionsUrl = await tabUrl('Versions');

if (want('01')) {
  console.log('01 navigation');
  await go(`${P}/settings/reporter_dashboards`); await shot('01-nav-before-settings', { full: false });
  await go(`${P}/reporter/templates`); await shot('01-nav-before-templates', { full: false });
  await go(`${P}/reporter/schedules`); await shot('01-nav-before-schedules', { full: false });

  await go(`${P}/reporter`); await navAfter('dashboard'); await shot('01-nav-after-dashboard', { full: false });
  await go(`${P}/reporter/templates`); await navAfter('templates'); await shot('01-nav-after-templates', { full: false });
  await go(`${P}/reporter/schedules`); await navAfter('schedules');
  await page.evaluate(() => window.UX.schedules({ admin: false })); await shot('01-nav-after-schedules', { full: false });
  await go(`${P}/reporter/mail`); await navAfter('mail');
  await page.evaluate(() => window.UX.sentReports()); await shot('01-nav-after-sent', { full: false });
  await go(`${P}/settings`); await inject(); await page.evaluate(() => window.UX.settingsWithoutTab());
  await shot('01-nav-after-settings', { full: false });

  await go(`${P}/reporter`); await navAfter('dashboard', { variant: 'two-level' }); await shot('01-nav-variant-two-level-dashboard', { full: false });
  await go(`${P}/reporter/templates`); await navAfter('templates', { variant: 'two-level' }); await shot('01-nav-variant-two-level-templates', { full: false });

  const header = { x: 0, y: 0, width: 1440, height: 180 };
  await go(`${P}/reporter`); await shot('01-menu-label-before', { clip: header });
  await inject(); await page.evaluate(() => window.UX.menuLabel('Reports')); await shot('01-menu-label-after', { clip: header });
}

if (want('02')) {
  console.log('02 yellow boxes');
  await go(`${P}/reporter/mail`); await shot('02-yellow-before-sent', { full: false });
  await inject(); await page.evaluate(() => window.UX.sentReports()); await shot('02-yellow-after-sent', { full: false });
  await go(`${P}/reporter/schedules`); await shot('02-yellow-before-schedules', { full: false });
  await inject(); await page.evaluate(() => window.UX.schedules({ admin: false })); await shot('02-yellow-after-schedules', { full: false });
}

if (want('03')) {
  console.log('03 dashboard widgets');
  for (const [key, url] of [['overview', `${P}/reporter`], ['charts', chartsUrl], ['versions', versionsUrl]]) {
    await go(url); await shot(`03-widgets-before-${key}`);
    if (key === 'overview') {
      await shot('03-widget-before-report', { element: '#reporter-block-report_by_issues' });
      await shot('03-widget-before-unconfigured', { element: '#reporter-block-report_by_issues__1' });
    }
    if (key === 'charts') await shot('03-widget-before-chart', { element: '#reporter-block-report_by_issues' });
    if (key === 'charts') await shot('03-widget-before-degraded', { element: '#reporter-block-report_by_spent_time' });
    await go(url);
    await navAfter('dashboard');
    const notes = await frames();
    await page.evaluate((n) => window.UX.widgets({ editor: true, notes: n }), notes);
    await page.waitForTimeout(500);
    await shot(`03-widgets-after-${key}`);
    if (key === 'overview') {
      await page.hover('#reporter-block-report_by_issues h3');
      await shot('03-widget-after-report', { element: '#reporter-block-report_by_issues' });
      await shot('03-widget-after-unconfigured', { element: '#reporter-block-report_by_issues__1' });
    }
    if (key === 'charts') await shot('03-widget-after-chart', { element: '#reporter-block-report_by_issues' });
    if (key === 'charts') await shot('03-widget-after-degraded', { element: '#reporter-block-report_by_spent_time' });
  }
  await go('/my/page'); await shot('03-core-my-page', { full: false });
}

if (want('04')) {
  console.log('04 template pages');
  await go(`${P}/reporter/templates/new`); await shot('04-template-new-before');
  await go(`${P}/reporter/templates/new`); await navAfter('templates', { keepTitle: true });
  await page.evaluate(() => window.UX.templateNew()); await shot('04-template-new-after');
  const summary = await page.evaluate(() => null);
  await go(`${P}/reporter/templates`);
  const showUrl = await page.evaluate(() => { const a = Array.from(document.querySelectorAll('table.list a')).find((x) => x.textContent.trim() === 'Open work summary'); return a && a.getAttribute('href'); });
  await go(showUrl); await shot('04-template-show-before');
  await go(showUrl); await navAfter('templates', { keepTitle: true }); await frames();
  await page.evaluate(() => window.UX.templateShow()); await shot('04-template-show-after');
  void summary;
}

if (want('05') || want('06') || want('01-nav-admin') || want('02')) {
  await login('admin');
  if (want('02')) {
    await go(`${P}/reporter/schedules`); await inject(); await page.evaluate(() => window.UX.schedules({ admin: true }));
    await shot('02-yellow-after-schedules-admin', { full: false });
  }
  if (want('05')) {
    console.log('05 plugin settings');
    await go('/settings/plugin/redmine_reporter_dashboards'); await shot('05-plugin-settings-before');
    await inject(); await page.evaluate(() => window.UX.pluginSettings()); await shot('05-plugin-settings-after');
  }
  if (want('06')) {
    console.log('06 role permissions');
    await go('/roles');
    const roleUrl = await page.evaluate(() => { const a = Array.from(document.querySelectorAll('table.list a')).find((x) => x.textContent.trim() === 'E2E full'); return a && a.getAttribute('href'); });
    await go(roleUrl);
    const fs1 = 'fieldset:has(legend:text-is("Reports")), fieldset:has(legend :text-is("Reports"))';
    await shot('06-permissions-before', { element: fs1 });
    await inject(); await page.evaluate(() => window.UX.rolePermissions());
    await shot('06-permissions-after', { element: fs1 });
  }
}

if (want('07')) {
  console.log('07 reader without edit rights');
  await login('viewer');
  await go(`${P}/reporter`); await shot('07-viewer-before-overview');
  await go(`${P}/reporter`); await navAfter('dashboard', { manage: VIEWER_TABS });
  const notes = await frames();
  await page.evaluate((n) => window.UX.widgets({ editor: false, notes: n }), notes);
  await page.waitForTimeout(500);
  await shot('07-viewer-after-overview');
  await go(chartsUrl); await shot('07-viewer-before-charts');
  await shot('07-viewer-before-time-widget', { element: '#reporter-block-report_by_spent_time' });
  await go(chartsUrl); await navAfter('dashboard', { manage: VIEWER_TABS });
  const notes2 = await frames();
  await page.evaluate((n) => window.UX.widgets({ editor: false, notes: n }), notes2);
  await shot('07-viewer-after-charts');
  await shot('07-viewer-after-time-widget', { element: '#reporter-block-report_by_spent_time' });
  await go(`${P}/reporter/templates`); await shot('07-viewer-before-templates', { full: false });
  const viewerShow = await page.evaluate(() => { const a = Array.from(document.querySelectorAll('table.list a')).find((x) => x.textContent.trim() === 'Open work summary'); return a && a.getAttribute('href'); });
  await go(viewerShow); await shot('07-viewer-before-template-show', { full: false });
  await go(viewerShow); await navAfter('templates', { manage: VIEWER_TABS, keepTitle: true }); await frames();
  await page.evaluate(() => window.UX.templateShow()); await shot('07-viewer-after-template-show', { full: false });
}

await browser.close();
