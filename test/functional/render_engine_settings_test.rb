# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# FR-50 — the install-wide engine selection, where it is a Redmine settings page.
#
# --- WHAT ONLY A FUNCTIONAL TEST CAN REACH ---
#
# `Render::EnginePreference` has its own DB-less examples and they cover the coercion table,
# the offered set and the precedence inputs. Nothing here re-tests those. What only this can
# reach is the part that is about being a settings page, and it is the same three things
# `asset_policy_settings_test.rb` exists for:
#
#   * the field name ROUND-TRIPS. Redmine's settings controller does
#     `Setting.send("plugin_#{id}=", params[:settings])`, so `settings[render_engine]` has to
#     reach `Setting.plugin_redmine_reporter_dashboards['render_engine']` and thence
#     `RedmineReporterDashboards.render_engine_id`. Any other spelling silently saves
#     nothing, and that is the single most likely way this feature ships broken.
#   * the partial RENDERS, on this Redmine branch, with this branch's helpers — and this one
#     matters more than usual, because Redmine sets `include_all_helpers = false` and the
#     partial is rendered by Redmine's OWN controller. A plugin helper would resolve in a
#     controller test of OUR controller and 500 here (HANDOVER §1's `sprite_icon` entry). The
#     partial therefore has no helper of its own, and this is what proves it.
#   * only an administrator can reach it, which is Redmine's guard and therefore exactly the
#     kind of thing that gets assumed rather than asserted.
#
# The setting is restored in `teardown` for the reason the asset test states: `Setting.plugin_*`
# is process-global and Redmine caches it, so a test that leaves `render_engine` set hands the
# next test an install that renders through somebody else's engine.
class RenderEngineSettingsTest < ActionController::TestCase
  include Redmine::I18n

  tests SettingsController

  fixtures :users, :email_addresses, :roles

  PLUGIN_ID = 'redmine_reporter_dashboards'
  Render = RedmineReporterDashboards::Render

  def setup
    @original = Setting.send(:"plugin_#{PLUGIN_ID}")
    @request.session[:user_id] = 1 # admin
  end

  def teardown
    Setting.send(:"plugin_#{PLUGIN_ID}=", @original)
  end

  # ------------------------------------------------------------------
  def test_the_declared_default_is_no_preference
    defaults = Redmine::Plugin.find(PLUGIN_ID).settings[:default]

    assert_equal Render::EnginePreference::NO_PREFERENCE, defaults['render_engine'],
                 'a fresh install must have chosen nothing, so the declared default renders'
  end

  def test_a_fresh_install_renders_with_the_declared_default
    assert_nil RedmineReporterDashboards.render_engine_id
    assert_equal 'chromium_cdp', RedmineReporterDashboards.render_engine_preference.effective_id
  end

  # ------------------------------------------------------------------
  def test_the_partial_renders_the_selector_for_an_administrator
    get :plugin, params: { id: PLUGIN_ID }

    assert_response :success
    assert_select 'select#settings_render_engine' do
      # THE OPTIONS COME OFF THE REGISTRY. Asserting the three that are registered is half
      # of it; the other half is that nothing else is offered, because "every dropdown comes
      # off the registry, nothing off input" is the property, not "the dropdown has three
      # entries".
      assert_select 'option[value=?]', 'chromium_cdp'
      assert_select 'option[value=?]', 'gotenberg'
      assert_select 'option[value=?]', 'wkhtmltopdf'
      assert_select 'option[value=?]', '', { count: 1 },
                    'the blank option is how an install says "use the declared default"'
      assert_select 'option', count: Render::Registry.ids.length + 1
    end
  end

  def test_the_partial_states_the_trade_per_engine_from_the_catalogue
    get :plugin, params: { id: PLUGIN_ID }

    assert_response :success
    catalogue = Render::EngineCatalogue.load
    # A TABLE, one row per engine — §9b.3's words, and the shape a UX review asked for after
    # measuring what a punctuation-in-the-markup list rendered as in German and Chinese.
    assert_select 'fieldset table.list tbody tr', count: Render::Registry.ids.length
    # GENERATED, NOT HAND-LISTED (§5.2 clause 4). Each of these is the catalogue's own text,
    # so if the file changes the page changes and this assertion follows it.
    assert_includes response.body, ERB::Util.html_escape(catalogue['gotenberg'].install)
    assert_includes response.body, ERB::Util.html_escape(catalogue['wkhtmltopdf'].label)
    # THE TRADE SENTENCE, which clause 4 names in as many words and the first version of
    # this view carried on the object and rendered nowhere.
    assert_includes response.body, ERB::Util.html_escape(catalogue['wkhtmltopdf'].trade)
    # What it cannot do, computed from the closed vocabulary rather than written down — and
    # NOT the three asset capabilities, which are reported as a model instead: telling an
    # administrator the recommended engine "cannot do :asset_http" reads as a deficiency
    # where INV-8 means it is the point.
    assert_includes response.body, ':modern_javascript'
    assert_not_includes response.body, ':asset_http'
    assert_select 'fieldset table.list tbody tr td', text: 'upload'
  end

  # THE DEGRADED STATE. `EnginePreference` survives an unreadable catalogue so that an
  # operator's explicit choice keeps rendering; the page must then say that it knows nothing
  # rather than printing a promise followed by three bare ids and no service warning.
  def test_the_page_says_so_when_the_catalogue_cannot_be_read
    Setting.send(:"plugin_#{PLUGIN_ID}=", @original.merge('render_engine' => 'gotenberg'))
    Render::EngineCatalogue.stubs(:load).raises(Render::EngineCatalogue::InvalidCatalogue, 'broken')

    get :plugin, params: { id: PLUGIN_ID }

    assert_response :success
    assert_select 'div.warning', text: /capabilities\.yml/
    # And the selection is still shown as chosen, because it still governs the render path.
    assert_select 'select#settings_render_engine option[selected][value=?]', 'gotenberg'
  end

  def test_the_partial_uses_locale_keys_and_not_hardcoded_english
    get :plugin, params: { id: PLUGIN_ID }

    assert_response :success
    assert_select 'label', text: l(:label_reporter_render_engine)
    # CASE-INSENSITIVE, AND A MUTATION RUN IS WHY. Rails renders a missing key as
    # **"Translation missing: en.…"** with a capital T (measured on Rails 7.2), so
    # `assert_not_includes response.body, 'translation missing'` never matches and the
    # control is vacuous: deleting a key this page uses left this test GREEN. The regexp is
    # case-insensitive rather than capitalised because the casing is Rails', not ours, and
    # this plugin spans three Rails majors.
    assert_no_match(/translation missing/i, response.body)
  end

  def test_a_non_admin_cannot_reach_it
    @request.session[:user_id] = 2 # jsmith

    get :plugin, params: { id: PLUGIN_ID }

    assert_response :forbidden
  end

  # ------------------------------------------------------------------
  # THE ROUND TRIP. This is the assertion the whole file exists for.
  def test_saving_the_form_reaches_the_engine_the_render_path_resolves
    post :plugin, params: { id: PLUGIN_ID, settings: { 'render_engine' => 'wkhtmltopdf' } }

    assert_response :redirect
    assert_equal 'wkhtmltopdf', RedmineReporterDashboards.render_engine_id
    assert_equal 'wkhtmltopdf', RedmineReporterDashboards.render_engine_preference.effective_id
  end

  def test_an_engine_that_needs_a_service_can_be_chosen_and_the_page_says_what_that_costs
    post :plugin, params: { id: PLUGIN_ID, settings: { 'render_engine' => 'gotenberg' } }
    assert_response :redirect
    assert_equal 'gotenberg', RedmineReporterDashboards.render_engine_id

    get :plugin, params: { id: PLUGIN_ID }

    assert_response :success
    # T-34's rule is that nobody may have gotenberg chosen FOR them. The other half is that
    # somebody who chooses it is told what they have taken on, HERE, rather than finding out
    # from a failed scheduled report at 04:17.
    assert_select 'div.warning', text: /#{Regexp.escape(l(:label_reporter_preflight))}/
  end

  def test_a_value_that_names_no_engine_is_dropped_rather_than_stored
    post :plugin, params: { id: PLUGIN_ID, settings: { 'render_engine' => 'chromium_cpd' } }

    assert_response :redirect
    assert_nil RedmineReporterDashboards.render_engine_id,
               'a typo must not become the engine every report on this install renders with'

    get :plugin, params: { id: PLUGIN_ID }

    assert_response :success
    # LISTED, because the dropdown will show the default and an operator would otherwise
    # conclude their choice was saved.
    assert_select 'div.warning li', text: /render_engine/
  end

  # AN EMPTY REGISTRY IS A REAL ANSWER AND THE MOST ALARMING ONE — nothing can render at
  # all. The preflight page says so; before a UX review measured it, this page printed an
  # introduction promising a comparison and then an empty list.
  def test_the_page_says_so_when_no_engine_is_registered
    Render::Registry.stubs(:ids).returns([])

    get :plugin, params: { id: PLUGIN_ID }

    assert_response :success
    assert_select 'p.nodata', text: l(:text_reporter_render_engine_none)
    assert_select 'table.list', count: 0
    # The dropdown still offers the declared default and nothing else.
    assert_select 'select#settings_render_engine option', count: 1
  end

  # AN ADAPTER ANOTHER PLUGIN REGISTERED. It is offered — being unknown to the catalogue is
  # not evidence of anything — and nothing is invented about it. Both markers are asserted
  # because the first version nested the unverified one inside "is it known", suppressing it
  # in exactly the state where nothing has been verified.
  def test_an_engine_the_catalogue_does_not_describe_is_offered_and_says_so
    Render::Registry.stubs(:ids).returns([:weasyprint])

    get :plugin, params: { id: PLUGIN_ID }

    assert_response :success
    assert_select 'select#settings_render_engine option[value=?]', 'weasyprint'
    assert_select 'table.list tbody tr td', text: /weasyprint/
    assert_includes response.body, l(:label_reporter_render_engine_undescribed)
    assert_includes response.body, l(:label_reporter_render_engine_unverified)
  end

  # THE OTHER END OF THE ROUND TRIP, and the only place it can be driven.
  #
  # `ReportRun`'s `engine_preference:` defaults to the `FROM_SETTINGS` sentinel, which resolves
  # through `RedmineReporterDashboards.render_engine_id` — a boot-file method. The DB-less
  # suite cannot load the boot file (that is why the port exists at all) and cannot stub the
  # method either, because `verify_partial_doubles` is on and rightly refuses to stub a method
  # that does not exist. So the sentinel's own resolution has exactly one honest home: here,
  # where `Setting` is real, the adapters are registered and the default argument is the one
  # production uses.
  #
  # Without this, deleting the sentinel's resolution — `engine_preference` returning
  # `@engine_preference` unconditionally — passes the entire rspec suite: every DB-less example
  # states the axis explicitly, by design.
  def test_a_run_with_no_explicit_preference_resolves_the_engine_the_setting_names
    Setting.send(:"plugin_#{PLUGIN_ID}=", @original.merge('render_engine' => 'wkhtmltopdf'))

    run = RedmineReporterDashboards::Reporting::ReportRun.new(
      template: RedmineReporterDashboards::Template.new(name: 'x', content: 'x'),
      actor: User.find(1), scope: nil, guard: Render::BatchGuard.new
    )

    assert_equal Render::Engines::Wkhtmltopdf, run.send(:resolve_engine),
                 'a run that was given no engine and no preference must follow the setting'

    Setting.send(:"plugin_#{PLUGIN_ID}=", @original.merge('render_engine' => ''))
    assert_equal Render::Engines::ChromiumCdp, run_with_no_preference.send(:resolve_engine),
                 'and with nothing selected it must follow the declared default'
  end

  # An id that is not in the registry cannot become an adapter whatever the form posts. This
  # is the FR-55 half of the same property: `Registry` is a closed map written in Ruby.
  def test_a_crafted_post_cannot_introduce_an_engine
    post :plugin, params: { id: PLUGIN_ID,
                            settings: { 'render_engine' => 'RedmineReporterDashboards' } }

    assert_response :redirect
    assert_nil RedmineReporterDashboards.render_engine_id
  end

  private

  def run_with_no_preference
    RedmineReporterDashboards::Reporting::ReportRun.new(
      template: RedmineReporterDashboards::Template.new(name: 'x', content: 'x'),
      actor: User.find(1), scope: nil, guard: Render::BatchGuard.new
    )
  end
end
