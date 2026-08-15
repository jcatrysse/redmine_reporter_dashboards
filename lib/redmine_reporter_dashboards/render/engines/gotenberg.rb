# frozen_string_literal: true

require 'cgi'
require 'json'
require 'net/http'
require 'securerandom'
require 'uri'

require_relative '../capabilities'
require_relative '../document_request'
require_relative '../page_furniture'
require_relative '../failure'
require_relative '../result'
require_relative '../readiness'
require_relative '../registry'

module RedmineReporterDashboards
  module Render
    module Engines
      # `:gotenberg` — the same Chromium, in somebody else's container. Never the default,
      # and never chosen by auto-detection: an operator has to deploy it and select it.
      #
      # THIS FILE IS THE ONE EXEMPTION TO THE `Net::HTTP` BAN UNDER `render/**`.
      # `script/gates/layer_purity.sh` enforces the ban as a proxy for INV-8 — the renderer
      # never holds the network, because a renderer that fetches a document's references on
      # the viewer's behalf is SSRF with a report attached. An engine that IS a service
      # cannot be reached without a socket, so the exemption is named, scoped to this file
      # and bounded by its own gate arm: no other file under `render/**` may name
      # `Net::HTTP`, and this file may not name `Rails.`, `ActiveRecord`, `Liquid`, `Issue`,
      # a cookie or a session.
      #
      # What keeps the exemption narrow:
      #
      #   * the endpoint is OPERATOR CONFIGURATION, never derived from a document, a
      #     template, a request parameter or an asset URL (`ENDPOINT_SCHEMES`,
      #     `#validate_endpoint!`);
      #   * `/forms/chromium/convert/url` is forbidden — it is SSRF by design, and a
      #     boundary grep asserts the string is absent from the whole tree;
      #   * the document arriving here is already asset-resolved. This adapter fetches
      #     nothing; it POSTs bytes it was given.
      #
      # ASSET MODEL: UPLOAD, because that is Gotenberg's only one — a multipart form whose
      # `index.html` is the document and whose sibling parts are the files it refers to by
      # relative name.
      #
      # The wire-format constants below were read off `gotenberg/gotenberg:8` @
      # sha256:a16a14e1f18a71405624bc028e90d4ef50ea774c352b303639c10bf7b141f760
      # (Gotenberg 8.35.0) rather than off its documentation.
      class Gotenberg
        ID = :gotenberg

        # Matches `config/capabilities.yml` exactly; the conformance suite asserts the two
        # are equal rather than trusting that they look it.
        #
        # `:asset_inline` is absent even though this engine's Chromium decodes a `data:` URI
        # fine. The resolver reads this list to pick an asset model, and an engine declaring
        # both would take the inline branch for everything under `inline_max_bytes`, leaving
        # the upload path unexercised. One asset model per engine.
        #
        # `:asset_http` is absent by policy as well as by capability (INV-8).
        CAPABILITIES = %i[
          javascript modern_javascript readiness_expression print_backgrounds header footer
          page_furniture_tokens custom_page_size landscape margins scale
          page_break_css media_print pdf_metadata asset_upload timeout
        ].freeze

        # THE ONE ROUTE. A frozen constant rather than an interpolation, so there is no
        # expression anywhere in this file that could evaluate to another route.
        CONVERT_PATH = '/forms/chromium/convert/html'
        VERSION_PATH = '/version'

        # The entry document's name is fixed by Gotenberg: a form without a part called
        # `index.html` is refused with 400 "form file 'index.html' is required" (measured).
        INDEX_PART = 'index.html'
        HEADER_PART = 'header.html'
        FOOTER_PART = 'footer.html'

        # Every part goes under this field name; Gotenberg keys on the FILENAME, not on
        # the field.
        FILES_FIELD = 'files'

        ENDPOINT_SCHEMES = %w[http https].freeze

        # THERE IS NO DEFAULT ENDPOINT. The obvious one is the worst possible value:
        # `http://localhost:3000` is Rails' and Redmine's own port, so an unconfigured
        # adapter would POST a probe document — and a credential — to Redmine itself.
        #
        # Construction stays total: raising here would escape `adapter.new` in
        # `ReportRun#with_pdf` and in the conformance harness. An unconfigured adapter builds
        # and answers a typed `Failure` naming the variable to set (INV-5).
        UNCONFIGURED = nil

        # The floor `config/capabilities.yml` declares. Checked on the MAJOR only: a project
        # pinning by digest gets its patch level from the pin.
        SUPPORTED_MAJOR = 8

        # How long to wait for the credential and version probes. These are not renders;
        # a service that cannot answer `/version` in ten seconds is not one to send a
        # report to.
        PROBE_TIMEOUT_MS = 10_000

        # Inches, because that is what this route speaks. Same conversion as the reference
        # adapter, and wrong in the same invisible way if it is wrong — F-03 is the fixture
        # that measures it.
        MM_PER_INCH = 25.4

        PAGE_SIZES_MM = {
          'A3' => [297, 420], 'A4' => [210, 297], 'A5' => [148, 210],
          'Letter' => [215.9, 279.4], 'Legal' => [215.9, 355.6],
          'Tabloid' => [279.4, 431.8]
        }.freeze

        # An asset name becomes a FILENAME inside the container, and a multipart filename
        # is a header value. Two different injections live in that sentence, so the name is
        # checked against a closed shape rather than escaped:
        #
        #   `a/../../etc/passwd`  a path, which Gotenberg would write outside its job dir
        #   `a"; filename="b`     a header break, which rewrites the part's own disposition
        #   `a\r\nContent-Type:`  a header injection, which rewrites the whole request
        #
        # `Assets::Resolver#asset_name` produces `rrd-asset-<32 hex><ext>` and nothing else,
        # so today this can only fire on a caller that built its own assets hash. It is
        # here because "the only producer is safe" is a property of the CURRENT tree, and
        # the cost of the check is one regexp.
        SAFE_ASSET_NAME = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/

        # `type/subtype` with the parameters a media type may legitimately carry, and
        # NOTHING that could end a header line. Deliberately narrower than RFC 2045: this
        # is a guard, and every type the asset layer can produce is in
        # `Assets::ContentTypes`' closed allowlist and matches this easily.
        # `\#\$&` AND NOT `#$&`. In a Ruby regexp literal `#$&` is GLOBAL-VARIABLE
        # INTERPOLATION, so the character class silently compiled to
        # `[A-Za-z0-9!^_.+-]` — the value of a security guard depending on `$&` in whatever
        # frame loaded the file. Found by an adversarial QA pass, which also constructed the
        # danger: with `$&` set to `]|.*` the same literal compiles to a class that closes
        # early and matches a CRLF payload. It happened to be STRICTER than intended here,
        # so nothing legitimate was refused and no test could tell.
        SAFE_CONTENT_TYPE = %r{\A[A-Za-z0-9][A-Za-z0-9!\#\$&^_.+-]{0,62}/
                               [A-Za-z0-9][A-Za-z0-9!\#\$&^_.+-]{0,62}
                               (?:;[ ]?[A-Za-z0-9-]{1,32}=[A-Za-z0-9._-]{1,64}){0,4}\z}x.freeze

        DEFAULT_CONTENT_TYPE = 'application/octet-stream'

        # A JS-LIVENESS PROBE THAT CANNOT SILENTLY PASS — see `#preflight`.
        JS_PROBE_DOCUMENT = '<!DOCTYPE html><html><body><p>rrd preflight</p>' \
                            "<script>throw new Error('rrd-js-liveness-probe')</script>" \
                            '</body></html>'

        PROBE_DOCUMENT = '<!DOCTYPE html><html><body><h1>rrd preflight</h1></body></html>'

        # THE READINESS EXPRESSION, COERCED TO A BOOLEAN — and the `!!` is not tidiness.
        #
        # MEASURED against 8.35.0, and it cost every chart-bearing report on this engine
        # before the probe caught it. `Readiness::EXPRESSION` is
        # `window.__rd && window.__rd.ready === true`, and BEFORE THE CHART SHELL HAS RUN
        # `window.__rd` is undefined, so the whole expression evaluates to `undefined`
        # rather than to `false`. Gotenberg does not treat that as "not ready yet" — it
        # refuses the conversion outright:
        #
        #     400 The expression '…' (waitForExpression) returned an exception or undefined
        #
        # in 0.2 s, so the readiness contract's "wait, then render anyway" never even
        # started. `!!(…)` makes it a real `false`, which Gotenberg waits on correctly.
        #
        # The reference adapter has always done this — `page.evaluate("!!(#{EXPRESSION})")`
        # — so the coercion is the interface's, not this engine's quirk. It is spelled out
        # here rather than pushed into `Readiness::EXPRESSION` because wkhtmltopdf's
        # `--window-status` arm does not evaluate an expression at all, and changing the
        # shared constant would put a JavaScript operator into a string that engine reads
        # as a status name.
        READINESS_EXPRESSION = "!!(#{Readiness::EXPRESSION})"

        attr_reader :endpoint

        # `endpoint` and `credential` are OPERATOR configuration, injected. This layer
        # cannot read a Redmine setting — `layer_purity.sh` forbids `Rails.` here, and
        # mechanism E5 is why — so the composition root passes them down and the
        # environment is the fallback the conformance harness and CI use.
        #
        # `credential` is a `[username, password]` pair, Gotenberg 8's only auth model
        # (`--api-enable-basic-auth`, measured). It is deliberately NOT a header string:
        # a string would accept `Authorization: Bearer …` for a service that has no bearer
        # auth, and would accept a newline.
        # `credential:` DEFAULTS TO A SENTINEL, NOT TO `nil`, and the difference is a
        # defect this file had until a mutation run exposed it.
        #
        # It was `credential: nil` with `credential || credential_from_env`, so
        # `Gotenberg.new(credential: nil)` — "explicitly no credential", the thing the
        # preflight's own examples are ABOUT — silently picked the environment's up
        # instead. There was no way to say "none" at all. Worse, it made those examples
        # environment-dependent: green on a laptop with no `RRD_GOTENBERG_*` set, red in
        # the render-smoke job, which exports them. That is CLAUDE.md §3's "passes
        # locally, fails in CI" in its purest form, and no example could have caught it
        # while every example ran on the same clean machine.
        #
        # `:from_env` means "I did not say"; `nil` means "none".
        FROM_ENV = :from_env

        def initialize(endpoint: nil, credential: FROM_ENV, http: nil, logger: nil)
          # TOTAL, AND THE PREVIOUS VERSION ONLY LOOKED IT. `validate_endpoint!` RAISED, and
          # the comment above claimed construction stays total precisely because
          # `ReportRun#with_pdf` does a bare `adapter.new` with no rescue anywhere above it.
          # Measured by an adversarial QA pass: `RRD_GOTENBERG_URL=gotenberg:3000` — a
          # missing scheme, which is exactly what an operator types after reading a compose
          # file — escaped as an uncaught `ArgumentError` and 500'd the preview page. So did
          # a trailing newline from `--env-file`, a stray space, and surrounding quotes. The
          # `nil` and `''` cases were total; nothing else was, and only those two were tested.
          #
          # This is the identical defect `report_run.rb` already fixed for
          # `engine.capabilities`: an adapter that raises takes the whole request out as an
          # untyped exception. The reason is refused into `@endpoint_error` and every entry
          # point answers a typed Failure carrying it.
          configured = endpoint || ENV['RRD_GOTENBERG_URL']
          @endpoint, @endpoint_error = resolve_endpoint(configured)
          @credential =
            normalize_credential(credential == FROM_ENV ? credential_from_env : credential)
          @http = http
          @logger = logger
        end

        def id
          ID
        end

        def capabilities
          CAPABILITIES
        end

        # PROBED FROM THE SERVICE, never a constant — `GET /version` answers `8.35.0`.
        # Memoised, because the stamp is asked for once per result and a version probe per
        # document would double the request count for a fact that cannot change under a
        # pinned digest.
        def version
          return 'unknown' unless @endpoint

          @version || probe_version(timeout_ms: PROBE_TIMEOUT_MS)
        end

        # Separated from `#version` so a caller with a deadline can impose one. Memoises
        # whatever it learns, including a failure — a service that cannot answer `/version`
        # will not answer it any better on the next document of the same run.
        def probe_version(timeout_ms:)
          response = request_get(VERSION_PATH, timeout_ms: timeout_ms)
          @version = if response.equal?(TIMED_OUT)
                       'unavailable (timeout)'
                     elsif response.is_a?(Net::HTTPSuccess)
                       response.body.to_s.strip
                     else
                       'unavailable'
                     end
        rescue StandardError => e
          @version = "unavailable (#{e.class})"
        end

        # PREFLIGHT IS A ROUND TRIP, and for this engine it is also the only place the
        # UNSAFE CONFIGURATIONS can be caught — technical-spec.md §5.2 clause 2. Four
        # checks, in this order, because each is cheaper than the one after it and because
        # refusing an unauthenticated service should not require rendering anything on it.
        #
        #   1. the credential check
        #   2. the version floor
        #   3. JavaScript liveness
        #   4. the render round trip
        #
        # --- 1. THE CREDENTIAL CHECK, AND THE PROBE THAT WOULD HAVE BEEN VACUOUS ---
        #
        # MEASURED, and this is the entry worth reading before changing anything here.
        # Against 8.35.0 with `--api-enable-basic-auth` and both env vars set:
        #
        #     GET  /health                        unauthenticated -> 200   <-- EXEMPT
        #     GET  /version                       unauthenticated -> 401
        #     POST /forms/chromium/convert/html   unauthenticated -> 401
        #     POST /forms/chromium/convert/html   authenticated   -> 415 (no parts)
        #
        # `/health` is exempt from basic auth. A credential check written against the
        # obvious health endpoint therefore answers 200 on a correctly locked-down service
        # AND on a wide-open one — a security check that cannot fail, which is the exact
        # shape this repository keeps rediscovering. So the probe is an UNAUTHENTICATED
        # POST to the convert route with no parts: it is the route that actually matters,
        # it costs no render, and 401/403 versus anything else is decisive.
        #
        # AND A MISSING CREDENTIAL IS ALSO A FAILURE. §5.2 reads "the endpoint is not
        # reachable without the configured credential (if a credential is configured)" and
        # then, one sentence later, "A Gotenberg reachable UNAUTHENTICATED produces a
        # preflight failure with a named remediation, not a warning". The second sentence
        # is unconditional and is the safer of the two readings, so it is the one
        # implemented: with no credential configured this plugin cannot authenticate, so
        # the endpoint IS reachable unauthenticated by it, which is the configuration the
        # 2026 unauthenticated-critical CVE cluster is about. Both arms name their own
        # remediation, because they need different ones.
        #
        # --- 3. JAVASCRIPT LIVENESS, AND THE SECOND CHECK THAT COULD NOT FAIL ---
        #
        # §5.2 also requires the preflight to assert that `chromium.disableJavaScript`
        # matches what this adapter assumes — it declares `:javascript`,
        # `:modern_javascript` and `:readiness_expression`, all three of which are void on
        # a container started with `--chromium-disable-javascript`.
        #
        # The obvious probe is `waitForExpression`, and MEASURED it is worthless for this:
        #
        #     JS live,     expression never true  -> 503 after the 30 s api timeout
        #     JS disabled, expression never true  -> 200 in 0.17 s
        #
        # Gotenberg SILENTLY IGNORES `waitForExpression` when JavaScript is off. So a
        # readiness signal that is the whole basis of the chart contract quietly stops
        # being waited for, every report renders chart-free, and nothing anywhere fails —
        # which is precisely the "healthy container, silently wrong documents" failure the
        # preflight exists to catch.
        #
        # The probe that DOES discriminate, in half a second either way, is a document
        # whose script THROWS, sent with `failOnConsoleExceptions`:
        #
        #     JS live     -> 409, naming the exception
        #     JS disabled -> 200, because the script never ran
        #
        # A 409 is therefore the PASS here, which is worth the double-take: the check
        # succeeds by provoking an error, and an engine that cannot be made to error has
        # no JavaScript.
        def preflight
          return unconfigured_failure('preflight') unless @endpoint

          refusal = configuration_checks.find { |check| check[:state] == :fail }
          return refusal[:failure] if refusal

          render(DocumentRequest.new(body: PROBE_DOCUMENT, correlation_id: 'preflight',
                                     page_size: 'A4', timeout_ms: 30_000))
        end

        # --- THE PRODUCT'S PREFLIGHT READS THIS, AND THAT IS THE WHOLE POINT ----
        #
        # `#preflight` returns a `Result`, which is what the conformance harness wants and
        # what the other two adapters answer. It is NOT what an operator sees: the admin
        # page and `rake reporter_dashboards:render:preflight` both go through
        # `Render::Preflight#run`, which renders a probe document and reads it back — and
        # for two releases nothing in the shipped product called `engine.preflight` at all.
        #
        # Two independent reviews found that on the same afternoon, and it is the worst
        # kind of defect this project has a name for: the credential check, the version
        # floor and the JavaScript probe were each rewritten after MEASURING that they
        # could not fail — and then hung on a method with no caller, while the README, the
        # compose file and `capabilities.yml` all told an operator the plugin refuses an
        # unauthenticated Gotenberg. Running the exact command the README prints, against a
        # Gotenberg with no authentication whatsoever, returned EXIT 0 AND EIGHT PASSES.
        #
        # So the checks are published as DATA — id, title, state, detail — and
        # `Render::Preflight` turns them into its own `Check`s. Plain hashes, because this
        # is the same shape `Assets` uses to avoid naming a render type across a boundary,
        # and because the `id` is the part that is a CONTRACT rather than prose: it is what
        # `ReporterPreflightHelper::CHECK_LABELS` keys a locale entry off, which is how
        # these sentences become translatable (§Findings E-26 #6's own recommendation).
        #
        # An adapter that does not answer to this simply has no configuration checks, which
        # is true of both binary-backed engines: there is nothing to misconfigure about a
        # Chromium you launched yourself.
        def configuration_checks
          unless @endpoint
            return [check_hash(:gotenberg_endpoint, unconfigured_failure('preflight'),
                               duration_ms: 0)]
          end

          checks = []
          [%i[gotenberg_reachable check_reachable],
           %i[gotenberg_credential check_credential],
           %i[gotenberg_version check_version],
           %i[gotenberg_javascript check_javascript]].each do |id, method|
            # EACH CHECK CARRIES ITS OWN CLOCK (E-27 row 10). These hashes used to have no
            # `duration_ms` at all, so `Preflight` built its `Check`s with nil and the
            # admin page's `ms.to_i` printed "0 ms" for a row that had just spent ten
            # seconds timing out — a timing column that lies in exactly the case an
            # operator is reading it.
            check_started = monotonic_ms
            failure = send(method, check_started)
            checks << check_hash(id, failure,
                                 duration_ms: (monotonic_ms - check_started).round)
            # STOPS AT THE FIRST FAILURE, deliberately. The checks are ordered so that each
            # one's premise is established by the one before it — asking whether JavaScript
            # is alive on a service that is not a Gotenberg produces a confident wrong
            # answer, which is INV-4 and is exactly what this ordering exists to avoid.
            break if failure
          end
          checks
        end

        CHECK_TITLES = {
          # "ADDRESS", not "endpoint": `label_reporter_preflight_check_gotenberg_endpoint`
          # and the failure message both say address, and one screen with two nouns for one
          # thing was a review rejection in this project on 2026-08-11.
          gotenberg_endpoint: 'an address is configured for the render service',
          gotenberg_reachable: 'the render service answers, and is a Gotenberg',
          gotenberg_credential: 'the render service enforces its credential',
          gotenberg_version: 'the render service is Gotenberg 8 or later',
          gotenberg_javascript: 'the render service has JavaScript enabled, so charts can draw'
        }.freeze

        def render(request)
          return unconfigured_failure(request.correlation_id) unless @endpoint

          started = monotonic_ms
          deadline = started + request.timeout_ms

          attempt, refusal = render_with_readiness(request, started, deadline)
          return refusal if refusal

          bytes, degradations = attempt
          # `version_within(deadline)` AND NOT `version`. The stamp is probed from the
          # service, and an un-deadlined probe added up to PROBE_TIMEOUT_MS to a request
          # that had already stated its own bound — measured at 3 001 ms of wall time for a
          # `timeout_ms: 500` request. A slow `/version` must not extend a render; the
          # document is already drawn, so an unknown version is the honest answer.
          Success.new(bytes: bytes, engine: ID, engine_version: version_within(deadline),
                      page_count: nil,
                      duration_ms: (monotonic_ms - started).round,
                      degradations: degradations + capability_degradations(request))
        rescue StandardError => e
          failure(request, :internal, 'the report could not be produced',
                  detail: "#{e.class}: #{e.message}", started: started)
        end

        # Nothing is held open between renders — `Net::HTTP.start` is per request — so
        # there is nothing to tear down. Answering `true` rather than omitting the method
        # keeps the adapter interface uniform for the conformance harness's `ensure`.
        def shutdown
          true
        end

        private

        # The stamp, bounded by whatever is left of the caller's deadline. Returns the
        # memoised value when there is one — the common case, since a fresh probe happens
        # at most once per adapter instance — and `'unknown'` rather than a slow answer
        # when the budget is gone.
        def version_within(deadline)
          return @version if @version

          remaining = remaining_ms(deadline)
          return 'unknown' if remaining <= 0

          probe_version(timeout_ms: [remaining, PROBE_TIMEOUT_MS].min)
        end

        public

        private

        # --- READINESS, AND THE ONE PLACE THIS ENGINE CANNOT DO WHAT THE CONTRACT SAYS ---
        #
        # §5's contract: on a readiness timeout the engine STILL RENDERS and the result
        # carries `Degradation(:readiness_timeout)`, unless the caller asked for `strict`.
        # Gotenberg cannot do that in one request — an expression that never comes true
        # ends the whole conversion with a 503 and no bytes at all, so "render anyway" has
        # to be a SECOND request without the expression.
        #
        # That is the abstraction earning its keep rather than leaking: the caller gets the
        # same three outcomes from every engine, and the cost of the difference is paid
        # here, on the path that was already slow, by the engine that is already the
        # expensive one.
        #
        # OUR deadline governs, not the container's. Gotenberg's `--api-timeout` is server
        # configuration this plugin does not own and defaults to 30 s, which is longer than
        # `Readiness::DEFAULT_TIMEOUT_MS`; waiting for it would make the readiness bound a
        # property of somebody else's flag file. So the client read timeout is the
        # readiness budget, and the abandoned request is left to the container to reap.
        def render_with_readiness(request, started, deadline)
          readiness = request.readiness
          response = post_convert(request, started, deadline,
                                  readiness: readiness, timeout_ms: readiness_budget(request))
          return [nil, response] if response.is_a?(Failure)
          return [[response, []], nil] unless timed_out?(response)

          # NO READINESS WAS ASKED FOR, so there is nothing to retry WITHOUT. The wait that
          # ran out was the request's own `timeout_ms`, and rendering a second time would
          # spend it twice — the first draft did exactly that, and the symptom is a
          # 30-second request that takes a minute to fail.
          return [nil, timeout_failure(request, started)] unless readiness

          if readiness.strict?
            return [nil, failure(request, :readiness_timeout,
                                 'the report was not finished drawing in time',
                                 detail: 'the readiness expression did not become true ' \
                                         "within #{readiness.timeout_ms}ms and strict was asked for",
                                 started: started)]
          end

          retried = post_convert(request, started, deadline, readiness: nil,
                                                             timeout_ms: remaining_ms(deadline))
          return [nil, retried] if retried.is_a?(Failure)
          return [nil, timeout_failure(request, started)] if timed_out?(retried)

          [[retried, Array(readiness.on_timeout(pending: 'unknown')).compact], nil]
        end

        # The readiness budget is the SMALLER of the readiness timeout and what is left of
        # the request's own deadline. Without the second half a request with
        # `timeout_ms: 2_000` and the default 10 s readiness would wait five times its own
        # stated bound before the retry even started.
        def readiness_budget(request)
          return request.timeout_ms unless request.readiness

          [request.readiness.timeout_ms, request.timeout_ms].min
        end

        def remaining_ms(deadline)
          [(deadline - monotonic_ms).round, 0].max
        end

        # A sentinel rather than an exception, so that "the wait ran out" and "the service
        # said no" are two values on one path instead of a rescue wrapped around the retry.
        TIMED_OUT = :timed_out

        def timed_out?(value)
          value.equal?(TIMED_OUT)
        end

        def post_convert(request, started, deadline, readiness:, timeout_ms:)
          return timeout_failure(request, started) if timeout_ms <= 0

          parts = build_parts(request, readiness: readiness)
          return parts if parts.is_a?(Failure)

          response = post_multipart(CONVERT_PATH, parts, timeout_ms: timeout_ms,
                                                         correlation_id: request.correlation_id)
          return TIMED_OUT if response.equal?(TIMED_OUT)

          interpret(request, response, started, deadline)
        rescue StandardError => e
          transport_failure(request, e, started)
        end

        def interpret(request, response, started, _deadline)
          case response
          when Net::HTTPSuccess then response.body
          when Net::HTTPUnauthorized, Net::HTTPForbidden
            # THE ONE THAT REACHES A REPORT READER. The service is up, it answered, and it
            # will keep answering 401 until somebody fixes the credential — so this is the
            # render path's `:engine_misconfigured` (§Findings E-27 row 3). Reported as
            # `:engine_unavailable` it read as "the container is down" in a mail nobody
            # could act on.
            failure(request, :engine_misconfigured, unauthorized_message,
                    detail: "#{response.code} from #{CONVERT_PATH}", started: started)
          when Net::HTTPServiceUnavailable
            # 503 is what this route answers when its own `--api-timeout` runs out. It is
            # the container giving up on a render, not the service being down.
            failure(request, :timeout, 'the report took too long to draw',
                    detail: "503 from #{CONVERT_PATH}: #{body_excerpt(response)}", started: started)
          when Net::HTTPClientError
            # 400/415 mean this adapter built a request the route refuses. That is a bug
            # here, not an engine fault, and `:internal` is what says so — blaming the
            # engine would send an operator to restart a container that is working.
            failure(request, :internal, 'the report could not be produced',
                    detail: "#{response.code} from #{CONVERT_PATH}: #{body_excerpt(response)}",
                    started: started)
          else
            failure(request, :engine_crashed, 'the render engine failed',
                    detail: "#{response.code} from #{CONVERT_PATH}: #{body_excerpt(response)}",
                    started: started)
          end
        end

        # --- THE FORM ---------------------------------------------------------
        #
        # `index.html` is the document. Every asset the resolver put in `request.assets`
        # becomes a sibling part under its own name, and the document refers to it by that
        # bare name — which is why `Assets::Resolver#upload!` rewrites the reference to the
        # name and why a relative reference is correct there and nowhere else in the plugin.
        def build_parts(request, readiness:)
          parts = [file_part(INDEX_PART, request.body, 'text/html')]

          request.assets.each do |name, asset|
            unless SAFE_ASSET_NAME.match?(name.to_s)
              return Failure.new(code: :internal, correlation_id: request.correlation_id,
                                 engine: ID, engine_version: @version || 'unknown',
                                 message: 'the report could not be produced',
                                 detail: "asset name #{name.to_s[0, 64].inspect} is not a plain " \
                                         'file name; a name that is a path or carries a quote or ' \
                                         'a newline would rewrite the multipart request itself')
            end

            bytes = asset[:bytes] || asset['bytes']
            content_type = asset[:content_type] || asset['content_type'] || DEFAULT_CONTENT_TYPE
            # THE CONTENT TYPE IS A HEADER VALUE, EXACTLY AS THE NAME IS. `SAFE_ASSET_NAME`
            # above argues that "the only producer is safe" is a property of the CURRENT
            # tree — and then the identical argument was not made about the other header
            # value in the same part. An independent review put a CRLF in a content type
            # and watched a second `Content-Disposition` appear in the form: 14 disposition
            # headers for 13 parts, accepted and sent.
            unless SAFE_CONTENT_TYPE.match?(content_type.to_s)
              return Failure.new(code: :internal, correlation_id: request.correlation_id,
                                 engine: ID, engine_version: @version || 'unknown',
                                 message: 'the report could not be produced',
                                 detail: "asset #{name.to_s[0, 64].inspect} has content type " \
                                         "#{content_type.to_s[0, 64].inspect}, which is not a " \
                                         'plain media type; a newline there rewrites the ' \
                                         'multipart request itself')
            end

            parts << file_part(name.to_s, bytes, content_type)
          end

          parts.concat(furniture_parts(request))
          parts.concat(field_parts(request, readiness))
          parts
        end

        # Header and footer are FILES here, not options — `header.html` and `footer.html`
        # are read by name, exactly like `index.html`. The token spelling is Chromium's,
        # because it is Chromium underneath, and this is the only place in the plugin
        # besides the reference adapter allowed to know that.
        def furniture_parts(request)
          parts = []
          if request.header && !request.header.empty?
            parts << file_part(HEADER_PART, furniture_html(request.header), 'text/html')
          end
          if request.footer && !request.footer.empty?
            parts << file_part(FOOTER_PART, furniture_html(request.footer), 'text/html')
          end
          parts
        end

        # THE PAGE IS SENT PORTRAIT AND ROTATED BY THE FLAG — NOT SWAPPED HERE.
        #
        # The reference adapter swaps `paperWidth`/`paperHeight` itself and never sets an
        # orientation, because Chromium's printToPDF has no flag it uses. This route has
        # one, and MEASURED it rotates WHATEVER DIMENSIONS IT IS GIVEN:
        #
        #     W=8.2677  H=11.6929  landscape=true  -> 841.92 x 595.92  (landscape)
        #     W=11.6929 H=8.2677   landscape=false -> 841.92 x 595.92  (landscape)
        #     W=11.6929 H=8.2677   landscape=true  -> 595.92 x 841.92  (PORTRAIT)
        #
        # So doing both — which the first version did, by copying the swap across and
        # then also sending the flag — cancels out and quietly produces a PORTRAIT page
        # for every landscape report. Nothing failed: the document rendered, the margins
        # were right, and only the page was the wrong way round. Conformance fixture F-03
        # is what caught it (`expected 841.89 ± 3, got 595.92`), which is the argument for
        # "passes T-12's corpus unmodified" being an acceptance criterion rather than a
        # formality.
        def field_parts(request, readiness)
          width_mm, height_mm = PAGE_SIZES_MM.fetch(request.page_size, PAGE_SIZES_MM['A4'])

          fields = {
            'paperWidth' => mm_to_in(width_mm).to_s,
            'paperHeight' => mm_to_in(height_mm).to_s,
            'marginTop' => mm_to_in(request.margins_mm['top']).to_s,
            'marginBottom' => mm_to_in(request.margins_mm['bottom']).to_s,
            'marginLeft' => mm_to_in(request.margins_mm['left']).to_s,
            'marginRight' => mm_to_in(request.margins_mm['right']).to_s,
            'scale' => request.scale.to_s,
            # THE DEFAULT THIS ADAPTER MUST OVERRIDE, for the same reason the reference
            # one does: every badge and alternating row in the shipped templates is a CSS
            # background, and Chromium's own default drops all of them.
            'printBackground' => request.print_backgrounds.to_s,
            'preferCssPageSize' => 'false',
            'landscape' => request.landscape?.to_s
          }
          fields['emulatedMediaType'] = 'print' if request.media == :print
          fields['waitForExpression'] = READINESS_EXPRESSION if readiness
          title = request.pdf_metadata['title'] || request.pdf_metadata[:title]
          fields['metadata'] = JSON.generate('Title' => title.to_s) if title

          fields.map { |name, value| field_part(name, value) }
        end

        # Same compilation as the reference adapter's, and for the same two reasons found
        # by conformance fixture F-04: a whitespace-only text node beside an inline element
        # is collapsed away in the furniture document ("Page1of3"), and literal slot text
        # is author-controlled and goes into markup position.
        def furniture_html(furniture)
          slots = furniture.slots.map do |position, text|
            align = { 'left' => 'flex-start', 'center' => 'center', 'right' => 'flex-end' }[position]
            "<div style=\"flex:1;display:flex;justify-content:#{align}\">#{compile_tokens(text)}</div>"
          end

          '<!DOCTYPE html><html><body>' \
            "<div style=\"width:100%;font-size:#{furniture.font_size_pt}pt;" \
            "padding:0 10mm;display:flex;color:#444\">#{slots.join}</div>" \
            '</body></html>'
        end

        def compile_tokens(text)
          parts = []
          remainder = text.to_s
          while (match = PageFurniture::TOKEN_PATTERN.match(remainder))
            parts << literal(match.pre_match) << token_markup(match[1], match[0])
            remainder = match.post_match
          end
          parts << literal(remainder)
          parts.join
        end

        def literal(fragment)
          CGI.escapeHTML(fragment.to_s).gsub(' ', '&nbsp;')
        end

        def token_markup(name, original)
          case name
          when 'page' then '<span class="pageNumber"></span>'
          when 'pages' then '<span class="totalPages"></span>'
          when 'title' then '<span class="title"></span>'
          when 'date' then '<span class="date"></span>'
          else literal(original)
          end
        end

        # --- THE PREFLIGHT CHECKS ---------------------------------------------

        # IDENTITY BEFORE VERDICT, and the ordering used to be the other way round for a
        # reason that turned out to be the wrong axis. The comment above `#preflight` once
        # justified the sequence on COST — "each is cheaper than the one after it" — which
        # is true and irrelevant: a diagnostic's job is to be right about what is wrong.
        #
        # Two misdiagnoses came out of it, both found by an independent review, both INV-4:
        #
        #   the service is DOWN         -> "answered WITHOUT the configured credential",
        #                                  sending an operator to audit basic auth on a
        #                                  container that is not running
        #   it is NOT a Gotenberg       -> the same sentence. An nginx, a Redmine, a load
        #      (a 404 from anything)       balancer and a Gotenberg behind an unnamed root
        #                                  path all answer 404 to this probe
        #
        # So this runs first, unauthenticated, and it establishes only that SOMETHING is
        # there and that it looks like a Gotenberg. `/version` is the right probe: it is a
        # GET, it is cheap, and MEASURED it is auth-gated (401) while `/health` is exempt —
        # so both of its plausible answers are informative.
        def check_reachable(started)
          # `credential: nil` — AND THE COMMENT ABOVE ALREADY SAID "unauthenticated" while
          # the code sent the credential. An adversarial QA pass measured the consequence:
          # with a WRONG password the service answers 401, this arm read that as "a
          # Gotenberg enforcing its credential", the credential arm agreed, and the run
          # reported PASS on both before failing on the version with "this endpoint did not
          # answer /version with a version". The pre-fix render path said "the render
          # service refused the configured credential" — the diagnosis got WORSE. A 401 only
          # means "enforcing" if nothing was presented.
          response = request_get(VERSION_PATH, timeout_ms: PROBE_TIMEOUT_MS, credential: nil)
          memoise_version(response)

          if response.equal?(TIMED_OUT)
            return preflight_failure(
              started, "nothing answered at #{@endpoint} in time",
              'Confirm the container is running and that Redmine can reach it at this ' \
              'address. With `internal: true` in the example compose file, Redmine has to ' \
              'be on the same Docker network — `docker compose -f ' \
              'docker-compose.gotenberg.yml ps` and `logs gotenberg` are the two things ' \
              'to look at.',
              detail: "GET #{VERSION_PATH} did not answer within #{PROBE_TIMEOUT_MS}ms"
            )
          end

          # 401/403 is a Gotenberg enforcing its credential — the best possible answer
          # here, and the credential check below is what confirms it. A version string is
          # a Gotenberg that is NOT enforcing one, which is also this check passing: it is
          # the next check's job to say so, not this one's.
          return nil if response.is_a?(Net::HTTPUnauthorized) || response.is_a?(Net::HTTPForbidden)
          return nil if response.is_a?(Net::HTTPSuccess) && response.body.to_s.strip =~ /\A\d+\./

          preflight_failure(
            started, "#{@endpoint} answered #{response.code}, and does not look like a Gotenberg",
            "Confirm the address points at a Gotenberg and includes any `--api-root-path` " \
            'prefix the container was started with. A Gotenberg answers `GET /version` ' \
            'with a bare version string such as `8.35.0`, or 401 when it is enforcing a ' \
            'credential.',
            detail: "GET #{VERSION_PATH} answered #{response.code}: #{body_excerpt(response)}"
          )
        # ITS OWN SENTENCE, AND DELIBERATELY NOT ITS OWN CODE — which is E-29 row 2's
        # recommendation as written ("a diagnostic-message change rather than a code change")
        # and not the wider thing the first draft of this arm did.
        #
        # What the UX pass measured is real: a name that does not resolve and a socket that
        # refuses were arriving under ONE sentence — *"nothing answered at …, Confirm the
        # container is running"* — which sends an operator to `docker ps` for a fault no
        # restart can fix, with the discriminator sitting unused in `detail`. Splitting the
        # ARM fixes that. The first draft also moved the CODE to `:engine_misconfigured`, and
        # an independent review refuted that by measurement, twice over:
        #
        #   * `technical-spec.md` §5 states this rule ONCE, on purpose — "two normative
        #     statements of one rule is how a vocabulary acquires two meanings" — and what it
        #     states is that reachability and transport are THEREFORE `:engine_unavailable`.
        #     A code change here contradicts the contract; a message change does not.
        #   * `SocketError` is not "the name is wrong". It is every `getaddrinfo` failure,
        #     EAI_AGAIN included — a resolver that is temporarily unreachable, measured
        #     against a bind-mounted unreachable `nameserver` with the address spelled
        #     correctly. `:engine_misconfigured` promises "no retry will ever produce a
        #     different answer", and a retry is exactly what fixes that one. So the code that
        #     has NOT chosen between remedies is the correct code, and the sentence names both
        #     of them.
        #
        # `Socket::ResolutionError#error_code` would discriminate EAI_AGAIN from EAI_NONAME,
        # but only on Ruby 3.3+ — below it there is nothing but the message — so the split
        # would hold on three of the four supported cells (3.2, 3.3, 3.4, 3.4 — a review counted
        # this where an earlier comment said two) and guess on the fourth. One sentence naming
        # both remedies is honest on all four.
        #
        # `SocketError` AND NOT `Socket::ResolutionError` as the arm's class: the latter is
        # Ruby 3.3+ and this plugin's floor is 2.7 (§8 raises it to 3.1, still below 3.3), so
        # naming it directly would break Redmine 5.1's Ruby 3.2 cell. It is a subclass, so one
        # rescue covers both — measured on 3.3.6, where a real unresolvable host raises it —
        # and `Errno::ECONNREFUSED` is NOT a `SocketError`, which is what keeps the refused
        # socket on the generic arm below.
        rescue SocketError => e
          preflight_failure(
            started, "the name in #{@endpoint} did not resolve from Redmine",
            'Check the spelling of RRD_GOTENBERG_URL and that Redmine is on the same network ' \
            'as the container — with `internal: true` in the example compose file a ' \
            "container's name resolves only for services on that network. If both are right, " \
            "the resolver itself is unreachable: if that is temporary it clears on its own, " \
            "and if it is not, check Redmine's own DNS configuration.",
            detail: "#{e.class}: #{e.message}"
          )
        rescue StandardError => e
          preflight_failure(
            started, "nothing answered at #{@endpoint}",
            'Confirm the container is running and that Redmine can reach it at this ' \
            'address. With `internal: true` in the example compose file, Redmine has to be ' \
            'on the same Docker network.',
            detail: "#{e.class}: #{e.message}"
          )
        end

        def check_credential(started)
          if @credential.nil?
            return preflight_failure(
              started,
              'this Gotenberg endpoint is used without a credential, and Gotenberg has none ' \
              'by default',
              'Start the container with `--api-enable-basic-auth` and the ' \
              'GOTENBERG_API_BASIC_AUTH_USERNAME / GOTENBERG_API_BASIC_AUTH_PASSWORD ' \
              'environment variables set, then configure the same user and password for ' \
              'this engine. An unauthenticated PDF service on an internal network renders ' \
              'any HTML anybody can reach it with.',
              detail: "no credential is configured for #{@endpoint}",
              code: :engine_misconfigured
            )
          end

          # A REFUSED CREDENTIAL IS THIS ARM'S FINDING, and it used to be nobody's: the
          # authenticated `/version` probe answered 401, every arm read it as health, and
          # the run failed two checks later on "did not answer /version with a version".
          authenticated = request_get(VERSION_PATH, timeout_ms: PROBE_TIMEOUT_MS)
          memoise_version(authenticated)
          if authenticated.is_a?(Net::HTTPUnauthorized) || authenticated.is_a?(Net::HTTPForbidden)
            return preflight_failure(
              started, 'the render service refused the configured credential',
              'Check the user and password against GOTENBERG_API_BASIC_AUTH_USERNAME and ' \
              'GOTENBERG_API_BASIC_AUTH_PASSWORD on the container. They have to be the same ' \
              'pair on both sides.',
              detail: "an authenticated GET #{VERSION_PATH} answered #{authenticated.code}",
              code: :engine_misconfigured
            )
          end

          probe = post_unauthenticated_probe
          return nil if probe == :refused

          # AN ENDPOINT NOBODY CAN REACH HAS PROVED NOTHING ABOUT ITS AUTHENTICATION. This
          # arm cannot be reached with the service down any more — `check_reachable` runs
          # first and stops the sequence — but the guard stays, because "the check before
          # it already covered that" is how a check acquires a hole when somebody reorders.
          return nil if probe.to_s.start_with?('unreachable')

          # 400 and 415 are what an OPEN Gotenberg answers an empty form; 200 would be one
          # that somehow accepted it. Anything else got past `check_reachable` and is not a
          # statement about authentication, so it is reported as what it is.
          unless %w[200 400 415].include?(probe.to_s)
            return preflight_failure(
              started, "#{@endpoint} answered #{probe} on the conversion route",
              'That is not an answer about authentication. Confirm the address points at ' \
              "a Gotenberg's API root — it answers 401 unauthenticated, or 400 when it is " \
              'not enforcing a credential.',
              detail: "an unauthenticated POST to #{CONVERT_PATH} answered #{probe}"
            )
          end

          preflight_failure(
            started,
            'this Gotenberg endpoint answered the conversion route WITHOUT the configured ' \
            'credential',
            'The credential is configured here but the container is not enforcing it. Start ' \
            'it with `--api-enable-basic-auth` and both GOTENBERG_API_BASIC_AUTH_* ' \
            'environment variables set, and confirm nothing else (a proxy, a second ' \
            'listener) is exposing the same service unauthenticated.',
            detail: "an unauthenticated POST to #{CONVERT_PATH} answered #{probe}",
            code: :engine_misconfigured
          )
        rescue StandardError => e
          # `#preflight` MUST NEVER RAISE (technical-spec.md §5), and this was the one
          # transport call in the sequence with no rescue — found by an adversarial QA pass
          # against a real listener that answers the identity probe and then stops
          # listening, which is a container restart, an OOM kill or a `--force-recreate`
          # mid-run. `send_request` only converts the three TIMEOUT classes into
          # `TIMED_OUT`, so `Errno::ECONNREFUSED`, `EOFError`, `Errno::ECONNRESET` and
          # `SocketError` escaped from here — past `configuration_checks`, out of
          # `#preflight`, and into `spec/conformance`, which calls it with no rescue at all.
          #
          # THE PROMOTION IS WHAT MADE THIS A DEFECT RATHER THAN A SKIP: while this engine
          # was `verification: pending` a raise here became an "unavailable" skip; at
          # `corpus` it is one example with a raw stack trace reading as a plugin bug next
          # to twenty-two with the right message.
          #
          # The answer is the same shape `check_reachable`'s rescue already has — the
          # service went away, we cannot tell why, so `:engine_unavailable` and a message
          # naming more than one remedy.
          preflight_failure(
            started, "nothing answered at #{@endpoint}",
            'Confirm the container is still running and that Redmine can reach it at this ' \
            'address — it answered the first probe and then stopped, which is what a ' \
            'restart, an OOM kill or a `docker compose up --force-recreate` looks like ' \
            'from here.',
            detail: "#{e.class}: #{e.message}"
          )
        end

        # Returns `:refused` when the route rejected an unauthenticated caller, and the
        # status code otherwise. A transport error is deliberately NOT `:refused` — an
        # endpoint nobody can reach has not proved anything about its authentication, and
        # the round trip below is what will report that it is down.
        def post_unauthenticated_probe
          response = post_multipart(CONVERT_PATH, [], timeout_ms: PROBE_TIMEOUT_MS,
                                                      correlation_id: 'preflight',
                                                      credential: nil)
          return :unreachable if response.equal?(TIMED_OUT)
          return :refused if response.is_a?(Net::HTTPUnauthorized) || response.is_a?(Net::HTTPForbidden)

          response.code
        rescue StandardError => e
          "unreachable (#{e.class})"
        end

        def check_version(started)
          probed = version
          major = probed.to_s[/\A(\d+)\./, 1]

          if major.nil?
            return preflight_failure(
              started, "this endpoint did not answer #{VERSION_PATH} with a version",
              "Confirm #{@endpoint} is a Gotenberg service and that the credential is " \
              'accepted; `GET /version` answers a bare version string such as `8.35.0`.',
              detail: "#{VERSION_PATH} answered #{probed.to_s[0, 120].inspect}"
            )
          end

          return nil if major.to_i >= SUPPORTED_MAJOR

          preflight_failure(
            started, "this Gotenberg is version #{probed}, below the supported floor",
            "Upgrade the container to Gotenberg #{SUPPORTED_MAJOR} or later. The routes and " \
            'form fields this adapter uses are the version 8 ones.',
            detail: "#{VERSION_PATH} answered #{probed}", code: :engine_version_unsupported
          )
        end

        def check_javascript(started)
          parts = [file_part(INDEX_PART, JS_PROBE_DOCUMENT, 'text/html'),
                   field_part('failOnConsoleExceptions', 'true')]
          response = post_multipart(CONVERT_PATH, parts, timeout_ms: PROBE_TIMEOUT_MS,
                                                         correlation_id: 'preflight')
          return nil if response.is_a?(Net::HTTPConflict)

          # A TIMEOUT IS NOT A PASS. Treating it as one would make this check unable to
          # fail on exactly the service least worth trusting — the first draft did, and it
          # is the same shape as the `/health` probe two checks up.
          if response.equal?(TIMED_OUT)
            return preflight_failure(
              started, 'this Gotenberg did not answer the JavaScript check in time',
              "Confirm #{@endpoint} is answering conversions; a one-paragraph document " \
              "should come back well inside #{PROBE_TIMEOUT_MS}ms.",
              detail: "no answer to the JavaScript probe within #{PROBE_TIMEOUT_MS}ms"
            )
          end

          # ONLY A 200 MEANS JAVASCRIPT IS OFF. Every other status means the probe never
          # got a usable answer — a 503 from the container's own api-timeout, a 502 from a
          # proxy, a 413 against --api-body-limit — and the first version answered all of
          # them with "JavaScript is disabled, restart without --chromium-disable-javascript".
          # The operator restarts a container that never had that flag, nothing changes,
          # and the check says it again. INV-4: a remedy that provably does nothing is
          # worse than no remedy, and this project has now shipped that shape three times
          # (§Findings E-26 #6 and #7 are the other two).
          unless response.is_a?(Net::HTTPSuccess)
            return preflight_failure(
              started,
              "the JavaScript check could not be completed: #{@endpoint} answered " \
              "#{response.code}",
              'This is not a verdict about JavaScript — the probe never got a usable ' \
              "answer. Look at the container's log for this request, and run the check " \
              'again once it is answering conversions.',
              detail: "the JavaScript probe answered #{response.code}: #{body_excerpt(response)}"
            )
          end

          preflight_failure(
            started, 'this Gotenberg has JavaScript disabled',
            'Start the container WITHOUT `--chromium-disable-javascript`. This engine ' \
            'declares :javascript, :modern_javascript and :readiness_expression, and with ' \
            'JavaScript off Gotenberg silently ignores the readiness expression as well — ' \
            'so every chart would be missing from every report and nothing would fail.',
            detail: "a document whose script throws answered #{response.code} with " \
                    'failOnConsoleExceptions set; a live JavaScript engine answers 409',
            # THE VERDICT gets `:engine_misconfigured`; the two arms above — a timeout and
            # a non-success answer — deliberately keep `:engine_unavailable`, because
            # neither is a statement about JavaScript at all. That distinction is the
            # whole of HANDOVER's "identity before verdict" entry, and it would be undone
            # by moving the code up to `check_javascript`'s other exits.
            code: :engine_misconfigured
          )
        rescue StandardError => e
          preflight_failure(started, 'the JavaScript check could not be run',
                            "Confirm #{@endpoint} is reachable and answering conversions.",
                            detail: "#{e.class}: #{e.message}")
        end

        def unconfigured_failure(correlation_id)
          message =
            if @endpoint_error
              "the address configured for the Gotenberg render service cannot be used. " \
                "#{@endpoint_error}"
            else
              'no address is configured for the Gotenberg render service. Set ' \
                "RRD_GOTENBERG_URL in Redmine's environment to the container's address — " \
                'for example http://gotenberg:3000 — together with RRD_GOTENBERG_USERNAME ' \
                'and RRD_GOTENBERG_PASSWORD. There is no default: the obvious one would be ' \
                'this Redmine.'
            end

          # `:engine_misconfigured`, not `:engine_unavailable` (§Findings E-27 row 3).
          # Nothing has been reached and nothing is down: there is no address to reach, or
          # the one configured cannot be used. A retry cannot change that answer and
          # `RRD_GOTENBERG_URL` can.
          Failure.new(
            code: :engine_misconfigured, engine: ID, engine_version: 'unknown',
            correlation_id: correlation_id, duration_ms: 0, message: message,
            detail: @endpoint_error || 'RRD_GOTENBERG_URL is unset and no endpoint was injected'
          )
        end

        def check_hash(id, failure, duration_ms:)
          { id: id, title: CHECK_TITLES.fetch(id),
            state: failure ? :fail : :pass,
            detail: failure ? failure.message : nil,
            duration_ms: duration_ms,
            failure: failure }
        end

        def preflight_failure(started, what, remediation, detail:, code: :engine_unavailable)
          Failure.new(code: code, engine: ID, engine_version: @version || 'unknown',
                      correlation_id: 'preflight', duration_ms: (monotonic_ms - started).round,
                      message: "#{what}. #{remediation}", detail: detail)
        end

        def unauthorized_message
          'the render service refused the configured credential. Check the user and ' \
            'password against GOTENBERG_API_BASIC_AUTH_USERNAME and ' \
            'GOTENBERG_API_BASIC_AUTH_PASSWORD on the container.'
        end

        # --- THE TRANSPORT ----------------------------------------------------

        Part = Struct.new(:name, :filename, :content_type, :body)

        def file_part(filename, body, content_type)
          Part.new(FILES_FIELD, filename, content_type, body.to_s.dup.b)
        end

        def field_part(name, value)
          Part.new(name, nil, nil, value.to_s.dup.b)
        end

        # Built by hand rather than with a gem: `multipart/form-data` is forty lines, and
        # the alternative is a dependency in the one layer that must stay loadable in a
        # bare RSpec process on four Ruby versions.
        #
        # The boundary is random per request and is asserted absent from every part before
        # it is used — a body containing the boundary would split the request in a place
        # this adapter did not choose.
        def encode_multipart(parts)
          boundary = "----rrd#{SecureRandom.hex(16)}"
          boundary = "----rrd#{SecureRandom.hex(16)}" while parts.any? { |p| p.body.include?(boundary) }

          body = +''.b
          parts.each do |part|
            body << "--#{boundary}\r\n".b
            disposition = +"Content-Disposition: form-data; name=\"#{part.name}\""
            disposition << "; filename=\"#{part.filename}\"" if part.filename
            body << "#{disposition}\r\n".b
            body << "Content-Type: #{part.content_type}\r\n".b if part.content_type
            body << "\r\n".b << part.body << "\r\n".b
          end
          body << "--#{boundary}--\r\n".b

          [body, "multipart/form-data; boundary=#{boundary}"]
        end

        def post_multipart(path, parts, timeout_ms:, correlation_id:, credential: :default)
          body, content_type = encode_multipart(parts)
          request = Net::HTTP::Post.new(uri_for(path))
          request['Content-Type'] = content_type
          # Gotenberg's own correlation header, so a trace in its log can be joined to a
          # diagnostics row here. It is a correlation id and nothing else — there is no
          # header on this request a credential could travel in except the one the
          # operator configured.
          request['Gotenberg-Trace'] = sanitize_header(correlation_id)
          request.body = body
          send_request(request, timeout_ms: timeout_ms, credential: credential)
        end

        def request_get(path, timeout_ms:, credential: :default)
          send_request(Net::HTTP::Get.new(uri_for(path)), timeout_ms: timeout_ms,
                                                          credential: credential)
        end

        def send_request(request, timeout_ms:, credential: :default)
          chosen = credential.equal?(:default) ? @credential : credential
          request.basic_auth(chosen[0], chosen[1]) if chosen

          seconds = [timeout_ms / 1000.0, 0.001].max
          http_client.call(uri_for('/'), request, seconds)
        rescue Net::ReadTimeout, Net::OpenTimeout, Timeout::Error
          TIMED_OUT
        end

        # The injectable seam. A default that builds a real connection, and a `http:`
        # constructor argument the specs hand a recording double — the same shape the
        # asset fetcher's tests use, and for the same reason: a transport asserted by
        # reading is a transport nobody has watched.
        def http_client
          @http || DEFAULT_HTTP
        end

        # `nil` IS THE THIRD POSITIONAL ARGUMENT AND IT IS LOAD-BEARING. `Net::HTTP.start`'s
        # signature is `start(address, port = nil, p_addr = :ENV, …)`, so passing only
        # keywords leaves `p_addr` at `:ENV` and the socket goes wherever `http_proxy` /
        # `HTTP_PROXY` points — NOT to the endpoint the operator configured.
        #
        # MEASURED by an independent review, against a listening fake proxy:
        #
        #     POST http://gotenberg.internal:3000/forms/chromium/convert/html
        #     Authorization: Basic cnJkOnMzY3JldA==     <-- the operator's credential
        #     Content-Type: multipart/form-data; …      <-- the whole rendered report
        #
        # So an ambient proxy variable — which a Redmine host very often has, for entirely
        # unrelated reasons — silently exfiltrated both the credential and issue data that
        # had already been through the visibility filter. It is invisible in every test and
        # in CI for one reason: `URI::Generic#find_proxy` returns nil for `127.*` and `::1`,
        # and every spec and both CI containers are on loopback. CLAUDE.md §3's
        # "passes locally, fails in production", with a security consequence.
        #
        # `nil` disables proxying outright. That is the right default for this adapter and
        # not a limitation: the endpoint is operator configuration, the document is already
        # complete, and INV-8 is that the renderer is never the thing holding the network —
        # a proxy is one more thing holding it. An operator who genuinely needs one should
        # have to say so, and no parameter for it exists yet.
        DEFAULT_HTTP = lambda do |base, request, seconds|
          Net::HTTP.start(base.host, base.port, nil,
                          use_ssl: base.scheme == 'https',
                          open_timeout: seconds, read_timeout: seconds,
                          write_timeout: seconds) do |http|
            http.request(request)
          end
        end

        # `URI.join(base, '/version')` DISCARDS the base's path, because an absolute-path
        # reference replaces it — so an endpoint served under `--api-root-path /gotenberg/`
        # would have been called at `/version` and answered 404, which reads as "this is
        # not a Gotenberg". The leading slash is stripped so the join is relative to the
        # endpoint, and `#validate_endpoint!` guarantees the trailing slash that makes a
        # relative join keep the last segment.
        def uri_for(path)
          URI.join(@endpoint, path.sub(%r{\A/+}, ''))
        end

        # A CR or LF in a header value splits the request. `correlation_id` is generated
        # by this plugin, so this is a belt on top of braces — and it is the kind of belt
        # that costs nothing and is missing from every log of a header-injection incident.
        def sanitize_header(value)
          value.to_s.gsub(/[[:space:]]+/, ' ').strip[0, 200]
        end

        # `[endpoint, error]`. Never raises — see the constructor.
        def resolve_endpoint(configured)
          return [UNCONFIGURED, nil] if configured.to_s.strip.empty?

          [validate_endpoint!(configured), nil]
        rescue ArgumentError => e
          [UNCONFIGURED, e.message]
        end

        def validate_endpoint!(value)
          raw = value.to_s

          # THE RAW STRING IS ASKED ABOUT `?` AND `#` BEFORE THE PARSER GETS A SAY, and
          # an independent review is why (E-27 row 9's fix, reviewed). The first version
          # checked `uri.query`/`uri.fragment` off the PARSED value — and
          # `URI.parse('gotenberg:3000/?token=abc')` is an OPAQUE URI whose `#query` is
          # nil, so the guard never fired for exactly the schemeless spellings the
          # endpoint spec calls "what an operator actually types", and the value fell
          # through to an arm whose message interpolated it, token and all. A `?` or `#`
          # anywhere in an endpoint is meaningless to this adapter under every parse
          # (`uri_for` joins request paths, and resolution drops the base's query and
          # fragment), so the raw test refuses nothing legitimate and no parser quirk
          # can carry a LITERAL `?` or `#` past it. The claim stops there, deliberately:
          # a percent-encoded `%3F` is not a query to any parser and is not decoded
          # here, and a secret an operator writes into the PATH is preserved and shown,
          # because the path is part of the endpoint's identity (`--api-root-path`).
          # The refusals are about the slots credentials ride in — userinfo, query,
          # fragment — not about every byte sequence an operator could regret.
          if raw.include?('?') || raw.include?('#')
            raise ArgumentError,
                  'a Gotenberg endpoint must not carry a query string or fragment. ' \
                  'Requests are joined onto the endpoint and drop both, so a token ' \
                  'there would authenticate nothing — and it would then travel in ' \
                  'every failure message, including the ones e-mailed to report ' \
                  'recipients. This adapter authenticates with RRD_GOTENBERG_USERNAME ' \
                  'and RRD_GOTENBERG_PASSWORD.'
          end

          uri = URI.parse(raw)

          # `http://user:pass@host` IS REFUSED, and it is refused rather than redacted.
          #
          # It is the most natural way an operator writes basic auth for a service URL, and
          # this adapter does not use it — `DEFAULT_HTTP` connects with host and port only,
          # so the credential would be silently ignored AND carried in `@endpoint`, which is
          # interpolated into failure messages this file produces, and into details as well.
          # (That clause used to carry a COUNT, which went stale twice — six, when it was nine,
          # and then ten — and was then replaced by "MOST of the failure messages", which a
          # review measured as false too: ten of thirty-six message-bearing sites. A number
          # nobody updates is worse than none, and a superlative nobody counts is worse than
          # both. The property does not depend on either.) `Failure#message` reaches the
          # diagnostics panel, the scheduled-report failure MAIL — sent to the schedule's
          # OWNER, not to every recipient, which the mailer view says in as many words and a
          # review corrected here — and `Snapshot`'s persisted row. So the password would be
          # displayed, e-mailed and stored, while not authenticating anything. The severity
          # does not need the inflated audience. Found by an independent review, measured end
          # to end.
          #
          # Redacting would fix the leak and keep the silent non-authentication. Refusing
          # fixes both, and the message says where the credential actually goes.
          unless uri.userinfo.nil?
            raise ArgumentError,
                  'a Gotenberg endpoint must not carry a user or password in the URL. ' \
                  'This adapter authenticates with RRD_GOTENBERG_USERNAME and ' \
                  'RRD_GOTENBERG_PASSWORD; a credential in the URL would be ignored, and ' \
                  'it would then travel in every failure message, including the ones ' \
                  'e-mailed to report recipients.'
          end

          # THE VALUE IS DELIBERATELY NOT IN THIS MESSAGE, and neither arm below carries
          # it. A schemeless spelling with a secret in it — `user:pass@gotenberg:3000`,
          # `gotenberg:3000/token` — survives to here, and this message travels exactly
          # where the userinfo comment above says: the diagnostics panel, the
          # scheduled-report failure MAIL, and a persisted `Snapshot` row. The reviewer
          # demonstrated `hunter2` arriving in a preflight message through this arm. An
          # operator who wants the rejected value has RRD_GOTENBERG_URL in front of them;
          # a report recipient must never have it.
          unless ENDPOINT_SCHEMES.include?(uri.scheme) && !uri.host.to_s.empty?
            raise ArgumentError,
                  'the configured value is not a usable Gotenberg endpoint. It must be ' \
                  "an #{ENDPOINT_SCHEMES.join('/')} URL naming a host — for example " \
                  'http://gotenberg:3000 — and it is operator configuration, never ' \
                  'derived from a document, a template or a request parameter.'
          end

          # A trailing slash so `URI.join` cannot eat the last path segment of an endpoint
          # served under a root path (`--api-root-path`).
          uri.path = "#{uri.path}/" unless uri.path.end_with?('/')
          uri.to_s.freeze
        rescue URI::InvalidURIError
          # `e.message` REPEATS THE RAW VALUE (`bad URI "http://…"`), so interpolating it
          # is the same leak as interpolating the value — neither travels.
          raise ArgumentError,
                'the configured value could not be parsed as a URL at all. It must be ' \
                "an #{ENDPOINT_SCHEMES.join('/')} URL naming a host, such as " \
                'http://gotenberg:3000.'
        end

        # THE IDENTITY AND CREDENTIAL PROBES ALREADY CARRY THE VERSION, and until E-27
        # row 10 both threw it away — so a preflight against a healthy service fetched
        # `/version` again in `check_version` for a body two earlier probes had already
        # read. Memoised ONLY when the body is version-shaped: `check_reachable`'s probe
        # can answer 200 with anything (an nginx greeting page, a Redmine login), and a
        # junk body stored here would become the `engine_version` stamped into every
        # failure message. A non-version body is left for `check_version` to fetch and
        # report in its own words.
        def memoise_version(response)
          return unless response.is_a?(Net::HTTPSuccess)

          # THE TOKEN, NOT THE BODY — and the class is dotted-words, not "up to the
          # first whitespace". `/\A\d+\.\S*/` was the first spelling, and an adversarial
          # QA pass fed it `8.35.0<script>…` — no whitespace, so the WHOLE body was
          # memoised and stamped into `engine_version`, which travels in mail and
          # Snapshot rows, the same surfaces the endpoint messages are kept clean for.
          # `\w` cuts at the first character no version carries; a suffix like `-rc1`
          # is dropped rather than trusted, which is the right trade for a stamp.
          token = response.body.to_s.strip[/\A\d+(?:\.\w+)*/]
          @version = token if token
        end

        def credential_from_env
          user = ENV['RRD_GOTENBERG_USERNAME'].to_s
          password = ENV['RRD_GOTENBERG_PASSWORD'].to_s
          return nil if user.empty? && password.empty?

          [user, password]
        end

        # nil means "no credential", and an EMPTY user or password is nil rather than a
        # credential made of blanks — an operator who cleared one field of two has not
        # configured authentication, and treating `["", ""]` as a credential would make
        # the check above pass on a service that refuses everybody.
        def normalize_credential(pair)
          return nil if pair.nil?

          user, password = Array(pair)
          return nil if user.to_s.empty? || password.to_s.empty?

          [user.to_s, password.to_s].freeze
        end

        # --- RESULTS ----------------------------------------------------------

        def capability_degradations(request)
          missing = Capabilities.negotiate(required: request.required_capabilities,
                                           essential: [], available: CAPABILITIES)[:missing]
          missing.map do |capability|
            Degradation.new(capability: capability, detail: "gotenberg cannot #{capability}")
          end
        end

        def body_excerpt(response)
          response.body.to_s.strip[0, 300]
        end

        def timeout_failure(request, started)
          failure(request, :timeout, 'the report took too long to draw',
                  detail: "no answer from #{@endpoint} within #{request.timeout_ms}ms",
                  started: started)
        end

        def transport_failure(request, error, started)
          failure(request, :engine_unavailable,
                  'the render service could not be reached',
                  detail: "#{@endpoint}: #{error.class}: #{error.message}", started: started)
        end

        def failure(request, code, message, detail:, started:)
          Failure.new(code: code, message: message, detail: detail, engine: ID,
                      # `@version` and not `version`: probing here would call the very
                      # service that just failed to answer.
                      engine_version: @version || 'unknown',
                      duration_ms: (monotonic_ms - started).round,
                      correlation_id: request.correlation_id)
        end

        def mm_to_in(millimetres)
          (millimetres.to_f / MM_PER_INCH).round(4)
        end

        def monotonic_ms
          Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000.0
        end
      end

      Registry.register(Gotenberg::ID, Gotenberg)
    end
  end
end
