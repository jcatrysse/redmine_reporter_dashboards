# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# T-14 — the admin page.
#
# --- WHAT THIS IS ACTUALLY FOR ---
#
# `Render::Preflight` and `Render::PreflightCommand` have their own specs and they cover
# the checks and the exit codes. Nothing here re-tests those. What only a functional
# test can reach is the part that is about being a Redmine page: WHO may open it, what
# each HTTP verb does, and whether a broken engine produces a diagnostic or a 500.
#
# --- THE ENGINE IS ALWAYS A FAKE HERE ---
#
# The real adapters register themselves at boot, and this suite runs on a CI box with
# no browser. A test that let them through would either launch Chromium in a functional
# test or — worse — pass because it did not. `Registry.isolated` swaps the map and puts
# it back; `reset!` without the restore already caused one random-seed failure in this
# repository, which is why the isolating form exists.
class ReporterPreflightControllerTest < ActionController::TestCase
  tests ReporterPreflightController

  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules

  Render = RedmineReporterDashboards::Render

  # An adapter class, because that is what the Registry maps an id to and what the
  # controller news up. It renders nothing: every example here stubs the Preflight or
  # asserts on a failure, so no fake ever has to imitate a browser.
  class StubAdapter
    def id
      :stub
    end

    def version
      'stub-1'
    end

    def capabilities
      Render::Capabilities::ALL
    end

    def render(_request)
      Render::Success.new(bytes: "%PDF-1.4\n#{'x' * 2000}\n%%EOF\n", engine: :stub,
                          engine_version: 'stub-1')
    end
  end

  class UnstartableAdapter
    def initialize
      raise Errno::ENOENT, 'chromium'
    end
  end

  # Counts on the CLASS, because the controller constructs its own instance and the test
  # never sees it.
  class ClosingAdapter < StubAdapter
    class << self
      attr_accessor :shutdowns
    end
    self.shutdowns = 0

    def shutdown
      self.class.shutdowns += 1
    end
  end

  class BrokenShutdownAdapter < StubAdapter
    def shutdown
      raise IOError, 'the browser would not stop'
    end
  end

  def setup
    @admin = User.find_by!(login: 'admin')
    @user = User.find_by!(login: 'jsmith')
  end

  def with_engine(id, adapter)
    Render::Registry.isolated do
      Render::Registry.register(id, adapter)
      yield
    end
  end

  # ---- authorization, per action (G5) -------------------------------------
  #
  # Both actions, not "the admin layout implies it". An administrator-only diagnostic
  # that starts a subprocess is exactly the action where an inherited check is not good
  # enough.

  def test_show_redirects_an_anonymous_visitor_to_login
    get :show

    assert_response :redirect
    assert_match(/login/, response.redirect_url)
  end

  def test_show_is_forbidden_for_a_signed_in_non_admin
    @request.session[:user_id] = @user.id
    get :show

    assert_response :forbidden
  end

  def test_run_is_forbidden_for_a_signed_in_non_admin
    @request.session[:user_id] = @user.id
    post :run

    assert_response :forbidden
  end

  def test_run_redirects_an_anonymous_visitor_to_login
    post :run

    assert_response :redirect
    assert_match(/login/, response.redirect_url)
  end

  # A non-admin must not reach the engine even if authorization were to change shape:
  # the observable is that nothing was constructed at all.
  def test_a_non_admin_never_reaches_an_engine
    @request.session[:user_id] = @user.id

    with_engine(:stub, UnstartableAdapter) do
      post :run

      assert_response :forbidden
    end
  end

  # ---- what each verb does ------------------------------------------------

  def test_show_renders_the_page_and_runs_nothing
    @request.session[:user_id] = @admin.id

    # If GET ran anything, this adapter would raise on construction and the page would
    # show a failed check. It must show no results at all.
    with_engine(:stub, UnstartableAdapter) do
      get :show

      assert_response :success
      assert_nil assigns(:reports)
      assert_select 'form[action=?]', '/admin/reporter_dashboards/preflight'
    end
  end

  def test_post_runs_the_preflight_and_renders_a_row_per_check
    @request.session[:user_id] = @admin.id

    report = Render::Preflight::Report.new(
      engine_id: :stub, engine_version: 'stub-1', duration_ms: 12,
      checks: [Render::Preflight::Check.new(id: :engine, title: 't', state: :pass,
                                            detail: 'ok', duration_ms: 3),
               Render::Preflight::Check.new(id: :footer, title: 't', state: :fail,
                                            detail: 'no page number found', duration_ms: 4)]
    )
    Render::Preflight.any_instance.stubs(:run).returns(report)

    with_engine(:stub, StubAdapter) do
      post :run

      assert_response :success
      assert_equal 1, assigns(:reports).length
      assert_select 'table.list tbody tr', 2
      assert_select 'td', text: /no page number found/
    end
  end

  # THE MOST LIKELY REAL RESULT, and it must be a diagnostic rather than an error page.
  # An administrator on a box with no browser learns "the engine could not be started",
  # which is the answer; a 500 tells them the plugin is broken, which is not.
  def test_an_engine_that_cannot_start_is_a_failed_check_not_a_500
    @request.session[:user_id] = @admin.id

    with_engine(:stub, UnstartableAdapter) do
      post :run

      assert_response :success
      assert_equal 1, assigns(:reports).length
      assert_equal [:engine], assigns(:reports).first.checks.map(&:id)
      assert_equal :fail, assigns(:reports).first.checks.first.state
      assert_select 'td', text: /chromium/
    end
  end

  # A DIAGNOSTIC MUST NOT LEAK THE RESOURCE IT DIAGNOSES. A fresh adapter is constructed
  # per request and the Chromium one owns a process pool that starts a browser. Without
  # the controller's `ensure`, an administrator who clicks the button three times leaves
  # three browsers running for the lifetime of the web worker.
  def test_the_engine_is_shut_down_after_every_run
    @request.session[:user_id] = @admin.id
    ClosingAdapter.shutdowns = 0

    with_engine(:stub, ClosingAdapter) do
      post :run
      assert_response :success
      post :run
      assert_response :success
    end

    assert_equal 2, ClosingAdapter.shutdowns
  end

  # The report is already built by the time shutdown runs. Losing it to a cleanup error
  # would be the worst possible trade — the administrator gets a 500 instead of the
  # answer they asked for.
  def test_a_shutdown_that_raises_does_not_lose_the_report
    @request.session[:user_id] = @admin.id

    with_engine(:stub, BrokenShutdownAdapter) do
      post :run

      assert_response :success
      assert_equal 1, assigns(:reports).length
      assert_select 'table.list tbody tr'
    end
  end

  # ---- the engine selector (§Findings E-27 row 6) -------------------------
  #
  # Before this parameter existed, an engine that needs a service could not be diagnosed
  # from this page at all: the deferral always applied, and its remediation named a rake
  # variable — an instruction the one reader this page exists for has no shell to follow.

  def test_the_form_offers_the_default_set_and_every_registered_engine
    @request.session[:user_id] = @admin.id

    with_engine(:stub, StubAdapter) do
      get :show

      assert_response :success
      assert_select 'select#engine' do
        assert_select 'option', 2
        assert_select 'option[value=?]', '', text: I18n.t(:label_reporter_preflight_engine_default)
        assert_select 'option[value=?]', 'stub'
      end
    end
  end

  def test_naming_an_engine_runs_only_that_engine
    @request.session[:user_id] = @admin.id
    report = Render::Preflight::Report.new(
      engine_id: :stub, engine_version: 'stub-1', duration_ms: 12,
      checks: [Render::Preflight::Check.new(id: :engine, title: 't', state: :pass,
                                            detail: 'ok', duration_ms: 3)]
    )
    Render::Preflight.any_instance.stubs(:run).returns(report)

    Render::Registry.isolated do
      Render::Registry.register(:stub, StubAdapter)
      Render::Registry.register(:other, StubAdapter)

      post :run, params: { engine: 'stub' }

      assert_response :success
      assert_equal 1, assigns(:reports).length
    end
  end

  # The registry lookup is the validation. A hand-crafted POST naming an engine that does
  # not exist — or a value that names nothing at all — must be an error an administrator
  # can read, never a 500 and never a silent run of the default set (the row-8 sin one
  # surface up).
  def test_an_unknown_engine_name_is_an_error_message_not_a_500
    @request.session[:user_id] = @admin.id

    with_engine(:stub, StubAdapter) do
      post :run, params: { engine: 'gotenbrg' }

      assert_response :success
      assert_nil assigns(:reports)
      assert_equal I18n.t(:text_reporter_preflight_unknown_engine, engines: 'stub'),
                   flash[:error]
    end
  end

  def test_a_blank_but_given_engine_name_is_the_same_error
    @request.session[:user_id] = @admin.id

    with_engine(:stub, StubAdapter) do
      post :run, params: { engine: '  ' }

      assert_response :success
      assert_nil assigns(:reports)
      assert_not_nil flash[:error]
    end
  end

  # Nothing may be constructed from the parameter: an unknown name must be refused
  # before any adapter is newed up, or the parameter is a way to make the server do
  # work on unvalidated input.
  def test_an_unknown_engine_name_constructs_no_adapter
    @request.session[:user_id] = @admin.id

    with_engine(:stub, UnstartableAdapter) do
      post :run, params: { engine: 'gotenbrg' }

      assert_response :success
      # UnstartableAdapter raises on construction, and a constructed adapter becomes a
      # failed :engine check — so a nil @reports proves nothing ran.
      assert_nil assigns(:reports)
    end
  end

  # FR-50 — THE INSTALLATION'S SELECTED ENGINE REACHES THE SUITE FROM HERE.
  #
  # `PreflightSuite` may not read a `Setting` (mechanism E5; `render/**` is gated), so the
  # selection arrives as a port that THIS controller fills. A port a caller forgets is the
  # defect an independent review already found once in this plugin (`asset_resolver:`), and
  # its signature is invisible from the outside: the page renders identically either way and
  # only a deferred engine's skip row moves.
  #
  # So the claim is asserted about the CONSTRUCTOR — HANDOVER §1's rule for exactly this
  # shape — and in BOTH directions, because `expects` with a matcher passes against a caller
  # that never constructs one at all.
  def test_the_installations_selected_engine_is_handed_to_the_suite
    @request.session[:user_id] = @admin.id
    original = Setting.send(:plugin_redmine_reporter_dashboards)
    Setting.send(:plugin_redmine_reporter_dashboards=,
                 original.merge('render_engine' => 'chromium_cdp'))

    suite = mock('suite')
    suite.stubs(:reports).returns([])
    Render::PreflightSuite.expects(:new)
                          .with { |args| args[:selected_engine_id] == 'chromium_cdp' }
                          .returns(suite)

    post :run

    assert_response :success
  ensure
    Setting.send(:plugin_redmine_reporter_dashboards=, original)
  end

  def test_no_selection_hands_the_suite_nothing_to_prefer
    @request.session[:user_id] = @admin.id

    suite = mock('suite')
    suite.stubs(:reports).returns([])
    Render::PreflightSuite.expects(:new)
                          .with { |args| args[:selected_engine_id].nil? }
                          .returns(suite)

    post :run

    assert_response :success
  end

  # Not a blank page. "Nothing can render at all" is the most alarming answer this page
  # has, so it has to be the loudest — a green-looking empty page is the failure mode
  # this repository keeps rediscovering.
  def test_no_registered_engine_says_nothing_was_verified
    @request.session[:user_id] = @admin.id

    Render::Registry.isolated do
      post :run

      assert_response :success
      assert_equal [], assigns(:reports)
      assert_select '.nodata',
                    text: /#{Regexp.escape(I18n.t(:text_reporter_preflight_no_engine))}/
    end
  end

  # ---- I18n (§10) ---------------------------------------------------------

  # The view is keyed on `Check#id`, so a check the render layer gained and the locale
  # files did not would render its English title in a Russian UI. Asserted here rather
  # than trusted, because the fallback is silent by design.
  # READ OFF THE RENDER LAYER, not typed out here. A hand-written list is a list that
  # stops matching the day somebody adds a check, and the symptom is an English title
  # in a Russian UI — which the fallback makes silent by design.
  def test_every_check_id_the_preflight_can_emit_has_a_label
    # DERIVED, and the previous version was not: it hand-wrote
    # `DOCUMENT_CHECKS.keys + %i[engine degradations]` directly under a comment saying not
    # to, and T-34's seven new ids went to the admin page unlabelled while this stayed
    # green. `emittable_check_ids` asks the registry, so an adapter that adds a check adds
    # it here too.
    emitted = Render::PreflightSuite.emittable_check_ids

    assert_equal [], emitted - ReporterPreflightHelper::CHECK_LABELS.keys,
                 'a check the render layer emits has no locale key'
    assert_equal [], ReporterPreflightHelper::CHECK_LABELS.keys - emitted,
                 'a locale key names a check the render layer no longer emits'
  end

  # THE ARTEFACT HAS TO BE REACHABLE FROM THE PAGE. The rake user gets it from
  # RRD_FORMAT=json; without this block the administrator this page exists for is the
  # one person who cannot paste the report into an issue.
  def test_the_page_carries_the_json_artefact
    @request.session[:user_id] = @admin.id

    with_engine(:stub, UnstartableAdapter) do
      post :run

      assert_response :success
      assert_select 'pre', text: /"engine": "stub"/
      assert_select 'pre', text: /"state": "fail"/
    end
  end

  # THE SENTENCE AN ADMINISTRATOR ACTUALLY READS, and until now nothing asserted a word of
  # it. Two tests above assert the deferral's locale KEY exists, and in all nine files — and
  # both stayed green while the key's VALUE said *"this install has not chosen it"*, which is
  # false for an installation whose stored selection names an engine that is no longer
  # registered. `EnginePreference` drops such a value, so `selected_engine_id` arrives nil and
  # this row appears anyway.
  #
  # ASSERTED ON THE RENDERED ROW, not on the `Check`. The round before this one corrected
  # `Check#title` and thought it had fixed the page; a review measured that the page prints
  # `reporter_preflight_check_label`, which prefers the locale key and never reaches the
  # title. The title now only reaches the rake text and the JSON artefact. So the guard has
  # to be here, on the HTML, or the same slip happens again.
  # THE LOCALE IS SET WHERE THE CONTROLLER READS IT, and `I18n.with_locale` is not that place.
  # This asserts English prose, and the first attempt to stop it INHERITING its locale (§6)
  # wrapped the request in `with_locale('en')` — which a review measured as decorative:
  # `ApplicationController#set_localization` is a `before_action` that does
  # `set_language_if_valid(find_language(user.language))`, so it runs INSIDE the block and
  # overwrites it. Both directions were measured: `with_locale('de')` still rendered English
  # and still passed, and `@admin.language = 'de'` rendered German and failed with
  # `with_locale('en')` still in place. The locale is `User#language`, whose value came from
  # Redmine's OWN `test/fixtures/users.yml` — branch-versioned across 5.1 → 7.0, which is the
  # inheritance §6 forbids. So the user's language is what this sets.
  def test_the_deferral_row_does_not_tell_an_installation_it_chose_nothing
    @request.session[:user_id] = @admin.id
    @admin.update_column(:language, 'en')

    # A FAKE UNDER THE `:gotenberg` ID, which this file's header requires and the deferral
    # allows: `deferred?` keys on the registry ID and `deferred_report` never instantiates the
    # adapter, so nothing here can reach a browser or a container.
    with_engine(:gotenberg, StubAdapter) do
      post :run

      assert_response :success
      assert_select 'td', text: /is not this installation's selected engine/
      assert_select 'td', text: /has not chosen/, count: 0
      # The English fallback is silent by design, so a missing key would read as a pass.
      assert_no_match(/translation missing/i, @response.body)
    end
  end

  def test_every_state_has_a_label_and_a_distinct_class
    assert_equal Render::Preflight::STATES.sort,
                 ReporterPreflightHelper::STATE_LABELS.keys.sort

    classes = ReporterPreflightHelper::STATE_CLASSES
    assert_equal Render::Preflight::STATES.sort, classes.keys.sort
    # `expected_failure` must not look like `fail`: give them one colour and the
    # failure that matters gets ignored along with the one that does not.
    refute_equal classes[:fail], classes[:expected_failure]
  end

  def test_every_key_the_page_uses_exists_in_every_locale
    keys = ReporterPreflightHelper::CHECK_LABELS.values +
           ReporterPreflightHelper::STATE_LABELS.values +
           %i[label_reporter_preflight text_reporter_preflight_intro
              text_reporter_preflight_takes_a_moment button_reporter_preflight_run
              text_reporter_preflight_no_engine text_reporter_preflight_ok
              text_reporter_preflight_problems text_reporter_preflight_incomplete
              label_reporter_preflight_engine_version label_reporter_preflight_duration
              label_reporter_preflight_duration_ms label_reporter_preflight_json
              text_reporter_preflight_json
              label_reporter_preflight_state label_reporter_preflight_check
              label_reporter_preflight_detail
              label_reporter_preflight_engine label_reporter_preflight_engine_default
              text_reporter_preflight_unknown_engine]

    SHIPPED_LOCALES.each do |locale|
      ::I18n.with_locale(locale) do
        keys.each do |key|
          value = ::I18n.t(key, default: nil)
          assert value.present?, "#{locale}.yml is missing #{key}"
          refute_match(/translation missing/i, value.to_s)
        end
      end
    end
  end

  # THE NINE VALUES, BY EQUALITY — and the round that reworded them shipped a guard for
  # exactly ONE of them.
  #
  # `test_the_deferral_row_does_not_tell_an_installation_it_chose_nothing` renders one page
  # in one language, and the commit that added it claimed all nine were "pinned by an
  # assertion on the rendered <td>". A review reverted the eight non-English values to their
  # old wording — *"this install has not chosen it"*, false for an installation whose stored
  # selection names an engine that is no longer registered — and measured the whole repository
  # staying green: rspec 2674/0, minitest 921 runs/0, nine gate scripts OK. So eight ninths of
  # the sentence an administrator reads was unguarded by the fix that exists to guard it, which
  # is the same defect one scale up: the test above asserts these keys EXIST, and existence was
  # never the thing that was wrong.
  #
  # EQUALITY AND NOT A MATCHER, for the same reason three English sentences in this change are
  # pinned by equality: a keyword guard passes a rewording of the same falsehood, and these are
  # the values a native reader has not checked yet — so they are the ones most likely to be
  # silently "improved" back. Any deliberate rewording updates this table, which is the point.
  # DERIVED ONCE AND SHARED, because the round that introduced the table below wrote a comment
  # condemning hand-written locale lists sixty lines under one — `%w[de en es hu it pl pt-BR ru
  # zh]`, in the test whose whole promise is "every key the page uses exists in every locale".
  # A review measured the consequence: a tenth locale file carrying ONE key passed that test.
  SHIPPED_LOCALES = Dir[File.expand_path('../../config/locales/*.yml', __dir__)]
                    .map { |f| File.basename(f, '.yml') }.sort.freeze

  DEFERRAL_LABEL = {
    'de' => 'Die Render-Engine benötigt einen Dienst und ist nicht die gewählte Engine ' \
            'dieser Installation',
    'en' => "The render engine needs a service and it is not this installation's selected " \
            'engine',
    'es' => 'El motor de renderizado necesita un servicio y no es el motor elegido de esta ' \
            'instalación',
    'hu' => 'A renderelő motor szolgáltatást igényel, és nem ez a telepítés ' \
            'kiválasztott motorja',
    'it' => 'Il motore di rendering richiede un servizio e non è il motore scelto per ' \
            'questa installazione',
    'pl' => 'Silnik renderujący wymaga działania osobnej usługi renderowania i nie ' \
            'jest wybranym silnikiem tej instalacji',
    'pt-BR' => 'O mecanismo de renderização precisa de um serviço e não é o mecanismo ' \
               'escolhido desta instalação',
    'ru' => 'Механизму рендеринга нужна служба, и он не является выбранным механизмом ' \
            'этой установки',
    'zh' => '渲染引擎需要一项服务，且不是此安装选择的引擎'
  }.freeze

  # COLLECTED, NOT ABORTED ON THE FIRST. A review reverted all eight non-English values and
  # this loop reported only `de`; the other seven were invisible, so an eight-locale regression
  # would have cost eight edit-run cycles to see.
  def test_the_deferral_label_says_the_same_true_thing_in_every_locale
    wrong = DEFERRAL_LABEL.each_with_object({}) do |(locale, expected), acc|
      actual = ::I18n.with_locale(locale) do
        ::I18n.t(:label_reporter_preflight_check_engine_not_selected)
      end
      acc[locale] = actual unless actual == expected
    end

    assert_equal({}, wrong,
                 'these locales no longer say the deferral is about THIS engine not being ' \
                 'the selected one')
  end

  # AND THE TABLE ABOVE COVERS EVERY LOCALE THE PLUGIN SHIPS, derived rather than typed — a
  # hand-written list is a list that stops matching the day somebody adds a language, which is
  # how eight of nine went unguarded in the first place.
  def test_the_deferral_label_table_covers_every_shipped_locale
    assert_equal SHIPPED_LOCALES, DEFERRAL_LABEL.keys.sort
  end
end
