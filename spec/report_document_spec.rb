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
      expect(document).to include('<html lang="en"><head>')
      expect(document).to include('</head><body>')
      expect(document).to end_with("</body></html>\n")
    end

    it 'declares an encoding, because an engine that guesses one gets it wrong' do
      expect(described_class.wrap(body)).to include('<meta charset="utf-8">')
    end

    # --- `<html lang>` — CURATOR DECISION #7, 2026-08-13 ------------------------------
    #
    # This module's header used to record the attribute as deliberately ABSENT, because a
    # locale is a property of a request and a scheduled render has none. The curator
    # answered the question that left open — whose language a scheduled report speaks —
    # with the INSTALLATION DEFAULT, and these examples are that answer.
    #
    # A screen reader announces the document in this language and a PDF engine hyphenates
    # with it. `dir` is deliberately not emitted: all nine shipped locales are LTR.
    describe 'the language it declares' do
      it 'declares one at all' do
        expect(described_class.wrap(body)).to match(/<html lang="[a-zA-Z-]+">/)
      end

      it 'takes it from the installation default, not from the ambient request locale' do
        stub_const('Setting', Class.new { def self.default_language; 'pt-BR'; end })

        expect(described_class.wrap(body)).to include('<html lang="pt-BR">')
      end

      # THE SETTING IS A PLAIN STRING COLUMN AND AN ADMINISTRATOR CAN EMPTY IT. A blank
      # `lang` is worse than no attribute at all — it tells a screen reader "no language"
      # explicitly — so it falls back rather than being emitted.
      it 'falls back when the setting is blank' do
        stub_const('Setting', Class.new { def self.default_language; ''; end })

        expect(described_class.wrap(body))
          .to include(%(<html lang="#{described_class::FALLBACK_LANGUAGE}">))
      end

      it 'falls back when Redmine is not loaded at all, which is this spec run' do
        expect(described_class.wrap(body)).to include('<html lang="en">')
      end

      # THE ONE VALUE THIS MODULE INTERPOLATES INTO AN ATTRIBUTE, so it is bounded rather
      # than escaped-and-hoped. A setting that is not a language tag cannot reach the
      # document — checked with a value that would break out of the attribute if it did.
      it 'refuses a setting that is not a language tag' do
        stub_const('Setting', Class.new { def self.default_language; '" onload="x'; end })

        document = described_class.wrap(body)

        expect(document).to include('<html lang="en">')
        expect(document).not_to include('onload')
      end

      it 'refuses one that merely looks close' do
        stub_const('Setting', Class.new { def self.default_language; 'en_US'; end })

        expect(described_class.wrap(body)).to include('<html lang="en">')
      end

      # AND THE `lang:` SEAM IS ESCAPED SEPARATELY, which is not belt-and-braces: the
      # `LANGUAGE_TAG` allowlist guards the SETTING, and `lang:` is a public keyword that
      # bypasses it entirely. Found by mutation — replacing `escape_attribute` with the
      # identity left 984 examples green, because every example above went through the
      # allowlist and none through the seam. The two controls guard two different inputs.
      it 'escapes a caller-supplied lang, which the allowlist never sees' do
        document = described_class.wrap(body, lang: '" onload="alert(1)')

        expect(document).not_to include('" onload="alert(1)"')
        expect(document).to include('&quot; onload=&quot;alert(1)')
      end

      it 'escapes the other three attribute-breaking characters too' do
        document = described_class.wrap(body, lang: '<&>')

        expect(document).to include('&lt;&amp;&gt;')
        expect(document).not_to include('<html lang="<&>">')
      end
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
    # --- THE EXCLUSION IS THE PLUGIN'S OWN CLONE, AND `include?('/redmine/')` WAS NOT IT ---
    #
    # A local checkout keeps a Redmine clone at `<plugin>/redmine/` with a COPY of this plugin
    # mirrored inside it, and these globs must not count that copy twice. The first version
    # rejected any path containing `/redmine/` — which is every path in the world when the
    # plugin is installed the way it actually ships: `redmine/plugins/redmine_reporter_dashboards`.
    #
    # CI RUNS IT THAT WAY, and that is how this was found: run 31694811039 failed all four
    # `RSpec` jobs with *"render/engines/chromium_cdp.rb is exempt and does not exist any more"*
    # and an emitter list of `[]`, while every one of them passed locally. Worse than the two
    # red examples is the third, which PASSED — `wraps a report body … from exactly one place`
    # asserts a list is EMPTY, and a glob that matched nothing satisfied it. A vacuous pass is
    # the failure mode this file exists to prevent, in this file.
    #
    # The clone is excluded by its absolute path instead, which cannot mean something else
    # depending on where the plugin is installed.
    def clone_prefix
      "#{File.expand_path('../redmine', __dir__)}/"
    end

    def sources_under(*dirs)
      dirs.flat_map { |dir| Dir[File.expand_path("../#{dir}/**/*.{rb,erb}", __dir__)] }
          .reject { |path| path.start_with?(clone_prefix) }
          .to_h { |path| [path, File.read(path, encoding: 'UTF-8')] }
    end

    # A GLOB THAT MATCHES NOTHING MUST NOT BE A PASS. Every example below asks a question about
    # a set of files, and two of the three are satisfied by an empty set — so the set itself is
    # asserted first, once, with a floor that is obviously below the real count.
    it 'finds the sources it is asking about' do
      expect(sources_under('lib', 'app').length).to be > 100
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
