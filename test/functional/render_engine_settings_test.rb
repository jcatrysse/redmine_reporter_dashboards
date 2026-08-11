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
    # GENERATED, NOT HAND-LISTED (§5.2 clause 4). The install sentence is the catalogue's
    # own text, so if the file changes the page changes and this assertion follows it.
    assert_includes response.body, ERB::Util.html_escape(catalogue['gotenberg'].install)
    assert_includes response.body, ERB::Util.html_escape(catalogue['wkhtmltopdf'].label)
    # And what it CANNOT do, computed from the closed vocabulary rather than written down.
    assert_includes response.body, ':asset_upload'
  end

  def test_the_partial_uses_locale_keys_and_not_hardcoded_english
    get :plugin, params: { id: PLUGIN_ID }

    assert_response :success
    assert_select 'label', text: l(:label_reporter_render_engine)
    assert_not_includes response.body, 'translation missing'
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
