# frozen_string_literal: true

require_relative '../assets/bundled_assets'
require_relative 'chart_spec'
require_relative 'chartjs_emitter'
require_relative 'svg_renderer'

module RedmineReporterDashboards
  module Charts
    # T-41 — THE OUTPUT BINDING. The step §Findings **M-1** says was never written.
    #
    # `{% chart %}` records a `ChartSpec` on the render's `Collector` and emits
    # `<div class="rrd-chart-placeholder" data-rd-chart="id"></div>` and nothing else.
    # T-16's design says *"the output binding decides"* what that becomes, and both
    # emitters were built, unit-tested and given ten SVG goldens — and neither ever
    # acquired a caller, so a chart was an empty `<div>` in every browser and blank
    # space in every PDF. This module is that caller.
    #
    # --- WHY A SUBSTITUTION PASS AND NOT MARKUP FROM THE TAG ---
    #
    # The tag cannot know the binding. `ReportRun` renders a section ONCE and then
    # decides — `html_only` or `with_pdf` — so at Liquid time the answer does not exist
    # yet. Rendering twice would double every query the template makes. A placeholder
    # plus a post-pass is what lets one render serve both outputs, and it is why the
    # tag's own comment says it emits no markup.
    #
    # --- ONE CALLER PER BINDING, AND NOT ONE PER SURFACE ---
    #
    # There are four surfaces (project dashboard widget, my-page widget, template page,
    # editor preview) and exactly TWO bindings. This runs at the two binding sites in
    # `ReportRun`, so a fifth surface inherits it by existing rather than by remembering.
    #
    # --- WHAT IS DELIBERATELY LEFT ALONE ---
    #
    # A placeholder carrying `data-rd-chart-refused` keeps its markup: the tag already
    # decided that chart is not drawn and the collector already carries the degradation
    # saying why. INV-4 — a refused chart stays an ELEMENT, so a reader can tell it from
    # a chart the author never wrote.
    #
    # A placeholder whose id the collector does not know is also left alone, and logged.
    # It means either a plugin defect or an author who hand-wrote the exact markup; in
    # both cases substituting something would be guessing.
    module Binding
      # The tag's own markup, matched exactly. `ChartSpec::ID_PATTERN` has already
      # restricted the id to `[A-Za-z][A-Za-z0-9_-]*` — restricted rather than escaped,
      # which is why this pattern can be this literal and why no unescaping is needed on
      # the way back out.
      PLACEHOLDER = %r{
        <div\ class="rrd-chart-placeholder"
        \ data-rd-chart="(?<id>[A-Za-z][A-Za-z0-9_-]*)"
        (?<refused>\ data-rd-chart-refused="[a-z_]*")?
        ></div>
      }x.freeze

      # Emitted once per document, after the body, when at least one chart on it is drawn
      # by Chart.js. `<script src>` rather than inlined bytes for the same reason
      # `{% mermaid %}` does it: 208 KB per chart per document otherwise, and a dashboard
      # holds several.
      #
      # ORDER IS LOAD-BEARING and all three are classic scripts, so the parser runs them
      # in source order: the readiness shell installs `window.__rd` before anything calls
      # `begin()`, Chart.js defines `window.Chart` before `chart_boot.js` looks for it,
      # and `chart_boot.js` waits for DOMContentLoaded regardless.
      SCRIPTS = [
        'chart_shell.js',
        CHARTJS_ASSET,
        'chart_boot.js'
      ].freeze

      ASSET_ROOT = "#{Assets::BundledAssets::URL_PREFIX}/javascripts".freeze

      # `body` — the rendered section, with placeholders.
      # `collector` — the render's `Charts::Collector`.
      # `output` — `:html` or `:pdf`; anything else is treated as `:html`, because a
      #            binding that refused an unknown value would lose the document over a
      #            caller's typo.
      Result = Struct.new(:body, :javascript, keyword_init: true) do
        # True when at least one chart on this document is drawn by Chart.js, so the
        # caller knows whether the scripts are owed and whether `:javascript` is an
        # essential capability for the engine.
        def javascript?
          !!javascript
        end
      end

      class << self
        def apply(body, collector, output: :html, logger: nil)
          text = body.to_s
          return Result.new(body: text, javascript: false) if collector.nil? || !collector.any?

          binding_output = output.to_sym == :pdf ? :pdf : :html
          javascript = false

          bound = text.gsub(PLACEHOLDER) do
            match = Regexp.last_match
            next match[0] if match[:refused]

            spec = collector[match[:id]]
            if spec.nil?
              log(logger, "[chart] no recorded chart for placeholder #{match[:id].inspect}; " \
                          'left as it was')
              next match[0]
            end

            markup, used_javascript = emit(spec, binding_output)
            javascript ||= used_javascript
            markup
          end

          bound += scripts if javascript
          Result.new(body: bound, javascript: javascript)
        end

        private

        # THE ONE BRANCH IN THIS FILE, and `ChartSpec#supported?` is the question it asks —
        # which is what that predicate's own comment says it is for: *"A supported family
        # can be drawn as SVG with no JavaScript; anything else needs Chart.js"*.
        #
        # So a PDF is SVG whenever it can be: vector, selectable, searchable, drill-through
        # as real `<a xlink:href>` annotations, and no JavaScript for an engine to wait on.
        # An unfamiliar type (`type: radar`) is the exception and falls back to Chart.js on
        # both bindings, which is the behaviour `ChartSpec` already chose when it carried
        # `unsupported_type` instead of raising.
        def emit(spec, output)
          return [SvgRenderer.render(spec), false] if output == :pdf && spec.supported?

          [ChartjsEmitter.emit(spec, output: output), true]
        end

        def scripts
          "\n" + SCRIPTS.map { |name| %(<script src="#{ASSET_ROOT}/#{name}"></script>) }.join("\n") + "\n"
        end

        def log(logger, line)
          logger&.warn(line)
        rescue StandardError
          nil
        end
      end
    end
  end
end
