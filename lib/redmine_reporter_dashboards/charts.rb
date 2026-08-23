# frozen_string_literal: true

module RedmineReporterDashboards
  # The chart layer — one authoring act, two outputs, one layout (technical-spec.md §6).
  #
  # --- WHY IT IS HERE AND NOT UNDER `render/` ---
  #
  # §1.1's tree puts `charts/{chart_spec,chart_layout,svg_renderer,chartjs_emitter}.rb`
  # under `render/`. §3.5 puts `charts` on `RenderContext`, which is the **Liquid**
  # layer. And mechanism E3 (`script/gates/layer_purity.sh`) forbids `liquid/**` from
  # naming `…Dashboards::Render`. Those three cannot all hold: `{% chart %}` has to
  # build a `ChartSpec`, and under `render/` it could not name one.
  #
  # The mechanism wins over the directory listing, because the mechanism is the thing
  # with a test. So the chart layer sits between the two and names NEITHER — the Liquid
  # layer may record into it, the render layer may draw from it, and the gate that keeps
  # those two apart is untouched. `implementation-plan.md` §Findings **F-13** records
  # the deviation rather than resolving it silently; moving the files is a `git mv` and
  # a namespace change if the curator prefers the tree as written.
  #
  # --- THE SHAPE, IN ONE PARAGRAPH ---
  #
  #   {% chart %}   → Collector#record(ChartSpec)   and a `<div data-rd-chart>` placeholder
  #   ChartLayout   → scales, ticks, palette, plot rectangle — computed ONCE, in Ruby
  #   SvgRenderer   → the PDF path: inline <svg>, no JavaScript, deterministic text
  #   ChartjsEmitter→ the HTML path: <canvas> + <script type="application/json">
  #
  # Neither emitter decides anything the other could decide differently. That is what
  # makes "identical in HTML and PDF" a construction rather than an aspiration, and
  # `spec/charts/shared_layout_falsifier_spec.rb` is what stops it being a claim.
  module Charts
    # The vendored library, and the two facts about it that have to be checkable.
    # `script/gates/vendor_integrity.sh` recomputes the digest and fails on a mismatch,
    # and on any CDN reference anywhere in the shipped assets — §6's "no network fetch,
    # ever" is simultaneously the SRI fix, the reproducibility fix and the prerequisite
    # for INV-8's zero-egress posture.
    CHARTJS_VERSION = '4.5.0'
    CHARTJS_SHA256 = 'b7929ad4d5323b8244f85d79bba0b3d1495e66f79a2f0023be7f4de5ba4fbac8'
    CHARTJS_ASSET = 'vendor/chart.umd.js'
  end
end

require_relative 'charts/palette'
require_relative 'charts/chart_spec'
require_relative 'charts/chart_layout'
require_relative 'charts/svg_renderer'
require_relative 'charts/chartjs_emitter'
require_relative 'charts/collector'
