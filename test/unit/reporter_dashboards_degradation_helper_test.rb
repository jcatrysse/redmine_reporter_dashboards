# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# §Findings E-25 — THE DEGRADATION LIST TOOK TWO VOCABULARIES AND UNDERSTOOD ONE.
#
# `ReportRun::Outcome#degradations` is
#
#     diagnostics.degradations + bound.degradations + batch.successes.flat_map(&:degradations)
#
# and those are TWO CLASSES, deliberately: `Liquid::Diagnostics::Degradation`
# (`code`/`detail`/`data`/`count`) and `Render::Degradation` (`capability`/`detail`).
# `diagnostics.rb` argues at length that they must not be merged — *"the collection was
# truncated" and "the browser could not fetch a font" are fixed by different people*.
#
# `reporter_degradation_text` read `#code`, `#data` and `#count` off both, and
# `Render::Degradation` has none of the three. Its rescue lists
# `I18n::MissingInterpolationArgument` and `ArgumentError`, so the `NoMethodError` escaped
# the helper and the view — and `_degradations.html.erb` is rendered UNCONDITIONALLY by
# both `show` and `preview`, so **every wkhtmltopdf render 500'd the page**: that adapter
# stamps `Degradation(:legacy_engine)` into every `Success` by design, which the partial's
# own comment says it renders.
#
# Pre-existing, latent since T-31 put the localisation in, and reachable a second way as
# soon as F-16 started producing asset degradations on the same path.
#
# --- MINITEST TRAP (HANDOVER §1) ---
#
# There is no `private` section in this file, so nothing can be silently unrun.
class ReporterDashboardsDegradationHelperTest < ActionView::TestCase
  include ReporterDashboards::TemplatesHelper
  # `l` comes from here and NOT from `ActionView::TestCase` (§Findings E-21: two of T-33's
  # tests errored for exactly this reason and had never asserted anything).
  include Redmine::I18n

  Liquid = RedmineReporterDashboards::Liquid
  Render = RedmineReporterDashboards::Render

  # --- the render vocabulary, which used to raise -----------------------------------

  def test_a_render_degradation_renders_instead_of_raising
    degradation = Render::Degradation.new(capability: :legacy_engine,
                                          detail: 'drawn by a legacy engine')

    assert_equal 'legacy_engine: drawn by a legacy engine',
                 reporter_degradation_text(degradation)
  end

  # THE REGRESSION, NAMED. This is the object wkhtmltopdf puts in every Success, and the
  # exact call the view makes. Before the fix it raised `NoMethodError: undefined method
  # 'code'` — asserted as "does not raise" rather than by equality, because the wording is
  # not the claim.
  def test_the_exact_object_wkhtmltopdf_stamps_does_not_raise_in_the_view_helper
    degradation = Render::Degradation.new(capability: :legacy_engine)

    assert_nothing_raised { reporter_degradation_text(degradation) }
  end

  # A `Render::Degradation` is not deduplicated, so it is one occurrence and must not be
  # decorated with a count. `(1x)` after every engine degradation would be noise that reads
  # like a number somebody chose.
  def test_a_render_degradation_carries_no_occurrence_count
    text = reporter_degradation_text(Render::Degradation.new(capability: :legacy_engine))

    assert_not_includes text, '1x'
  end

  # THE NAME IS READ FROM `capability`, so a render degradation gets a localised sentence
  # by the same mechanism the Liquid ones do the day somebody writes the key. Proven by
  # planting the key rather than by reading the method.
  def test_a_render_degradation_uses_its_capability_as_the_locale_key
    with_locale_key('text_reporter_degradation_legacy_engine' => 'Drawn by an older engine') do
      text = reporter_degradation_text(Render::Degradation.new(capability: :legacy_engine))

      assert_equal 'Drawn by an older engine', text
    end
  end

  # --- the Liquid vocabulary, which must be unchanged ---------------------------------

  def test_a_liquid_degradation_still_falls_back_to_its_raw_to_s
    degradation = Liquid::Diagnostics::Degradation.new(code: :unbounded_collection,
                                                       detail: 'the collection was capped')

    assert_equal 'unbounded_collection: the collection was capped',
                 reporter_degradation_text(degradation)
  end

  # AN INVENTED CODE, and deliberately. The first version planted a key over
  # `aggregation_dimension_unknown`, which this plugin already ships — the shipped value
  # won and the example failed against a sentence nobody wrote here. A plant that competes
  # with a real translation tests the backend's precedence rules, not the helper.
  def test_a_liquid_degradation_still_interpolates_its_data_into_the_key
    with_locale_key('text_reporter_degradation_rrd_probe' => 'Unknown dimension %{group_by}') do
      degradation = Liquid::Diagnostics::Degradation.new(
        code: :rrd_probe, data: { group_by: 'activty' }
      )

      assert_equal 'Unknown dimension activty', reporter_degradation_text(degradation)
    end
  end

  # AND THE SHIPPED KEYS STILL WIN, which is what the eight `aggregation_*` sentences T-31
  # added are for. Asserted against a real one rather than a plant, because the plant above
  # cannot see a regression that removed the lookup entirely.
  def test_a_shipped_liquid_key_is_still_used_in_preference_to_the_raw_to_s
    degradation = Liquid::Diagnostics::Degradation.new(
      code: :aggregation_dimension_unknown, data: { group_by: 'activty' }
    )

    text = reporter_degradation_text(degradation)

    assert_includes text, 'activty'
    assert_not_includes text, 'aggregation_dimension_unknown',
                        'a shipped key must replace the raw `to_s`, not sit beside it'
  end

  def test_a_liquid_degradation_still_reports_its_occurrence_count
    degradation = Liquid::Diagnostics::Degradation.new(code: :unbounded_collection,
                                                       detail: 'capped', count: 4)

    assert_includes reporter_degradation_text(degradation), '(4x)'
  end

  # --- the two together, which is the shape the outcome actually has -------------------

  # THE MIXED LIST IS THE REAL CASE and neither example above covers it: a run with an
  # unresolved asset AND a legacy engine produces one of each, and the view iterates them
  # in one loop.
  def test_a_mixed_list_renders_every_entry
    list = [Liquid::Diagnostics::Degradation.new(code: :unbounded_collection, detail: 'capped'),
            Render::Degradation.new(capability: :asset_srcset_collapsed, detail: 'dropped 1')]

    rendered = list.map { |entry| reporter_degradation_text(entry) }

    assert_equal ['unbounded_collection: capped', 'asset_srcset_collapsed: dropped 1'],
                 rendered
  end

  # --- the diagnostic headline, whose `else` used to mean "engine" ---------------------

  # F-16 added a fourth origin, and the helper's `case`/`else` would have headlined it
  # *"The render engine could not produce this document"* — a remedy pointing at a binary
  # that was never started. Every origin is walked, so a fifth cannot be added silently.
  def test_every_diagnostic_origin_has_its_own_headline
    headlines = RedmineReporterDashboards::Reporting::Diagnostic::ORIGINS.to_h do |origin|
      diagnostic = RedmineReporterDashboards::Reporting::Diagnostic.new(
        origin: origin, code: :internal, message: 'm', correlation_id: 'c'
      )
      [origin, reporter_diagnostic_headline(diagnostic)]
    end

    assert_equal RedmineReporterDashboards::Reporting::Diagnostic::ORIGINS.length,
                 headlines.values.uniq.length,
                 "each origin needs its own sentence, got #{headlines.inspect}"
    headlines.each_value do |sentence|
      assert_not_includes sentence, 'translation missing', 'a locale key is absent'
    end
  end

  def test_the_assets_headline_does_not_blame_the_engine
    diagnostic = RedmineReporterDashboards::Reporting::Diagnostic.new(
      origin: :assets, code: :asset_unresolved, message: 'm', correlation_id: 'c'
    )

    assert_equal l(:label_reporter_report_failed_assets),
                 reporter_diagnostic_headline(diagnostic)
    assert_not_equal l(:label_reporter_report_failed_engine),
                     reporter_diagnostic_headline(diagnostic)
  end

  # A key added to `ORIGIN_LABEL_KEYS` without nine translations is a Russian operator
  # reading English, which CLAUDE.md §10 forbids and which no other test here would see.
  def test_every_origin_headline_is_translated_in_every_shipped_locale
    keys = RedmineReporterDashboards::Reporting::Diagnostic::ORIGIN_LABEL_KEYS.values

    %w[de en es hu it pl pt-BR ru zh].each do |locale|
      keys.each do |key|
        value = ::I18n.t(key, locale: locale, default: '')
        assert value.to_s.strip.present?, "#{key} is missing from #{locale}.yml"
      end
    end
  end

  def with_locale_key(pairs)
    ::I18n.backend.store_translations(::I18n.locale, pairs)
    yield
  ensure
    ::I18n.backend.reload!
  end
end
