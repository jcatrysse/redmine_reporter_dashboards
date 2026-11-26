// UX review 2026-11, mockup only. Evaluated INSIDE a report widget's frame after
// report-frame.css. Argument: { techPatterns } . Returns the scope/technical lines it hid,
// so the parent can show them as one grey foot line under the widget.
//
// Charts: consecutive chart cards are laid out side by side when the widget is wide
// (3 per row from 1100px, 2 from 720px, else 1), never wider than 720px when alone, with
// axis and legend text at Redmine's size and grey.
(opts) => {
  const hidden = [];
  const patterns = (opts.techPatterns || []).map((p) => new RegExp(p, 'i'));
  document.querySelectorAll('body p, body small, body figcaption, body .rrd-muted').forEach((el) => {
    const text = el.textContent.trim();
    if (text && patterns.some((re) => re.test(text))) {
      el.classList.add('ux-tech');
      hidden.push(text.replace(/\s+/g, ' '));
    }
  });

  const width = document.body.clientWidth;
  const maxCols = width >= 1100 ? 3 : width >= 720 ? 2 : 1;
  const isChartCard = (n) => n && n.nodeType === 1 && n.querySelector && n.querySelector(':scope > .rrd-chart-frame, :scope > figure .rrd-chart-frame');
  const groups = [];
  document.querySelectorAll('.rrd-chart-frame').forEach((frame) => {
    const card = frame.closest('.rrd-card') || frame;
    const last = groups[groups.length - 1];
    if (last && last[last.length - 1].nextElementSibling === card) last.push(card);
    else groups.push([card]);
  });
  groups.forEach((cards) => {
    const cols = Math.min(maxCols, cards.length);
    const grid = document.createElement('div');
    grid.className = 'ux-chart-grid';
    grid.style.cssText = `display:grid;grid-template-columns:repeat(${cols},minmax(0,1fr));gap:12px 24px;margin:0 0 12px;max-width:${cols === 1 ? 720 : 9999}px`;
    cards[0].parentNode.insertBefore(grid, cards[0]);
    cards.forEach((c) => grid.appendChild(c));
    cards.forEach((c) => c.querySelectorAll('.rrd-chart-frame').forEach((f) => {
      f.style.maxWidth = 'none';
      f.style.height = `${cols === 1 && maxCols === 1 ? 240 : 230}px`;
    }));
  });
  void isChartCard;

  const font = { family: '"Noto Sans", sans-serif', size: 12 };
  const grey = '#868e96';
  document.querySelectorAll('.rrd-chart-frame canvas').forEach((canvas) => {
    const chart = window.Chart && window.Chart.getChart && window.Chart.getChart(canvas);
    if (!chart) return;
    // The raw config, not chart.options (a resolved proxy that cannot take new objects).
    const o = chart.config.options;
    o.maintainAspectRatio = false;
    o.plugins = o.plugins || {};
    if (o.plugins.legend) { o.plugins.legend.labels = Object.assign(o.plugins.legend.labels || {}, { font, color: grey, boxWidth: 12 }); }
    if (o.plugins.title) { o.plugins.title.font = { ...font, size: 13, weight: 'bold' }; o.plugins.title.color = '#495057'; }
    Object.values(o.scales || {}).forEach((s) => {
      s.ticks = Object.assign(s.ticks || {}, { font, color: grey });
      if (s.title) { s.title.font = font; s.title.color = grey; }
      if (s.grid) s.grid.color = '#e9ecef';
    });
    chart.update('none');
    chart.resize();
  });
  return hidden;
}
