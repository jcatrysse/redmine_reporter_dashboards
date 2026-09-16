# frozen_string_literal: true

require_relative '../lib/redmine_reporter_dashboards/liquid/tags/mermaid_tag'

# T-42 — EVERY SHIPPED TEMPLATE PARSES, AND THE LIQUID MAJOR IS THE SUBJECT.
#
# §Findings **M-3**: `starters/aggregate-report.liquid` and `starters/version-status.liquid`
# did not parse on Liquid 4.0.4. Saved unmodified from the gallery they rendered as
# *"this template has a syntax error and was not rendered"*, and the cause was PROSE — both
# header comments quoted a `{% for … %}` as an example of the idiom they replace. Liquid 4's
# `Comment` is a `Block` that still TOKENISES its body, so a block tag inside a comment opens
# a block that then meets `{% endcomment %}`. Liquid 5 stopped reading comment bodies, so the
# same two files are fine there.
#
# --- WHY THIS FILE EXISTS WHEN A TEST ALREADY CAUGHT IT ---
#
# `test/unit/reporter_dashboards_gallery_rake_test.rb` DID catch it, first run, with the
# exact Liquid message. It shipped anyway, because **nothing in CI has ever resolved Liquid
# 4**: `Gemfile` admits `>= 4.0, < 6.0` on purpose — *"an install that already has reporter
# has 4.x and must not be forced to upgrade"* — and every job takes what the lockfile gives
# it, which is 5.x.
#
# So the gap was never a missing assertion. **It was a missing axis**, and this directory is
# the one mechanism in the repository that already runs against both majors (see
# `README.md`, and `ci.yml`'s `liquid-majors` job, which pins 4.0.4 and `~> 5.0` in turn).
# Putting the check anywhere else would be a second way to do something that has a way.
#
# --- WHY STAND-IN TAGS ---
#
# Parsing is the only thing that differs between the majors here, and a parser needs to know
# a tag's NAME and whether it is a block — not what it does. Registering stand-ins keeps this
# spec out of `Rails.logger`, `Redmine::I18n` and the aggregation kernel, none of which this
# question touches. A stand-in cannot mask a parse error in a template: it is the template's
# own syntax that is on trial.
#
# `mermaid` is the exception and uses the real class, because it is the one BLOCK tag the
# plugin ships and `{% mermaid %}…{% endmermaid %}` only parses if the parser is told so.
#
# NAMESPACED, because a constant assigned inside `RSpec.describe` lands on `Object` — and
# `PLUGIN_ROOT`, `SHIPPED`, `BLOCK_TAGS` and `StandInTag` were all exactly that until an
# independent review pointed at them. `spec/frame_auto_height_spec.rb` carries the header
# about this trap; this file is another that has to obey it.
module ShippedTemplateParseSupport
  PLUGIN_ROOT = File.expand_path('..', __dir__)

  # Both directories ship, and an author copies from either: `starters/` is offered on the
  # New template page, `examples/` is the README's record of the old idiom.
  SHIPPED = (Dir[File.join(PLUGIN_ROOT, 'starters', '*.liquid')] +
             Dir[File.join(PLUGIN_ROOT, 'examples', '*.liquid')]).sort.freeze

  # Liquid's own block tags. A SIMPLE tag inside a comment is harmless — `Comment#unknown_tag`
  # ignores it — so listing only the block ones is the difference between a rule an author can
  # follow and one that forbids naming the plugin's tags in its own documentation.
  BLOCK_TAGS = %w[for if unless case capture tablerow raw comment ifchanged].freeze

  # A tag that parses and renders nothing. `Liquid::Tag` is the simple-tag base on both
  # majors; the render entry point differs between them (§`mermaid_tag_spec.rb`) and is not
  # exercised here, because nothing in this file renders.
  class StandInTag < Liquid::Tag; end

  def self.plugin_tag_names
    source = File.read(File.join(PLUGIN_ROOT, 'lib', 'redmine_reporter_dashboards.rb'),
                       encoding: 'UTF-8')
    constants = source.scan(/^\s*(\w*TAG\w*(?:NAME|ALIAS))\s*=\s*'([^']+)'/).to_h { |k, v| [k, v] }
    constants.values.sort
  end
end

