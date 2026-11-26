// UX review 2026-11, mockup only: NOT plugin code. capture.mjs injects this into the real
// Redmine pages (after ux.css) and calls window.UX.<step>(options). Every step only
// restyles, moves or rewrites DOM that the real page already rendered, using Redmine's own
// markup idioms (core .tabs, .contextual, em.info, p.nodata, .box.tabular, table.list,
// .mypage-box), so that what the "after" screenshots show is buildable with core markup.
(() => {
  const $ = (s, root = document) => root.querySelector(s);
  const $$ = (s, root = document) => Array.from(root.querySelectorAll(s));
  const el = (html) => { const t = document.createElement('template'); t.innerHTML = html.trim(); return t.content.firstChild; };
  const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const spritePath = () => { const u = $('use[href*="icons"]'); return u ? u.getAttribute('href').split('#')[0] : '/assets/icons.svg'; };
  const svg = (name) => `<svg class="s18 icon-svg" aria-hidden="true"><use href="${spritePath()}#icon--${name}"></use></svg>`;
  const iconOnly = (name, label, attrs = '') => `<a class="icon-only icon-${name}" title="${esc(label)}" ${attrs}>${svg(name)}<span class="icon-label">${esc(label)}</span></a>`;
  const iconLink = (name, label, href) => `<a class="icon icon-${name}" href="${href}">${svg(name)}<span class="icon-label">${esc(label)}</span></a>`;
  const textMatches = (re) => $$('#content *').filter((n) => n.children.length === 0 && re.test(n.textContent));

  // ---------------------------------------------------------------- 1. navigation
  // o = { project, current: 'dashboard'|'templates'|'schedules'|'mail', variant: 'one-row'|'two-level',
  //       dashTabs: [{title, href, selected}], manage: ['templates','schedules','mail'], menuLabel }
  function nav(o) {
    const P = `/projects/${o.project}/reporter`;
    const manageTabs = [
      { key: 'templates', title: 'Templates', href: `${P}/templates` },
      { key: 'schedules', title: 'Schedules', href: `${P}/schedules` },
      { key: 'mail', title: 'Sent reports', href: `${P}/mail` },
    ].filter((t) => o.manage.includes(t.key));

    // The project menu item stays selected on every subpage.
    $$('#main-menu a.selected').forEach((a) => a.classList.remove('selected'));
    const item = $('#main-menu a.reporter-project-page');
    if (item) { item.classList.add('selected'); if (o.menuLabel) item.textContent = o.menuLabel; }

    const content = $('#content');
    let tabs = $('#content > .tabs');
    const li = (t, selected, extra = '') => `<li${extra}><a href="${t.href}"${selected ? ' class="selected"' : ''}>${esc(t.title)}</a></li>`;

    if (o.variant === 'two-level') {
      const top = el(`<div class="tabs ux-feature-tabs"><ul>${
        li({ title: 'Dashboard', href: P }, o.current === 'dashboard')}${
        manageTabs.map((t) => li(t, o.current === t.key)).join('')}</ul></div>`);
      if (o.current === 'dashboard' && tabs) {
        tabs.classList.add('ux-subtabs');
        tabs.parentNode.insertBefore(top, tabs);
        // "Add:" and the gear belong to the dashboard, so they sit on its own tab row.
        const ctx = $('#content > .contextual');
        if (ctx) tabs.parentNode.insertBefore(ctx, tabs);
      } else {
        content.insertBefore(top, $('#content > h2') ? $('#content > h2').nextSibling : content.firstChild);
      }
      $$('#content > h2').forEach((h) => h.remove());
      return;
    }

    // one-row (recommended): the dashboard's pages, then the management tabs at the end of
    // the same core tab bar.
    const right = manageTabs.map((t, i) => li(t, o.current === t.key, i === 0 ? ' class="ux-tabs-right"' : '')).join('');
    if (o.current === 'dashboard' && tabs) {
      $('ul', tabs).insertAdjacentHTML('beforeend', right);
      // The dashboard's own controls ("Add:" and the gear) leave the tab row so they never
      // crowd the management tabs: a .contextual line of their own, right-aligned, under it.
      const ctx = $('#content > .contextual');
      if (ctx) { ctx.classList.add('ux-dash-controls'); tabs.insertAdjacentElement('afterend', ctx); }
    } else {
      const pages = o.dashTabs.map((t) => li(t, false)).join('');
      tabs = el(`<div class="tabs"><ul>${pages}${right}</ul></div>`);
      const h2 = $('#content > h2');
      content.insertBefore(tabs, h2 ? h2.nextSibling : content.firstChild);
      // On a list page the selected tab names the page; the h2 would say it twice. A
      // subpage (new, show, edit) keeps its own h2, below the tabs.
      if (h2 && !o.keepTitle) h2.remove();
      if (h2 && o.keepTitle) tabs.insertAdjacentElement('afterend', h2);
    }
  }

  function menuLabel(label) {
    const item = $('#main-menu a.reporter-project-page');
    if (item) item.textContent = label;
  }

  // Settings: the "Reports and dashboards" tab is gone (it held only counts and links).
  function settingsWithoutTab() {
    const a = $('#tab-reporter_dashboards');
    if (a) a.closest('li').remove();
    const panel = $('#tab-content-reporter_dashboards');
    if (panel) panel.remove();
    const first = $('#content .tabs a');
    if (first && !$('#content .tabs a.selected')) first.click();
  }

  // ---------------------------------------------------------------- 2. yellow boxes
  // The scope line differs by actor today (admin: every report; others: their own), and the
  // controller filters accordingly, so both variants stay; only the yellow goes.
  function sentReports() {
    textMatches(/mailed from this project/).forEach((n) => {
      const box = n.closest('.nodata, .warning, p') || n;
      box.replaceWith(el(`<p><em class="info">${esc(n.textContent.trim())}</em></p>`));
    });
    // Status as a word in its column; a failure reads as one, without colour noise.
    $$('table.list td').forEach((td) => {
      if (/^\s*failed\b/.test(td.textContent)) {
        const first = td.childNodes[0];
        if (first && first.nodeType === 3) first.textContent = 'Failed';
        td.classList.add('ux-failed');
      } else if (/^\s*success\s*$/.test(td.textContent)) td.textContent = 'Sent';
    });
    $$('table.list td').forEach((td) => { if (td.textContent.trim() === 'none') td.textContent = ''; });
  }

  function schedules(o) {
    const box = textMatches(/periodic task outside Redmine/)[0];
    const container = box && (box.closest('.warning, .nodata, .flash, div') || box);
    if (!container) return;
    // FR-44: the warning stays for everyone who can open the page (it answers "did it
    // run?"), as one line in the state's own words; the cron detail is for administrators.
    const headline = (container.querySelector('strong, b, h3, p') || container).textContent.trim() || 'No scheduled report has run yet';
    const tail = o.admin
      ? ` Check the scheduler in <a href="/admin/reporter_dashboards/preflight">Render preflight</a>.`
      : ' An administrator can check the scheduler.';
    container.replaceWith(el(`<p class="warning">${esc(headline.replace(/\.?$/, '.'))}${tail}</p>`));
  }

  // ---------------------------------------------------------------- 3. dashboard widgets
  // o = { editor, notes: { boxId: [text] } }
  const WIDGET_LABEL = { report_by_issues: 'Issue report', report_by_spent_time: 'Spent time report' };
  // The starters' scope lines in Redmine's own register (they are template text, so the
  // real change is in starters/*.liquid).
  function plainNote(text) {
    return text
      .replace(/^Counted in SQL over the issues this report's reader may see\.?/, 'Only issues you can see are counted.')
      .replace(/^Versions with no issues in this report do not appear.*$/, 'Versions without issues in this report are not listed.')
      .replace(/^Hours are summed in SQL.*$/, 'Only time entries you can see are counted.');
  }
  function widgets(o) {
    $$('#reporter-project-page .mypage-box').forEach((box) => {
      const base = box.id.replace(/^reporter-block-/, '').replace(/__\d+$/, '');
      const frame = $('iframe.reporter-report-frame', box);
      const settings = $('[id$="-settings"] .report-settings', box) && $('[id$="-settings"]', box);
      const h3 = $(':scope > h3', box);

      if (frame && h3) {
        // "Open work summary (E2E project | UX open issues ) (38)" ->
        // "Open work summary · UX open issues (38)": one title, the query as a link, no
        // project name (it is this project), no stray spaces.
        const name = (h3.childNodes[0].textContent || '').split('(')[0].trim();
        const query = $('a:not(.reporter-report-pdf)', h3);
        const count = (h3.textContent.match(/\((\d+)\)\s*$/m) || h3.textContent.match(/\((\d+)\)(?!.*\(\d+\))/s) || [])[1];
        const pdf = $('a.reporter-report-pdf', h3);
        h3.innerHTML = `${esc(name)}${query ? ` <span class="ux-widget-query">· <a href="${query.getAttribute('href')}">${esc(query.textContent.trim())}</a></span>` : ''}${count ? ` (${count})` : ''}`;
        // The PDF export stays visible in the heading: it is a reader's action, and core
        // hides .contextual until hover (application.css:2074), which suits only edit controls.
        if (pdf) { h3.appendChild(document.createTextNode(' ')); h3.appendChild(pdf); }

        const notes = (o.notes && o.notes[box.id]) || [];
        const deg = $('.reporter-degradations', box);
        const degText = deg ? $$('li', deg).map((li) => li.textContent.trim()
          .replace(/^(\w+) has too many values to show: (\d+) are listed and (\d+) were folded together\.?/,
            (m, what, shown, folded) => `${shown} ${what === 'issue' ? 'issues' : what} listed, ${folded} more under "(other)".`)) : [];
        if (deg) deg.remove();
        // Degradations and the report's own scope lines ("Counted in SQL over the issues
        // this report's reader may see.") are facts about the numbers and who they cover:
        // one quiet grey foot line under the report, for every reader.
        const foot = degText.concat(notes.map(plainNote));
        if (foot.length) frame.insertAdjacentElement('afterend', el(`<p class="ux-widget-foot"><em class="info">${esc(foot.join(' '))}</em></p>`));
      }

      if (settings) {
        // Unconfigured, editor: one grey line and a gear; the form opens on demand.
        settings.style.display = 'none';
        const ctx = $(':scope > .contextual', box) || box.insertBefore(el('<div class="contextual"></div>'), box.firstChild);
        ctx.insertAdjacentHTML('afterbegin', iconOnly('settings', 'Options', 'href="#"'));
        settings.insertAdjacentElement('beforebegin', el('<p><em class="info">Not set up yet. Choose a report template under <a href="#">Options</a>.</em></p>'));
        if (h3) h3.textContent = WIDGET_LABEL[base] || h3.textContent;
      } else if (!frame && WIDGET_LABEL[base]) {
        // Unconfigured, reader: today an untitled yellow "No data to display" box.
        const nodata = $('p.nodata', box);
        if (nodata && !h3) {
          box.insertBefore(el(`<h3>${WIDGET_LABEL[base]}</h3>`), nodata);
          nodata.replaceWith(el('<p><em class="info">Not set up yet.</em></p>'));
        }
      }
    });
  }

  // ---------------------------------------------------------------- 4. template pages
  function templateNew() {
    const gallery = $('#reporter-starter-gallery');
    if (gallery) {
      gallery.classList.add('ux-gallery');
      const info = $('em.info', gallery);
      if (info) info.textContent = 'Pick one to open it in the editor. Nothing is saved until you press Create.';
      $$('li.reporter-starter', gallery).forEach((li) => {
        const desc = $('.reporter-starter-description', li);
        if (desc) { desc.classList.add('info'); }
      });
    }
    // Large editor; the chart helper becomes a button above it.
    const ta = $('textarea[name*="[content]"]');
    if (ta) {
      ta.classList.add('ux-editor');
      const p = ta.closest('p') || ta.parentNode;
      const bar = el(`<div class="ux-editor-bar">${iconLink('stats', 'Insert a chart', '#reporter-chart-form')}</div>`);
      p.insertBefore(bar, ta);
    }
    const chart = $('#reporter-chart-form');
    if (chart) chart.style.display = 'none';
    lintClean();
    coreVisibility();
    // Reference: every group closed, so the sidebar is a short index rather than 60 lines.
    $$('details.reporter-drop-reference').forEach((d) => d.removeAttribute('open'));
    const refInfo = $('#sidebar em.info');
    if (refInfo) refInfo.textContent = 'Everything a template can print. Open a group to see its fields.';
    // Long help lines under the form fields: one short line each.
    const short = {
      'Data source': 'Issues use an issue query, spent time a time entry query.',
      Output: 'One PDF per issue, or one PDF for all.',
      'Margins (mm)': 'Top, right, bottom, left, for example 20,15,20,15.',
      'Produce a failure document': 'Offer a PDF saying the report could not be generated.',
    };
    $$('.tabular p').forEach((p) => {
      const label = $('label', p);
      if (!label) return;
      const key = Object.keys(short).find((k) => label.textContent.trim().startsWith(k));
      const info = $('em.info', p);
      if (key && info) info.textContent = short[key];
    });
    // INV-9 at the point of authoring: shorter, the statement itself kept.
    textMatches(/executed on the server/).forEach((n) => { n.textContent = 'Templates run on the server: whoever can edit one can run code as the application.'; });
  }

  // A clean lint result: one plain grey line (an absent panel cannot be told from one that
  // did not run, lint_panel_test.rb:267). The rake command goes: authors are not admins.
  function lintClean() {
    if (!$('#reporter-template-lint-clean')) return;
    $('#reporter-template-lint').replaceWith(el('<p id="reporter-template-lint"><em class="info">No linter findings.</em></p>'));
  }

  // "Visible" exactly as core's query form (app/views/queries/_form.html.erb:20-29 and
  // :118-121): private, public, then "to these roles only:" with the roles indented
  // (label.block.role-visibility) and enabled only while that option is chosen.
  function coreVisibility() {
    const radios = $$('input[type=radio][name="template[visibility]"]');
    if (!radios.length) return;
    const p = radios[0].closest('p');
    const labelOf = (v) => { const r = radios.find((x) => x.value === String(v)); return r && (r.closest('label') || r.parentNode); };
    const roles = $$('input[type=checkbox][name="template[role_ids][]"]');
    const roleLabels = roles.map((cb) => cb.closest('label') || cb.parentNode);
    const hidden = $('input[type=hidden][name="template[role_ids][]"]', p);
    [labelOf(0), labelOf(2), labelOf(1)].forEach((l) => { if (l) { l.classList.add('block'); p.appendChild(l); } });
    const rolesLabel = labelOf(1);
    if (rolesLabel && !/:\s*$/.test(rolesLabel.textContent)) {
      const last = Array.from(rolesLabel.childNodes).reverse().find((n) => n.nodeType === 3 && n.textContent.trim());
      if (last) last.textContent = last.textContent.replace(/\s+$/, '') + ':';
    }
    roleLabels.forEach((l) => { l.classList.add('block', 'role-visibility'); p.appendChild(l); });
    if (hidden) p.appendChild(hidden);
    $$('span', p).forEach((s) => { if (!s.textContent.trim()) s.remove(); });
    const sync = () => { const on = radios.find((x) => x.value === '1')?.checked; roles.forEach((cb) => { cb.disabled = !on; }); };
    radios.forEach((r) => r.addEventListener('change', sync));
    sync();
  }

  function templateShow() {
    lintClean();
    $$('#content > .box').forEach((b) => { if ($('iframe.reporter-report-frame', b)) b.classList.add('ux-report-box'); });
  }

  // ---------------------------------------------------------------- 5. plugin settings
  function pluginSettings() {
    const rewrite = [
      [/^Asset policy/, 'Where images, stylesheets, fonts and scripts in a report may come from. A report whose asset cannot be obtained is not produced.'],
      [/^Asset host allowlist/, 'One host name per line. Empty means bundled only.'],
      [/^Embed assets up to/, 'Larger assets are sent next to the document, on engines that support it.'],
      [/^Refuse assets above/, 'A report with a larger asset is not produced.'],
      [/^Render engine/, 'Draws the PDF for every report. A template can name its own engine.'],
      [/^Allow external e-mail/, 'Off: reports go to Redmine users only.'],
      [/^Permitted domains/, 'One domain per line.'],
      [/^Sends per user/, 'Maximum reports one user may send within the given minutes. 0 turns ad-hoc mail off.'],
    ];
    $$('.tabular p, .box p').forEach((p) => {
      const label = $('label', p);
      if (!label) return;
      const r = rewrite.find(([re]) => re.test(label.textContent.trim()));
      if (!r) return;
      const infos = Array.from(new Set($$('em.info', p)));
      if (infos.length) { infos[0].textContent = r[1]; infos.slice(1).forEach((i) => i.remove()); }
    });
    // Any loose help paragraph that is not a field's own line goes.
    textMatches(/What each engine needs, and what it cannot do/).forEach((n) => n.closest('p, em').remove());
    // The engine table: one short line per engine, symbols as words, details on the preflight.
    const table = $$('table').find((t) => /Render engine/.test(t.textContent) && /Needs a service/.test(t.textContent));
    if (table) {
      const short = {
        chromium_cdp: ['Headless Chromium', 'Default. Needs the chromium package on the server.'],
        gotenberg: ['Gotenberg', 'A separate service you run yourself.'],
        wkhtmltopdf: ['wkhtmltopdf (deprecated)', 'For old templates only.'],
      };
      const head = $('thead tr', table) || table.rows[0];
      head.innerHTML = '<th>Engine</th><th>Needs a service</th><th>Works offline</th><th>Not supported</th>';
      $$('tbody tr', table).forEach((tr) => {
        const key = Object.keys(short).find((k) => tr.textContent.includes(k));
        if (!key) return;
        const cells = Array.from(tr.cells).map((c) => c.textContent.trim());
        const missing = cells[cells.length - 1]
          .replace(/—/, '')
          .split(/,\s*/).filter(Boolean)
          .map((s) => ({ ':outline': 'outline', ':tagged_pdf': 'tagged PDF', ':modern_javascript': 'modern JavaScript', ':readiness_expression': 'readiness check', ':scale': 'scaling' }[s.trim()] || s.replace(/^:/, '').replace(/_/g, ' ')))
          .join(', ');
        tr.innerHTML = `<td class="name"><strong>${short[key][0]}</strong><em class="info">${short[key][1]}</em></td><td>${cells[1]}</td><td>${cells[2]}</td><td>${missing || ''}</td>`;
      });
      table.classList.add('ux-engines');
      table.insertAdjacentElement('afterend', el('<p><em class="info">What each engine can do on this server: <a href="/admin/reporter_dashboards/preflight">Render preflight</a>.</em></p>'));
    }
  }

  // ---------------------------------------------------------------- 6. role permissions
  function rolePermissions() {
    const labels = {
      'View report templates and documents': 'View reports',
      'View report schedules and their run history': 'View report schedules',
      // INV-9 (technical-spec.md:580): the label itself says the permission runs code.
      'Author report templates (executes server-side code)': 'Create report templates (runs code)',
      'Edit and delete own report templates (executes server-side code)': 'Edit own report templates (runs code)',
      'Edit and delete any report template (executes server-side code)': 'Edit all report templates (runs code)',
      'Manage public report templates (executes server-side code)': 'Manage public report templates (runs code)',
      'Manage report schedules': 'Manage report schedules',
      'Render reports as another user — grants access to everything that user can see': 'Render reports as another user (sees all they see)',
      'Send a report by e-mail': 'Send reports by e-mail',
      'Create report share links': 'Create report share links',
      'Make report share links public': 'Make report share links public',
    };
    let fieldset = null;
    $$('fieldset label').forEach((label) => {
      const text = label.textContent.trim().replace(/\s+/g, ' ');
      if (labels[text]) {
        const input = $('input', label);
        label.innerHTML = '';
        if (input) label.appendChild(input);
        label.appendChild(document.createTextNode(' ' + labels[text]));
        fieldset = label.closest('fieldset');
      }
    });
    if (fieldset) {
      fieldset.appendChild(el('<p class="ux-perm-note"><em class="info">Template authors run code on the server. "Render reports as another user" shows what that user can see.</em></p>'));
    }
  }

  window.UX = { nav, menuLabel, settingsWithoutTab, sentReports, schedules, widgets, templateNew, templateShow, pluginSettings, rolePermissions };
})();
