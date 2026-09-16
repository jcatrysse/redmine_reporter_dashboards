# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# T-33 — the asset-policy settings surface.
#
# --- WHAT THIS IS ACTUALLY FOR ---
#
# `Assets::Policy` has 23 DB-less examples and they cover the three values, the fail-closed
# collapse and FR-15's coercion. Nothing here re-tests those. What only a functional test can
# reach is the part that is about being a Redmine settings page:
#
#   * that the partial's field names ROUND-TRIP. Redmine's settings controller does
#     `Setting.send("plugin_#{id}=", params[:settings])`, so a field named
#     `settings[asset_policy]` reaches `Setting.plugin_redmine_reporter_dashboards['asset_policy']`
#     and any other spelling silently saves nothing. That is not checkable from a spec, and it is
#     the single most likely way this feature ships broken.
#   * that the partial RENDERS at all, on this Redmine branch, with this branch's helpers.
#     `ruby -c` plus an ERB compile — which is all a local run can do here — proves neither.
#   * that only an administrator can reach it, which is Redmine's own guard and therefore exactly
#     the kind of thing that is assumed rather than asserted.
#
# --- WHY IT MATTERS THAT THE DEFAULT IS RESTORED ---
#
# `Setting.plugin_*` is process-global and Redmine caches it. A test that leaves
# `asset_policy: 'external'` behind hands the next test in the process an install with egress
# enabled, and every assertion about the default still passes because each is about one setting at
# a time. HANDOVER §1 records the same shape twice — the registry reset with no restore, and the
# fixture built on the absence of rows. So the value is saved and put back in `teardown`.
class AssetPolicySettingsTest < ActionController::TestCase
  # NOT T-22's, and fixed here because this session is the first to RUN this file.
  #
  # Two of its tests call `l(...)` and the class did not include the module that defines it,
  # so both errored with `NoMethodError: undefined method 'l'` — meaning that since T-33
  # landed, `test_the_partial_uses_locale_keys_and_not_hardcoded_english` has asserted
  # nothing at all. `docs/plan/HANDOVER.md` records that T-33's Minitest half had never been
  # executed anywhere; this is what it was hiding. §Findings E-21.
  include Redmine::I18n

  tests SettingsController

  fixtures :users, :email_addresses, :roles

  PLUGIN_ID = 'redmine_reporter_dashboards'
  Assets = RedmineReporterDashboards::Assets

  def setup
    @original = Setting.send(:"plugin_#{PLUGIN_ID}")
    @request.session[:user_id] = 1 # admin
  end

  def teardown
    Setting.send(:"plugin_#{PLUGIN_ID}=", @original)
  end

  # ------------------------------------------------------------------
  # The plugin is registered with a settings block at all.
  def test_the_plugin_declares_settings_and_a_partial
    plugin = Redmine::Plugin.find(PLUGIN_ID)

    assert plugin.configurable?,
           'the plugin has no settings block, so Administration -> Plugins shows no Configure link'
    assert_equal 'settings/reporter_dashboards', plugin.settings[:partial]
  end

  def test_the_declared_defaults_are_the_documented_ones
    plugin = Redmine::Plugin.find(PLUGIN_ID)
    defaults = plugin.settings[:default]

    assert_equal 'bundled', defaults['asset_policy'],
                 'the default must be the no-egress one (FR-64)'
    assert_equal '', defaults['asset_allowlist']
    assert_equal Assets::Policy::DEFAULT_INLINE_MAX_BYTES.to_s, defaults['inline_max_bytes']
    assert_equal Assets::Policy::DEFAULT_ASSET_MAX_BYTES.to_s, defaults['asset_max_bytes']
  end

  # A fresh install, with nothing ever saved, must read as `:bundled`.
  def test_a_fresh_install_reads_as_bundled
    policy = RedmineReporterDashboards.asset_policy

    assert_equal :bundled, policy.effective_mode
    assert_predicate policy, :bundled?
    refute policy.may_fetch?(:third_party)
  end

  # ------------------------------------------------------------------
  def test_the_partial_renders_for_an_administrator
    get :plugin, params: { id: PLUGIN_ID }

    assert_response :success
    assert_select 'select#settings_asset_policy'
    assert_select 'textarea#settings_asset_allowlist'
    assert_select 'input#settings_inline_max_bytes'
    assert_select 'input#settings_asset_max_bytes'
  end

  def test_the_partial_uses_locale_keys_and_not_hardcoded_english
    get :plugin, params: { id: PLUGIN_ID }

    assert_response :success
    assert_select 'label', text: l(:label_reporter_asset_policy)
    # A missing key renders as "Translation missing: …", which reads as a broken page in
    # every locale but English and is invisible in English.
    # CASE-INSENSITIVE SINCE 2026-08-11, AND A MUTATION RUN IS WHY. This assertion has been vacuous
    # since T-33 shipped it. Rails renders a missing key as
    # **"Translation missing: en.…"** with a capital T (measured on Rails 7.2), so
    # `assert_not_includes response.body, 'translation missing'` never matches and the
    # control is vacuous: deleting a key this page uses left this test GREEN. The regexp is
    # case-insensitive rather than capitalised because the casing is Rails', not ours, and
    # this plugin spans three Rails majors.
    assert_no_match(/translation missing/i, response.body)
  end

  def test_a_non_admin_cannot_reach_it
    @request.session[:user_id] = 2 # jsmith, not an administrator

    get :plugin, params: { id: PLUGIN_ID }

    assert_response :forbidden
  end

  def test_an_anonymous_visitor_cannot_reach_it
    @request.session[:user_id] = nil

    get :plugin, params: { id: PLUGIN_ID }

    assert_response :redirect
  end

  # ------------------------------------------------------------------
  # THE ROUND TRIP. This is the assertion the whole file exists for.
  def test_saving_the_form_reaches_the_policy_the_resolver_reads
    post :plugin, params: {
      id: PLUGIN_ID,
      settings: { 'asset_policy' => 'external',
                  'asset_allowlist' => "cdn.example\nfonts.example",
                  'inline_max_bytes' => '2048',
                  'asset_max_bytes' => '4096' }
    }

    assert_response :redirect

    policy = RedmineReporterDashboards.asset_policy
    assert_equal :external, policy.mode
    assert_equal %w[cdn.example fonts.example], policy.allowlist
    assert_equal 2048, policy.inline_max_bytes
    assert_equal 4096, policy.asset_max_bytes
    assert policy.fetch_allowed?(:third_party, 'cdn.example')
    refute policy.fetch_allowed?(:third_party, 'other.example')
  end

  def test_an_out_of_range_value_is_dropped_rather_than_stored
    post :plugin, params: {
      id: PLUGIN_ID,
      settings: { 'asset_policy' => 'nonsense',
                  'asset_allowlist' => "*.example.com\ncdn.example",
                  'inline_max_bytes' => 'lots' }
    }

    assert_response :redirect

    policy = RedmineReporterDashboards.asset_policy
    assert_equal :bundled, policy.mode, 'an unknown mode must fall back to the safe one'
    assert_equal %w[cdn.example], policy.allowlist, 'a pattern is not a host'
    assert_equal Assets::Policy::DEFAULT_INLINE_MAX_BYTES, policy.inline_max_bytes
    assert_equal 3, policy.dropped.length
  end

  def test_the_page_says_so_when_an_empty_allowlist_collapses_the_mode
    Setting.send(:"plugin_#{PLUGIN_ID}=",
                 @original.merge('asset_policy' => 'external', 'asset_allowlist' => ''))

    get :plugin, params: { id: PLUGIN_ID }

    assert_response :success
    # §5.1's fail-closed rule is correct and invisible. An administrator who selected
    # "external" and saved would otherwise see their own choice in the dropdown and conclude
    # egress was on.
    assert_select 'div.warning', text: /#{Regexp.escape(l(:label_reporter_asset_policy_external))}/
  end

  def test_the_page_lists_a_value_it_had_to_drop
    Setting.send(:"plugin_#{PLUGIN_ID}=", @original.merge('inline_max_bytes' => '-1'))

    get :plugin, params: { id: PLUGIN_ID }

    assert_response :success
    assert_select 'div.warning li', text: /inline_max_bytes/
  end

  # A rejected entry must still be in the field, or the operator reloads, sees a tidy list, and
  # never connects it to the warning.
  def test_a_rejected_allowlist_entry_stays_in_the_textarea
    Setting.send(:"plugin_#{PLUGIN_ID}=",
                 @original.merge('asset_policy' => 'external',
                                 'asset_allowlist' => "*.example.com\ncdn.example"))

    get :plugin, params: { id: PLUGIN_ID }

    assert_response :success
    assert_select 'textarea#settings_asset_allowlist', text: /\*\.example\.com/
  end

  # ------------------------------------------------------------------
  # The other two Redmine reads this task added, exercised where `Setting` is real.
  def test_the_asset_origin_comes_from_redmines_own_two_settings
    with_settings host_name: 'redmine.example/sub', protocol: 'https' do
      origin = RedmineReporterDashboards.asset_origin

      assert_equal 'redmine.example', origin.host
      assert_equal 443, origin.port
      assert_equal '/sub', origin.prefix
      assert origin.same?('redmine.example', 443)
      refute origin.same?('other.example', 443)
    end
  end

  def test_the_asset_store_reads_the_plugins_own_vendored_files
    store = RedmineReporterDashboards.asset_store
    path = "#{Assets::BundledAssets::URL_PREFIX}/javascripts/" \
           "#{RedmineReporterDashboards::Charts::CHARTJS_ASSET}"

    found = store.file_for(path, usage: :script)

    assert_not_nil found, 'the vendored Chart.js is not readable through the production store'
    assert_equal 'text/javascript', found.content_type
    assert_equal RedmineReporterDashboards::Charts::CHARTJS_SHA256,
                 Digest::SHA256.hexdigest(found.bytes),
                 'the file the resolver would inline is not the one THIRD_PARTY.md records'
  end
end
