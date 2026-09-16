# frozen_string_literal: true

# T-37 / FR-72 — the drop reference, against the REAL Liquid gem on BOTH majors.
#
# --- WHY IT IS HERE AND NOT IN `spec/` ---
#
# `spec/spec_helper.rb` installs a minimal Liquid STUB so the drops load without the gem,
# and that stub has no `invokable_methods` — the one method this whole module is built on.
# Worse, the first version of this file lived in `spec/` and did `require 'liquid'`, which
# loaded the real gem into a process the other specs had written against the stub: nineteen
# of T-16's chart-tag examples went red with `private method 'new' called for ChartTag`,
# because `Liquid::Tag.new` is private in Liquid 5 and the stub's is not. So the surface
# this file reads must come from the real gem, and `spec_liquid/` is where the real gem
# lives — see its README. It runs on 4.0.4 and 5.13.0, which also answers a question
# nobody had asked: `invokable_methods` reports the same set on both majors.
#
# `script/gates/drop_reference_parity.sh` is the gate; this file is what makes the gate's
# subject worth trusting. The gate can only say "these two sets agree" — it cannot say that
# the sets are the right sets, that a type is one a reader can look up, or that a snippet is
# copyable. Those are properties of this module and they are asserted here.
#
# The one thing this file deliberately does NOT do is repeat the gate's own comparison as a
# passing example. `#parity?` is asserted — because a red suite is a faster signal than a red
# gate — but the gate is what runs it in CI, and a spec that only asserted parity would make
# the gate look redundant while covering none of its other three questions.
require 'liquid'
require_relative '../lib/redmine_reporter_dashboards/liquid/drop_reference'

