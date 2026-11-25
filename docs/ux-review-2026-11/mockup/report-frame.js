// UX review 2026-11, mockup only. Evaluated INSIDE a report widget's frame after
// report-frame.css. Argument: { chartHeight, techPatterns } . Returns the technical
// notes it hid, so the parent can offer them to editors behind one small icon.
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
  document.querySelectorAll('.rrd-chart-frame').forEach((frame) => {
    frame.style.maxWidth = 'none';
    frame.style.height = `${opts.chartHeight}px`;
    const canvas = frame.querySelector('canvas');
    const chart = canvas && window.Chart && window.Chart.getChart && window.Chart.getChart(canvas);
    if (chart) {
      chart.options.maintainAspectRatio = false;
      chart.resize();
    }
  });
  return hidden;
}
