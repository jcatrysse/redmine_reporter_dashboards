# frozen_string_literal: true

require_relative 'spec_helper'
require 'yaml'
require_relative '../lib/redmine_reporter_dashboards/starter_gallery'
require_relative '../lib/redmine_reporter_dashboards/template_linter'

# T-37 / FR-73 — THE GALLERY'S LINT HALF, which is the half a spec can reach.
#
# *"a starter gallery whose every entry lints clean and renders on every engine in the matrix,
# thumbnails generated in CI"*. Three clauses, three homes:
#
#   lints clean      here, at ZERO findings per entry rather than at a ratchet. The two legacy
#                    examples are held at a ratchet by `spec/shipped_templates_lint_spec.rb`
#                    and are deliberately NOT gallery entries — `StarterGallery`'s own header
#                    argues that at length.
#   renders on every `rake reporter_dashboards:gallery:verify`, because a render needs a
#   engine          booted Redmine, a project with data in it and a real engine. Its wiring is
#                    `test/unit/reporter_dashboards_gallery_rake_test.rb`.
#   thumbnails       here as a PROVENANCE check: the recorded digest of the body each
#                    thumbnail was drawn from must still match. See the module for why that
#                    rather than a pixel diff.
RSpec.describe RedmineReporterDashboards::StarterGallery do
  # METHODS, NOT CONSTANTS. A constant assigned inside an `RSpec.describe` block lands on
  # `Object` — HANDOVER §1 records it as a real defect, not a style point: T-22's review found
  # one breaking two of T-16's examples in the randomised full run while passing in isolation.
  def linter
    RedmineReporterDashboards::TemplateLinter
  end

  def locale_root
    File.expand_path('../config/locales', __dir__)
  end

  def entries
    described_class.entries
  end

  describe 'the manifest' do
    it 'ships five starters, which is §9b.1\'s count' do
      expect(entries.length).to eq(5)
    end

    it 'has a unique, url-safe id for each' do
      ids = entries.map(&:id)

      expect(ids.uniq).to eq(ids)
      expect(ids).to all(match(/\A[a-z][a-z0-9-]*\z/))
    end

    it 'points every entry at a file that exists' do
      entries.each do |entry|
        expect(File.file?(described_class.path(entry))).to be(true), entry.id
      end
    end

    # THE ID NEVER BECOMES PART OF A PATH — `find` is a lookup in a frozen Hash. These four
    # are the shapes a traversal takes, and each must answer nil rather than reaching disk.
    describe '#find' do
      it 'answers the entry for a known id' do
        expect(described_class.find('chart-report').file).to eq('chart-report.liquid')
      end

      it 'answers nil for anything else, including a traversal' do
        ['', 'nope', '../../config/database', 'issue-document.liquid',
         '..%2f..%2fetc%2fpasswd', 'issue-document/../../Gemfile'].each do |attempt|
          expect(described_class.find(attempt)).to be_nil, attempt.inspect
        end
      end

      it 'answers nil for nil without raising' do
        expect(described_class.find(nil)).to be_nil
      end
    end

    it 'declares a source and an output the model knows' do
      entries.each do |entry|
        expect(%w[issues time_entries]).to include(entry.source), entry.id
        expect(%w[per_record combined]).to include(entry.output), entry.id
      end
    end

    # A gallery whose five entries are five combined issue reports teaches one thing five
    # times. Both sources and both outputs are covered, and this is what says so.
    it 'covers both sources and both outputs between them' do
      expect(entries.map(&:source).uniq.sort).to eq(%w[issues time_entries])
      expect(entries.map(&:output).uniq.sort).to eq(%w[combined per_record])
    end
  end

  describe 'every entry lints clean' do
    it 'has zero findings, not a ratchet' do
      offenders = entries.filter_map do |entry|
        findings = linter.lint(described_class.body(entry))
        next if findings.empty?

        "#{entry.id}: #{findings.map { |f| "#{f.position} #{f.rule}" }.join('; ')}"
      end

      expect(offenders).to eq([])
    end

    # A FILE THAT LINTS CLEAN BY BEING EMPTY IS NOT A STARTER. Every clause below has been a
    # real way for a "clean" template to be useless: no body at all, a body that is only the
    # explanatory comment, or a body that stopped using the surface it exists to demonstrate.
    it 'has a body worth starting from' do
      entries.each do |entry|
        body = described_class.body(entry)
        code = body.gsub(/\{%-?\s*comment\s*-?%\}.*?\{%-?\s*endcomment\s*-?%\}/m, '')

        expect(body.length).to be > 500, entry.id
        expect(code).to match(/\{\{|\{%/), "#{entry.id} has no Liquid outside its comments"
        expect(code).to match(/<(h1|table|div)/), "#{entry.id} emits no markup"
      end
    end

    it 'explains itself in a comment, because a starter is read before it is run' do
      entries.each do |entry|
        expect(described_class.body(entry)).to start_with('{% comment %}'), entry.id
      end
    end

    # T-38's three public classes are the styling contract, and a starter is where an author
    # first meets them. A starter with a `<style>` block of its own would be teaching the
    # opposite of §9b.4.
    #
    # COMMENTS ARE STRIPPED FIRST, and that is not a loophole — it is the lesson
    # `script/gates/layer_purity.sh` records about its own first run: it failed on the two
    # comments EXPLAINING why the boundary exists, and "a gate that punishes writing down its
    # own rationale teaches people to delete the rationale". This assertion hit exactly that:
    # `issue-document.liquid` explains in prose that `| json` is the filter to use INSIDE a
    # `<script>`, which is the sentence an author most needs and the one this check would
    # have deleted.
    it 'uses the documented classes and ships no stylesheet of its own' do
      expect(entries.map { |e| described_class.body(e) }.join).to include('rrd-card')

      entries.each do |entry|
        code = described_class.body(entry)
                              .gsub(/\{%-?\s*comment\s*-?%\}.*?\{%-?\s*endcomment\s*-?%\}/m, '')

        expect(code).not_to include('<style'), entry.id
        expect(code).not_to include('<script'), entry.id
      end
    end
  end

  describe 'the locale keys' do
    # §10: *"Update every locale file when you add a key — an absent key falls back to English
    # silently, which reads as a bug to a Dutch or Russian user and hides the gap from
    # review."* The keys are DERIVED from the id, so this check is what makes adding a starter
    # without its twelve translations impossible rather than merely discouraged.
    it 'has a name and a description for every entry in every one of the twelve locales' do
      missing = Dir.glob(File.join(locale_root, '*.yml')).sort.flat_map do |path|
        keys = YAML.load_file(path).values.first.keys

        entries.flat_map do |entry|
          [entry.name_key, entry.description_key].reject { |key| keys.include?(key.to_s) }
                                                 .map { |key| "#{File.basename(path)}: #{key}" }
        end
      end

      expect(missing).to eq([])
    end

    it 'checks all twelve locales, so it cannot pass by finding one file' do
      expect(Dir.glob(File.join(locale_root, '*.yml')).length).to eq(12)
    end
  end

  # FR-73's *"thumbnail rendered by the plugin itself … so the thumbnail cannot show something
  # the code no longer produces"*, checked deterministically. The module's header argues why
  # this is a digest and not a pixel comparison; in short, §9b.5 makes a perceptual diff
  # advisory and CLAUDE.md §7 forbids reporting an advisory check as PASS.
  describe 'the thumbnails' do
    it 'has one per starter, drawn from the body that is committed now' do
      stale = described_class.stale_thumbnails.map { |entry, reason| "#{entry.id}: #{reason}" }

      expect(stale).to eq([]),
                       lambda {
                         (['a thumbnail is missing or was drawn from an older body. Regenerate ' \
                           'with `rake reporter_dashboards:gallery:verify RRD_THUMBNAILS=1 ' \
                           'RRD_PROJECT=… RRD_ACTOR=…` and commit both the PNG and ' \
                           'thumbnails.yml:'] + stale).join("\n")
                       }
    end

    it 'records a digest that really is the body\'s' do
      recorded = described_class.recorded_digests

      entries.each do |entry|
        expect(recorded[entry.id]).to eq(described_class.digest(entry)), entry.id
      end
    end

    it 'ships a real PNG rather than a placeholder of some other type' do
      entries.each do |entry|
        bytes = File.binread(described_class.thumbnail_path(entry), 8)

        expect(bytes).to eq("\x89PNG\r\n\x1A\n".b), entry.id
      end
    end

    # The recorded digest is over the body, so a manifest holding a stale key would keep
    # claiming a starter that no longer exists.
    it 'records nothing for a starter that is not in the gallery' do
      expect(described_class.recorded_digests.keys.sort).to eq(entries.map(&:id).sort)
    end

    # --- THE NEGATIVE HALF, AND IT WAS A MUTATION SURVIVOR ---
    #
    # Every example above passes against a `stale_thumbnails` that always answers `[]`:
    # replacing `next if was == digest(entry)` with a bare `next` killed the detector and the
    # suite stayed green, because nothing here had ever shown it a CHANGED body. A detector
    # with no negative case is indistinguishable from a method that returns an empty array.
    #
    # So these three drive it: a body that has moved, a starter with no entry in the manifest,
    # and one whose PNG is missing. Each names its own reason, because "stale" with no reason
    # is a red build somebody clears by regenerating without reading.
    describe 'the staleness detector itself' do
      it 'reports a starter whose body has changed since its thumbnail was drawn' do
        entry = entries.first
        allow(described_class).to receive(:digest).and_call_original
        allow(described_class).to receive(:digest).with(entry).and_return('0' * 64)

        stale = described_class.stale_thumbnails

        expect(stale.map { |found, _reason| found.id }).to eq([entry.id])
        expect(stale.first.last).to include('has changed since its thumbnail was drawn')
      end

      it 'reports a starter the manifest has never heard of' do
        entry = entries.last
        recorded = described_class.recorded_digests.reject { |id, _| id == entry.id }
        allow(described_class).to receive(:recorded_digests).and_return(recorded)

        stale = described_class.stale_thumbnails

        expect(stale.map { |found, _reason| found.id }).to eq([entry.id])
        expect(stale.first.last).to include('not recorded in thumbnails.yml')
      end

      it 'reports a starter whose thumbnail file is absent' do
        entry = entries[1]
        allow(described_class).to receive(:thumbnail?).and_call_original
        allow(described_class).to receive(:thumbnail?).with(entry).and_return(false)

        stale = described_class.stale_thumbnails

        expect(stale.map { |found, _reason| found.id }).to eq([entry.id])
        expect(stale.first.last).to include('no thumbnail has been generated')
      end
    end
  end
end
