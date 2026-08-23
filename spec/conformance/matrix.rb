# frozen_string_literal: true

require_relative 'conformance'
require_relative '../../lib/redmine_reporter_dashboards/render/engine_catalogue'

module RedmineReporterDashboards
  module Conformance
    # G9 — the support matrix is GENERATED FROM THE RUN, and a committed file that
    # disagrees with the run fails the build.
    #
    # --- WHY GENERATION IS THE WHOLE POINT ---
    #
    # A hand-written support matrix is a statement of intent that ages into a lie, and
    # INV-7 is this project's record of that happening: the plugin claimed Redmine 5.1
    # support for four minor versions while CI never ran it, and two defects had been
    # shipping since v0.5.0 in the configuration nobody tested. A matrix nobody can
    # edit — because the run writes it — cannot drift, and a PR that changes what an
    # engine can do has to carry the changed table with it or go red.
    #
    # --- WHAT IS DELIBERATELY NOT IN THE FILE ---
    #
    # The exact engine build, the machine, the date. All three change without anything
    # about SUPPORT changing, and a matrix that goes red because Chromium shipped a
    # patch release trains people to regenerate it without reading it — which is the
    # same failure as not having it. The committed file therefore carries declarations
    # and outcomes; the run's own log carries the exact versions, and CI keeps those.
    module Matrix
      HEADER = <<~MD
        <!-- GENERATED FILE — do not edit by hand.

             Written by the render-smoke job from an actual conformance run:

                 RRD_CONFORMANCE=1 RRD_MATRIX_WRITE=1 rspec spec/conformance

             Gate G9 fails if the committed file and a fresh run disagree, so editing
             this by hand does not make a claim true — it makes the build red. If a
             cell here is wrong, the fixture or the adapter is what has to change.
        -->

        # Engine support matrix

        This is what each render engine **did**, not what it was hoped to do. Every cell
        below comes from `spec/conformance/`, run against the engine named in the column.

        Three states, and the difference between the second and the third is the whole
        design (gate G12):

        | Cell | Means |
        |---|---|
        | `PASS` | the engine declares the capability the fixture needs, and the fixture passed |
        | `SKIP` | the engine **does not declare** the capability — the fixture does not apply, and the reason names it |
        | `FAIL` | the engine **declares** the capability and the fixture failed. A declaration is a promise |

        And the Role column, which is spelled out here because one of its three values is
        also a `verification:` value meaning something else entirely — a UX review read
        `documented` in a row headed by measured cells and took it for "no adapter ships":

        | Role | Means |
        |---|---|
        | `reference` | the default, and the engine every other column is compared against |
        | `compatibility` | kept so existing installs keep rendering; deprecated on arrival |
        | `documented` | a first-class adapter you choose deliberately, because it needs a service you run. **Not** `verification: documented`, which means no adapter ships at all |

        **Which build produced these cells is not in this file, on purpose** — see the note in
        `spec/conformance/matrix.rb`: a matrix that goes red because Chromium shipped a patch
        release trains people to regenerate it without reading it. Per-engine provenance (the
        version, the pinned digest, the CI run) is recorded in `config/capabilities.yml`'s
        `verification_note`, and the run's own log carries the exact versions. That mattered
        less while an unverified engine's note was printed below; every engine is verified
        now, so this sentence is where a reader is sent instead.
      MD

      module_function

      # `reports` is a hash of engine id => Conformance::Report.
      def render(reports:, fixtures:, catalogue: Render::EngineCatalogue.load)
        engines = catalogue.engines
        verify_coverage!(engines, reports)

        [HEADER,
         engine_section(engines),
         capability_section(engines, catalogue),
         corpus_section(engines, fixtures, reports),
         footer_section(engines)].join("\n")
      end

      # An engine the catalogue says must be conformance-verified, that did not run, is
      # a HARD ERROR rather than an empty column. An empty column reads as "nothing to
      # report" and means "nobody checked", and those two must never share a rendering.
      def verify_coverage!(engines, reports)
        missing = engines.select { |e| e.corpus_verified? && !reports.key?(e.id) }
        return true if missing.empty?

        raise HarnessError,
              "the catalogue requires a conformance run for #{missing.map(&:id).join(', ')} " \
              'and none was supplied. Generating the matrix without it would print an empty ' \
              'column, which reads as "nothing to report" and means "nobody checked".'
      end

      def engine_section(engines)
        rows = engines.map do |e|
          "| `#{e.id}` | #{e.role} | #{e.default ? 'yes' : 'no'} | " \
            "#{e.needs_service ? 'yes' : 'no'} | #{e.renders_offline ? 'yes' : 'no'} | " \
            "#{e.install} |"
        end

        <<~MD
          ## The engines

          | Engine | Role | Default | Needs a service | Renders offline | Install cost |
          |---|---|---|---|---|---|
          #{rows.join("\n")}

          #{engines.map { |e| "* **`#{e.id}`** — #{e.trade}" }.join("\n")}
        MD
      end

      def capability_section(engines, catalogue)
        rows = Render::Capabilities::ALL.map do |capability|
          cells = engines.map { |e| e.capabilities.include?(capability) ? 'yes' : '—' }
          "| `:#{capability}` | #{cells.join(' | ')} |"
        end

        <<~MD
          ## Declared capabilities

          What each engine **claims**. `spec/conformance/conformance_spec.rb` asserts that a
          registered adapter's own `#capabilities` equals its row here, so the declaration and
          the code cannot drift apart — the file is not documentation of the adapter, it is the
          same fact written where an operator can read it (#{catalogue.source_name}).

          | Capability | #{engines.map { |e| "`#{e.id}`" }.join(' | ')} |
          |---|#{engines.map { '---' }.join('|')}|
          #{rows.join("\n")}
        MD
      end

      def corpus_section(engines, fixtures, reports)
        rows = fixtures.map do |fixture|
          cells = engines.map { |e| cell(e, reports[e.id], fixture) }
          "| `#{fixture.id}` | #{fixture.title} | #{cells.join(' | ')} |"
        end

        <<~MD
          ## Conformance corpus

          | Fixture | What it asserts | #{engines.map { |e| "`#{e.id}`" }.join(' | ')} |
          |---|---|#{engines.map { '---' }.join('|')}|
          #{rows.join("\n")}
        MD
      end

      # ONLY A `corpus` ENGINE GETS MEASURED CELLS, even when a report happens to be in
      # hand. That is what makes this file reproducible: the committed matrix must be
      # the same document wherever it is generated, and an engine whose binary is
      # present on one machine and absent on another would otherwise move every cell in
      # its column depending on who ran it. Promoting an engine to `corpus` is therefore
      # a deliberate act — it says "this is measured in the environment that generates
      # the matrix", and the generator refuses to proceed without the run.
      def cell(engine, report, fixture)
        return 'not verified' unless engine.corpus_verified?
        return 'no adapter' if report.nil?

        outcome = report[fixture.id]
        return 'not run' if outcome.nil?

        case outcome.state
        when :pass then 'PASS'
        when :fail then "**FAIL** — #{one_line(outcome.reason)}"
        when :skip then "SKIP — #{one_line(outcome.reason)}"
        else "**HARNESS ERROR** — #{one_line(outcome.reason)}"
        end
      end

      def footer_section(engines)
        undeclared = engines.reject(&:corpus_verified?)
        # EMPTY, not a newline. Every shipped engine is `verification: corpus` since
        # 2026-08-11, so this section is absent — and `"\n"` joined with the section
        # separator left the file ending in two blank lines, a visible artefact of a
        # deleted section in a generated document.
        return '' if undeclared.empty?

        lines = undeclared.map do |e|
          "* **`#{e.id}`** — #{e.verification_note}"
        end

        <<~MD
          ## Columns that are not measurements

          INV-7's rule, applied to engines: a configuration nobody ran is unsupported, and
          saying so is cheaper than finding out from a user.

          #{lines.join("\n")}
        MD
      end

      # A cell is one table row; a multi-line reason would break the table and a
      # truncated one would hide the diagnosis. The full text is in the run's output,
      # which is where somebody debugging a red cell is already looking.
      def one_line(reason)
        flat = reason.to_s.gsub(/\s+/, ' ').strip.tr('|', '/')
        flat.length > 120 ? "#{flat[0, 117]}…" : flat
      end
    end
  end
end
