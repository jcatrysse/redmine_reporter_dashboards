# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/redmine_reporter_dashboards/report_document'

# T-38 — the ONE place a report body becomes a document, and the reason there is only one.
#
# "One print-first stylesheet and one type scale used by the HTML view AND the PDF body"
# is a claim about construction. Two assemblers would satisfy it on the day they were
# written and stop satisfying it at the first edit to one of them, which is exactly how
# `ReportRun::OUTPUT_CLASSES` and `ExecutionPolicy::OUTPUT_CLASSES` drifted (§Findings
# E-40). So the property asserted here is not "both documents contain a stylesheet" — it
# is that there is ONE assembler and ONE source module, and that the frame's document is this
# module's output plus a CSP and nothing else.
#
# IT USED TO SAY "the SAME OBJECT", and an independent review measured that no example could
# hold that: every assertion is `include(style_element)`, which is substring containment, so a
# `.dup` in the assembler survived the whole file. Ruby cannot express "this substring is that
# object". What CAN be held is what the two examples at the bottom now hold — one assembler
# emitting one module's output, asserted by SOURCE over `lib/` and `app/` — and HANDOVER §1's
# rule about pointing a second constant at the first rather than comparing them is the same
# idea one level up.
RSpec.describe RedmineReporterDashboards::ReportDocument do
  # A METHOD, NOT A CONSTANT: a constant assigned inside `RSpec.describe` lands at the
  # file's top level and collides across the suite (see `report_run_spec.rb`'s header).
  def sheet
    RedmineReporterDashboards::ReportStylesheet
  end

  let(:body) { '<h1>Report</h1><table><thead><tr><th>x</th></tr></thead></table>' }

  describe '.wrap' do
    it 'produces a whole document, not a fragment' do
      document = described_class.wrap(body)

      expect(document).to start_with('<!DOCTYPE html>')
      expect(document).to include('<html><head>')
      expect(document).to include('</head><body>')
      expect(document).to end_with("</body></html>\n")
    end

    it 'declares an encoding, because an engine that guesses one gets it wrong' do
      expect(described_class.wrap(body)).to include('<meta charset="utf-8">')
    end

    it 'carries the report stylesheet' do
      expect(described_class.wrap(body)).to include(sheet.style_element)
    end

    it 'puts the stylesheet in the head, where a stylesheet applies to what follows' do
      document = described_class.wrap(body)
      head = document[/<head>(.*?)<\/head>/m, 1]

      expect(head).to include(sheet.style_element)
    end

    # THE AUTHOR'S OWN `<style>` MUST STILL WIN. Both shipped example templates open with
    # a `<style>` block, and a plugin default that overrode them would be a plugin
    # redesigning somebody's report. The cascade decides this by SOURCE ORDER at equal
    # specificity, so "ours is in the head and theirs is in the body" is the whole
    # mechanism — asserted as an ordering fact rather than trusted.
    it 'goes BEFORE the body, so a template\'s own style overrides the default' do
      document = described_class.wrap('<style>h1 { font-size: 99px }</style><h1>x</h1>')

      expect(document.index(sheet.style_element))
        .to be < document.index('font-size: 99px')
    end

    it 'passes the body through unchanged, escaping nothing and dropping nothing' do
      expect(described_class.wrap(body)).to include(body)
    end

    # `head:` is the caller's, and this module never invents one. `ReportFrame` uses it for
    # the CSP; the PDF path passes none, because there is no browser to enforce a policy
    # and an engine may reasonably refuse its own document.
    it 'inserts the caller\'s head markup before the stylesheet' do
      document = described_class.wrap(body, head: "<meta name=\"x\" content=\"1\">\n")

      expect(document.index('name="x"')).to be < document.index(sheet.style_element)
      expect(document.index('name="x"')).to be > document.index('<head>')
    end

    it 'adds no head markup of its own when the caller passes none' do
      document = described_class.wrap(body)

      expect(document.scan('<meta').length).to eq(1) # the charset, and nothing else
    end

    # A body is markup already rendered by the Liquid layer, where escaping lives. This
    # module concatenates and decides nothing, so a `<script>` in a body stays a
    # `<script>` — on the HTML binding it then becomes `srcdoc` ATTRIBUTE data, which
    # Rails escapes, and on the PDF binding no browser of the viewer's ever parses it.
    it 'does not escape the body, because escaping happened in the Liquid layer' do
      expect(described_class.wrap('<script>x</script>')).to include('<script>x</script>')
    end

    # INV-9 and the `no_html_safe` rule, asserted about the file rather than about a
    # return value: a plain String is never a SafeBuffer, so an assertion on the output
    # would pass whatever this module did.
    it 'never marks its output safe' do
      source = File.read(
        File.expand_path('../lib/redmine_reporter_dashboards/report_document.rb', __dir__),
        encoding: 'UTF-8'
      )

      expect(source.gsub(/^\s*#.*$/, '')).not_to include('html_safe')
    end

    it 'survives an empty body without producing something that is not a document' do
      expect(described_class.wrap('')).to start_with('<!DOCTYPE html>')
      expect(described_class.wrap(nil.to_s)).to include('<body></body>')
    end

    # The stylesheet is built once, so a 50-document run inlines the same bytes 50 times
    # rather than building 50 copies.
    it 'reuses one stylesheet object across documents' do
      expect(described_class.wrap('a')).to include(sheet.style_element)
      expect(described_class.wrap('b')).to include(sheet.style_element)
      expect(sheet.style_element).to be(sheet.style_element)
    end
  end

  # --- "ONE STYLESHEET" AS A PROPERTY OF THE TREE, not of a return value -----------------
  #
  # These two are the mechanical form of the claim the header used to make by hand. A second
  # assembler or a second `<style>` for a report body is what would make the HTML view and the
  # PDF stop being the same document, and neither is visible in anything either module
  # RETURNS — it is visible in how many places emit one.
  describe 'there is one assembler and one stylesheet' do
    def sources_under(*dirs)
      dirs.flat_map { |dir| Dir[File.expand_path("../#{dir}/**/*.{rb,erb}", __dir__)] }
          .reject { |path| path.include?('/redmine/') }
          .to_h { |path| [path, File.read(path, encoding: 'UTF-8')] }
    end

    # Comments are stripped: `ReportFrame` and `ReportStylesheet` both DISCUSS `<style>` in
    # their headers, and an assertion that punished the explanation would teach the next author
    # to delete it — `layer_purity.sh`'s own first run, again.
    def code_only(text)
      text.gsub(/^\s*#.*$/, '').gsub(/<%#.*?%>/m, '')
    end

    # THE FOUR EXEMPT FILES, EACH WITH ITS REASON — the convention `zero_reporter.allowlist`
    # and `layer_purity.sh` both follow, and the first version of these two examples had none,
    # so they failed on documents that are not report bodies at all.
    #
    # An engine's PREFLIGHT PROBE is a complete, self-contained document the adapter posts to
    # itself to find out whether the engine works. It never carries a template's output, it is
    # never shown to a reader, and it must NOT gain the report stylesheet: its whole purpose is
    # to isolate "can this engine draw anything" from everything else. `preflight.rb`'s probe
    # is the same thing one layer up, and it is the one that also needs a `<style>`, because
    # what it measures is whether the engine applied CSS at all.
    EXEMPT = {
      'render/engines/chromium_cdp.rb' => "the adapter's own preflight probe document",
      'render/engines/gotenberg.rb' => "the adapter's own preflight probe document",
      'render/engines/wkhtmltopdf.rb' => "the adapter's own preflight probe document",
      'render/preflight.rb' => 'the preflight probe, whose subject IS whether CSS applied'
    }.freeze

    def unexempt(matches)
      matches.keys.reject { |path| EXEMPT.keys.any? { |tail| path.end_with?(tail) } }
    end

    it 'emits a <style> element for a report body from exactly one place' do
      emitters = sources_under('lib', 'app').select { |_path, text| code_only(text).include?('<style>') }

      expect(unexempt(emitters).map { |path| path.split('/').last })
        .to eq(['report_stylesheet.rb'])
    end

    it 'wraps a report body into a document from exactly one place' do
      callers = sources_under('lib', 'app').select do |path, text|
        !path.end_with?('report_document.rb') && code_only(text).include?('<!DOCTYPE html>')
      end

      expect(unexempt(callers)).to be_empty,
                                   "#{unexempt(callers).join(', ')} assembles its own document. " \
                                   'There is one assembler (ReportDocument), and a second one is ' \
                                   'how the HTML view and the PDF stop being the same document at ' \
                                   'the first edit.'
    end

    # AN EXEMPTION THAT PERMITS NOTHING IS WHAT SILENTLY PERMITS SOMETHING LATER —
    # `zero_reporter.sh` learned this and says so. Each entry has to still be needed.
    it 'has no stale exemption' do
      all = sources_under('lib', 'app')

      EXEMPT.each_key do |tail|
        path = all.keys.find { |candidate| candidate.end_with?(tail) }
        expect(path).not_to be_nil, "#{tail} is exempt and does not exist any more"
        expect(code_only(all[path])).to include('<!DOCTYPE html>'),
                                       "#{tail} is exempt and no longer assembles a document; " \
                                       'delete the entry'
      end
    end
  end
end