RSpec.describe RedmineReporterDashboards::Liquid::DropReference do
  before do
    skip 'run with the real gem: rspec -r liquid spec_liquid' unless defined?(::Liquid::VERSION)
  end

  # SPELLED OUT rather than assigned to a short constant here: a constant assigned inside an
  # `RSpec.describe` block lands on `Object` (HANDOVER §1 — it broke two of T-16's examples
  # once, in the randomised full run only), and `Drops` is a name several other files would
  # be delighted to collide with.
  def drops
    RedmineReporterDashboards::Liquid::Drops
  end

  describe 'the surface it describes' do
    it 'agrees with the runtime in both directions' do
      expect(described_class.undocumented).to eq({})
      expect(described_class.absent_at_runtime).to eq({})
    end

    it 'covers every drop class and every base this layer ships' do
      expect(described_class.unreferenced_classes).to eq([])
    end

    it 'names no class that does not exist' do
      expect(described_class.unknown_classes).to eq([])
    end

    # THE NAMES COME FROM THE CODE, and this is the example that says so rather than
    # trusting the comment: an accessor removed from a drop disappears from the reference
    # without anybody editing the reference.
    it 'reads the accessor names from the class rather than from a hand-written list' do
      section = described_class.sections.find { |s| s.klass == 'UserDrop' }
      runtime = drops::UserDrop.invokable_methods.to_a.map(&:to_s) - described_class::PROTOCOL

      expect(section.accessors.map(&:name).sort).to eq(runtime.sort)
    end

    # `to_liquid` is on every drop because `Liquid::Drop` defines it. It is the drop
    # PROTOCOL, not vocabulary, and its exclusion is one constant rather than a filter
    # repeated per class — so "why is it not in the reference" has an answer.
    it 'excludes the drop protocol, and excludes it in one place' do
      expect(described_class::PROTOCOL).to eq(['to_liquid'])
      expect(described_class.sections.flat_map { |s| s.accessors.map(&:name) })
        .not_to include('to_liquid')
    end
  end

  describe 'the metadata a method signature cannot carry' do
    it 'gives every accessor a type from the closed vocabulary' do
      offenders = described_class.sections.flat_map do |section|
        section.accessors.reject { |a| described_class::TYPES.include?(a.type) }
               .map { |a| "#{section.klass}##{a.name} => #{a.type.inspect}" }
      end

      expect(offenders).to eq([])
    end

    # A `drop`/`collection`/`ref` accessor whose target is not named is a row that tells the
    # reader "this is another drop" and leaves them to guess which.
    it 'names the target class of every nested drop and collection' do
      offenders = described_class.sections.flat_map do |section|
        section.accessors.select { |a| %i[drop collection].include?(a.type) && a.of.nil? }
               .map { |a| "#{section.klass}##{a.name}" }
      end

      # `CollectionDrop`'s own three are the legitimate cases and the only ones: the BASE
      # cannot know what its subclass holds, so each concrete collection overrides those
      # rows with its element type. If a fifth collection drop is added and forgets to, this
      # example names it.
      expect(offenders).to eq(['CollectionDrop#first', 'CollectionDrop#visible',
                               'CollectionDrop#all'])
    end

    # THE BATCH FLAG IS THE MOST USEFUL THING IN THE TABLE and the easiest to get silently
    # wrong, so the accessors that go through §3.4's batch registry are pinned by name. A
    # row that lost its flag would tell an author that a 500-issue loop is free when it is
    # not, or the reverse — which is how an author avoids the accessor they should use.
    it 'marks exactly the accessors that read through the batch registry' do
      issue = described_class.sections.find { |s| s.klass == 'IssueDrop' }
      batched = issue.accessors.select(&:batch?).map(&:name).sort

      expect(batched).to eq(%w[attachments custom_field_value custom_field_values spent_hours
                               subtasks time_entries])
    end

    it 'does not claim an ordinary attribute reader is batched' do
      issue = described_class.sections.find { |s| s.klass == 'IssueDrop' }

      expect(issue.accessors.find { |a| a.name == 'subject' }.batch?).to be(false)
    end
  end

  describe 'the copyable snippet' do
    it 'is the accessor on the variable an author actually has' do
      issue = described_class.sections.find { |s| s.klass == 'IssueDrop' }
      subject_accessor = issue.accessors.find { |a| a.name == 'subject' }

      expect(subject_accessor.snippet(issue.variable)).to eq('{{ issue.subject }}')
    end

    # A BRACKET LOOKUP IS NOT A METHOD CALL. `{{ issue.custom_field_values }}` renders the
    # drop's `to_s` and teaches nothing; the form an author needs is the one with the id in
    # it, and printing the wrong one is a snippet that "does not work" for no visible reason.
    it 'uses the bracket form for a lookup' do
      issue = described_class.sections.find { |s| s.klass == 'IssueDrop' }
      lookup = issue.accessors.find { |a| a.name == 'custom_field_values' }

      expect(lookup.snippet('issue')).to eq('{{ issue.custom_field_values[42] }}')
    end

    it 'gives every section a variable, so no snippet reads `{{ .subject }}`' do
      expect(described_class.sections.map(&:variable)).to all(match(/\A[a-z_.]+\z/))
    end
  end

  describe 'the generated Markdown' do
    let(:markdown) { described_class.markdown }

    it 'marks itself as generated and names the command that writes it' do
      expect(markdown).to include('GENERATED')
      expect(markdown).to include('rake reporter_dashboards:drop_reference')
    end

    it 'has a heading per drop, in the declared order' do
      headings = markdown.scan(/^## (\w+)$/).flatten

      expect(headings).to eq(described_class::DECLARED.keys)
    end

    it 'carries every accessor of every section' do
      described_class.sections.each do |section|
        section.accessors.each do |accessor|
          expect(markdown).to include("`#{accessor.name}`"), "#{section.klass}##{accessor.name}"
        end
      end
    end

    it 'says where each drop is reached from, so a reader knows what they can type' do
      expect(markdown.scan(/^Reached from: /).length).to eq(described_class::DECLARED.length)
    end

    it 'ends in exactly one newline, so a regeneration is not a whitespace diff' do
      expect(markdown).to end_with("\n")
      expect(markdown).not_to end_with("\n\n")
    end

    # IT IS THE SAME TEXT EVERY TIME. The gate compares the committed file with a fresh
    # generation, so a generator that ordered a Hash differently on a second run would fail
    # the build with no change in the tree.
    it 'is deterministic' do
      expect(described_class.markdown).to eq(markdown)
    end

    # THE COMMITTED FILE IS PART OF THE SUITE, not only of the gate. G9's rule for the
    # support matrix applied one artefact along: a generated file that is committed must be
    # regenerated in the same change, or the file and the code are two answers to one
    # question and the reader has no way to tell which is current.
    #
    # It is asserted HERE as well as in `script/gates/drop_reference_parity.sh` on purpose.
    # The gate needs the Liquid gem and the `gates` CI job installs none, so the four-branch
    # `rspec` job is where this actually runs on every push — and a red example names the
    # command to run, which a reviewer reads faster than a gate log.
    it 'matches the committed docs/drop-reference.md' do
      committed = File.read(File.expand_path('../docs/drop-reference.md', __dir__),
                            encoding: 'UTF-8')

      expect(committed).to eq(markdown),
                           'docs/drop-reference.md is stale. Run ' \
                           '`rake reporter_dashboards:drop_reference` and commit it in this change.'
    end

    # A `<` outside a code span is an HTML tag to every Markdown renderer, so `an <a>
    # element` renders as `an  element` — the one word the note is about disappears. The
    # notes put it in backticks; this is what holds them to it, and it checks the WHOLE
    # document with the code spans removed rather than looking for one known offender.
    it 'writes no raw HTML that a Markdown reader would swallow' do
      prose = markdown.gsub(/`[^`\n]*`/, '').gsub(/^<!--.*?-->$/m, '')

      expect(prose).not_to match(/<[a-zA-Z]/)
    end
  end
end