RSpec.describe 'every shipped template' do
  # THE REGISTRY IS PROCESS-WIDE AND IS PUT BACK, which is the difference between a spec and
  # a spec that breaks the four files after it.
  #
  # `Liquid::Template.register_tag` writes one global table. `spec_liquid` runs as a single
  # rspec process under `config.order = :random`, so without this `after` every file that
  # loaded later saw `sql_aggregate`, `version_rollup` and `chart` as `StandInTag` — and in
  # `template_renderer_spec.rb`'s `:strict` examples, whether a tag is KNOWN is the thing
  # being asserted. The other four files in this directory avoid the problem by registering
  # under `rrd_spec_`-prefixed names; this one cannot, because the names are exactly what is
  # on trial. So it snapshots and restores instead. CLAUDE.md §6: never depend on another
  # test having run, or on the order they run in. Found by an independent review.
  # `Liquid::Template.tags` IS NOT A HASH. It is a `TagRegistry` on both majors, with
  # `[]`, `[]=`, `delete` and `each` and nothing else — measured on 4.0.4 and 5.5.1, after a
  # first version of this hook called `.dup` and `.replace` on it and died with a
  # `NoMethodError` in the `ensure`, which turned one restore into four red examples. So the
  # snapshot is per NAME: what each name mapped to before, `nil` included, and `delete` is
  # what puts a name that did not exist back to not existing.
  around do |example|
    touched = ShippedTemplateParseSupport.plugin_tag_names
    before = touched.to_h { |name| [name, Liquid::Template.tags[name]] }

    touched.each do |name|
      next if name == 'mermaid'

      Liquid::Template.register_tag(name, ShippedTemplateParseSupport::StandInTag)
    end
    Liquid::Template.register_tag(
      'mermaid', RedmineReporterDashboards::Liquid::Tags::MermaidTag
    )

    begin
      example.run
    ensure
      before.each do |name, previous|
        if previous
          Liquid::Template.register_tag(name, previous)
        else
          Liquid::Template.tags.delete(name)
        end
      end
    end
  end

  # A NON-EMPTY SUBJECT IS AN ASSERTION, not an assumption. T-37 shipped a spec whose glob
  # resolved to nothing and whose emptiness assertion therefore passed vacuously for a whole
  # release; the same shape here would report "every shipped template parses" about none.
  it 'is a real set of files, and the tag names come from the plugin rather than this file' do
    expect(ShippedTemplateParseSupport::SHIPPED.count { |path| path.include?('/starters/') }).to eq(5)
    expect(ShippedTemplateParseSupport::SHIPPED.length).to be >= 5

    names = ShippedTemplateParseSupport.plugin_tag_names
    expect(names).to include('sql_aggregate', 'version_rollup', 'chart', 'mermaid')
    expect(names.length).to be >= 5
  end

  it "parses on Liquid #{Liquid::VERSION}" do
    failures = ShippedTemplateParseSupport::SHIPPED.filter_map do |path|
      begin
        Liquid::Template.parse(File.read(path, encoding: 'UTF-8'))
        nil
      rescue Liquid::SyntaxError => e
        "#{path.sub("#{ShippedTemplateParseSupport::PLUGIN_ROOT}/", '')}: #{e.message}"
      end
    end

    expect(failures).to be_empty,
                        -> { "on Liquid #{Liquid::VERSION}:\n  #{failures.join("\n  ")}" }
  end

  # THE PLANTED FAILURE. Without it this file proves only that the check runs, not that it
  # can say no — and "the check was broken so everything passed" is a failure mode this
  # repository has shipped more than once (T-38's gate reported OK while reading nothing).
  # The planted body is M-3's exact shape, so what is proven is that THIS defect is caught.
  it 'catches a block tag inside a comment, which is what M-3 was' do
    planted = "{% comment %}\n A {% for issue in issues %} loop.\n{% endcomment %}\n<p>b</p>\n"

    if Liquid::VERSION.start_with?('4.')
      expect { Liquid::Template.parse(planted) }
        .to raise_error(Liquid::SyntaxError, /endcomment|endfor/)
    else
      # NOT A SKIP. The majors genuinely differ here and recording the difference is what
      # stops a later session "fixing" the corrected starters back to the broken spelling.
      expect { Liquid::Template.parse(planted) }.not_to raise_error
    end
  end

  # The rule the two corrected starters now follow, asserted on the files rather than left to
  # a comment inside them — CLAUDE.md §5's "a control specified as mechanical and implemented
  # as a comment". This one holds on BOTH majors, which is the point: it is the portable rule.
  it 'writes no block tag inside a comment, on either major' do
    offenders = ShippedTemplateParseSupport::SHIPPED.flat_map do |path|
      body = File.read(path, encoding: 'UTF-8')
      body.scan(/\{%\s*comment\s*%\}(.*?)\{%\s*endcomment\s*%\}/m)
          .flat_map { |(inner)| inner.scan(/\{%-?\s*(\w+)/).flatten }
          .select { |tag| ShippedTemplateParseSupport::BLOCK_TAGS.include?(tag) }
          .map { |tag| "#{path.sub("#{ShippedTemplateParseSupport::PLUGIN_ROOT}/", '')}: {% #{tag} %}" }
    end

    expect(offenders).to be_empty, -> { offenders.join("\n  ") }
  end
end
