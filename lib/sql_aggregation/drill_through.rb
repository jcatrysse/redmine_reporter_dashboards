# frozen_string_literal: true

# Hash#to_query. Always loaded under Redmine (it is part of ActiveSupport's core
# extensions); required explicitly so this file also works in the plugin's bare
# RSpec suite, which boots ActiveSupport without Rails.
require 'active_support/core_ext/object/to_query'

module SqlAggregation
  # Builds Redmine issue-list URLs that drill through from one chart element to
  # exactly the issues it represents, in the context of the report's own query.
  #
  # --- Why a copy of the query ---
  #
  # A saved query cannot be extended through a URL: QueriesHelper#retrieve_query
  # short-circuits on params[:query_id] and ignores any f/op/v that follow, and
  # Query#as_params returns a bare {query_id: id} for a persisted record. A
  # drill-down URL therefore has to REPLICATE the report query's parameters and
  # add the dimension filter, with set_filter=1.
  #
  # Rather than reimplement Redmine's parameter names, we hand the inherited
  # attributes to an unsaved IssueQuery and let its own #as_params serialise
  # them: new_record? is true, so it returns the full long form
  # (f / op / v / c / group_by / t / sort / set_filter). Filters, columns,
  # grouping, totals and sort order are inherited in one step, and the URL stays
  # correct if Redmine ever renames a parameter.
  #
  # --- Merging the dimension filter ---
  #
  # Redmine allows exactly one filter per field, so a bucket filter has to be
  # merged into the inherited set:
  #
  #   * field not filtered yet            -> add it
  #   * field filtered, non-date          -> REPLACE it. A bucket is by
  #     construction a subset of whatever the query filtered on that field (if it
  #     were not, the bucket would be empty and no element would exist to click),
  #     so replacing cannot widen the result.
  #   * field filtered, date              -> INTERSECT, because replacing a date
  #     range could widen it. Only absolute operators (><, >=, <=, =) can be
  #     intersected at render time; a relative inherited range (t-, w, m, >t-, …)
  #     falls back to the bucket range and logs at debug level. That is the one
  #     case where the drill-down count can exceed the charted count.
  #
  # --- Safety rules ---
  #
  # * Query#add_filter silently ignores a field that is not in available_filters,
  #   which would drop the user on a wider list than the element they clicked.
  #   Every field is checked against available_filters first; an unavailable field
  #   yields no URL and one log line per render.
  # * Only the operators this plugin generates are accepted (OPERATORS); values
  #   are percent-encoded by Hash#to_query and re-validated by Redmine when the
  #   issue list is rendered.
  # * A URL longer than the (configurable) cap yields nil rather than a truncated,
  #   wrong URL.
  # * No URL is better than a wrong URL: every failure path returns nil and the
  #   template renders the element as non-clickable.
  #
  # URLs are ABSOLUTE (Setting.protocol + Setting.host_name, which may include a
  # path prefix), following the VersionDrop idiom, because the same markup is
  # exported to PDF where there is no request context to resolve a relative path.
  class DrillThrough
    # Conservative default: proxies and older browsers start truncating well
    # before the ~8k a stock nginx accepts. Override with the tag's drill_max_url.
    DEFAULT_MAX_URL_LENGTH = 2000

    # Redmine filter types whose values are dates, so a merge must intersect
    # instead of replace.
    DATE_TYPES = %i[date date_past].freeze

    # Fallback when Query#type_for cannot answer (a stubbed or future Query):
    # treat a date-looking core field as a date field, so the merge fails safe
    # towards intersection.
    DATE_FIELD_NAME_RE = /(?:_on|_date)\z/

    # What Query#validate_query_filters accepts as a date filter value: an ISO date,
    # optionally with a time it never needs here.
    ISO_DATE_RE = /\A(\d{4})-(\d{2})-(\d{2})(?:T.*)?\z/

    # Operators this plugin emits. Anything else never reaches a URL.
    OPERATORS = %w[= >< >= <= * !* c o].freeze

    # What a URL inherits, most complete first. Filters decide correctness;
    # columns, totals, grouping and sort order are cosmetic, so an over-long URL
    # sheds them instead of losing the link:
    #
    #   :all          f/op/v + c + t + group_by + sort
    #   :no_columns   f/op/v + group_by + sort      (c and t are the long ones)
    #   :filters_only f/op/v
    #
    # `drill_inherit: filters` starts at :filters_only on purpose — see the tag.
    INHERIT_LEVELS  = %i[all no_columns filters_only].freeze
    COSMETIC_PARAMS = { no_columns: %i[c t], filters_only: %i[c t group_by sort] }.freeze

    # Returns a builder, or nil when no usable base URL can be produced (no
    # query, no host settings, an unexpected Query API). nil means "no
    # drill-through", which every caller must treat as a supported outcome.
    def self.build(query, max_url_length: DEFAULT_MAX_URL_LENGTH, inherit: :all)
      return nil if query.nil?

      builder = new(query, max_url_length: max_url_length, inherit: inherit)
      return builder if builder.available?

      Rails.logger.warn('[sql_aggregation] drill-through unavailable: no base URL could be built ' \
                        'for the report query')
      nil
    rescue StandardError => e
      Rails.logger.warn("[sql_aggregation] drill-through setup failed: #{e.class}: #{e.message}")
      nil
    end

    def initialize(query, max_url_length: DEFAULT_MAX_URL_LENGTH, inherit: :all)
      @query          = query
      @max_url_length = max_url_length.to_i
      @max_url_length = DEFAULT_MAX_URL_LENGTH unless @max_url_length.positive?
      @inherit        = INHERIT_LEVELS.include?(inherit) ? inherit : :all
      @logged_fields  = []
      @cache          = {}
    end

    # Set once a URL had to shed its inherited columns/totals to fit, so a
    # template can say so instead of leaving the reader wondering.
    attr_reader :degraded

    alias degraded? degraded

    def available?
      !base_url.nil?
    end

    # The report query itself, with no dimension filter added.
    def base_url
      return @base_url if defined?(@base_url)

      @base_url = url_for([])
    end

    # descriptors — Array of filter descriptors ({'field','operator','values'},
    # String or Symbol keys). nil entries mean "no extra constraint", so
    # url_for([nil]) is the report query unchanged — a valid drill-down for the
    # `total` funnel stage. Callers that treat a nil filter as "inexpressible"
    # (every dimension bucket does) must not call this at all.
    #
    # Returns nil whenever the URL cannot be built or validated.
    def url_for(descriptors)
      list = Array(descriptors).compact
      return @cache[list] if list.size <= 1 && @cache.key?(list)

      url = build_url(list)
      @cache[list] = url if list.size <= 1
      url
    end

    private

    def build_url(list)
      bucket = combine(list)
      return nil if bucket.nil?

      filters = inherited_filters
      bucket.each do |field, descriptor|
        merged = merge_inherited(filters[field], descriptor, field)
        return nil if merged.nil?

        # Again, on the RESULT: an intersection synthesises an operator nobody has
        # validated yet (>< becomes >= or <= when one end opens up), and a merge can
        # hand back the inherited filter with an operator of its own.
        operator = fetch(merged, :operator).to_s
        return nil unless operator_allowed?(field, operator)

        # Exactly the two keys Redmine's own filters hash carries; the field name
        # is the Hash key, so a stray :field inside the options is noise.
        filters[field] = { operator: operator, values: Array(fetch(merged, :values)) }
      end

      fit(filters, bucket.keys)
    rescue StandardError => e
      # Once per render: a systemic failure here would otherwise log one line per
      # chart element.
      unless @logged_failure
        @logged_failure = true
        Rails.logger.warn("[sql_aggregation] drill-through URL could not be built: " \
                          "#{e.class}: #{e.message}")
      end
      nil
    end

    # ------------------------------------------------------------------
    # Length budget
    # ------------------------------------------------------------------

    # Builds the URL at the requested inheritance level and, if it does not fit,
    # sheds the cosmetic parameters rather than the link. Columns and totals go
    # first (a report with twenty columns spends hundreds of characters on c[]
    # alone), then grouping and sort. The filters are never touched: they are what
    # makes the URL correct.
    #
    # Returns nil only when even a filters-only URL is too long — and says so,
    # with the real length and the cap, instead of failing silently.
    def fit(filters, fields)
      label  = fields.empty? ? 'the report query' : fields.join(', ')
      levels = INHERIT_LEVELS[INHERIT_LEVELS.index(@inherit)..]
      url    = nil

      levels.each_with_index do |level, index|
        url = "#{path}?#{query_string(filters, level)}"
        if url.length <= @max_url_length
          # Only now, when a shortened URL is actually handed out. Setting the flag
          # while walking down the ladder would report a degradation for elements
          # that ended up with no URL at all.
          @degraded = true if index.positive?
          return url
        end

        log_degraded(label, url.length, levels[index + 1]) if levels[index + 1]
      end

      log_too_long(label, url.to_s.length)
      nil
    end

    # Once per render: a report whose columns push every URL over the cap would
    # otherwise log one line per chart element.
    def log_degraded(label, length, next_level)
      return if @logged_degraded

      @logged_degraded = true
      Rails.logger.warn("[sql_aggregation] drill-through URL for #{label} is #{length} " \
                        "characters, over the #{@max_url_length} cap — retrying without the " \
                        "inherited #{COSMETIC_PARAMS[next_level].join('/')} (the filters are kept, " \
                        'so the issue list still matches the chart element)')
    end

    def log_too_long(label, length)
      return if @logged_too_long

      @logged_too_long = true
      Rails.logger.warn("[sql_aggregation] drill-through URL for #{label} is still " \
                        "#{length} characters with filters alone, over the #{@max_url_length} cap " \
                        '— no URL for those elements (raise drill_max_url to allow a longer one)')
    end

    # ------------------------------------------------------------------
    # Descriptor handling
    # ------------------------------------------------------------------

    # Validates and normalises the supplied descriptors into
    # { field => {operator:, values:} } with Redmine's own symbol keys.
    # Two descriptors on the same field are combined (a crosstab cell may put the
    # row and the series filter on one field); nil when that is impossible.
    def combine(list)
      combined = {}
      list.each do |raw|
        descriptor = normalize(raw)
        return nil if descriptor.nil?

        field = descriptor[:field]
        return nil unless filter_available?(field)
        return nil unless operator_allowed?(field, descriptor[:operator])
        return nil unless date_values_usable?(field, descriptor)

        if (previous = combined[field])
          descriptor = combine_same_field(previous, descriptor, field)
          return nil if descriptor.nil?
        end
        combined[field] = descriptor
      end
      combined
    end

    def normalize(raw)
      return nil unless raw.respond_to?(:[])

      field    = fetch(raw, :field).to_s
      operator = fetch(raw, :operator).to_s
      return nil if field.empty?

      unless OPERATORS.include?(operator)
        Rails.logger.warn("[sql_aggregation] refusing drill-through operator #{operator.inspect} " \
                          "for #{field}")
        return nil
      end

      values = Array(fetch(raw, :values)).map(&:to_s)
      values = [''] if values.empty?
      { field: field, operator: operator, values: values }
    end

    # Accepts both the String keys the Liquid result uses and the Symbol keys
    # Redmine's own filters hash uses.
    def fetch(hash, key)
      hash[key.to_s] || hash[key.to_sym]
    rescue StandardError
      nil
    end

    # A date field's values have to BE dates, whether or not the query already
    # filters that field: Redmine validates them and renders "Date is invalid"
    # instead of a list, so a link would be broken rather than merely wide. The
    # case this catches is a date-format custom field used as a dimension, whose
    # buckets carry the raw stored value.
    def date_values_usable?(field, descriptor)
      return true unless date_filter?(field)
      return true unless date_bounds(descriptor) == :relative

      unless @logged_fields.include?(field)
        @logged_fields << field
        Rails.logger.warn("[sql_aggregation] #{field.inspect} is a date filter but the bucket value " \
                          "#{descriptor[:values].inspect} is not a date Redmine accepts — no " \
                          'drill-through URL for those elements')
      end
      false
    end

    # Row filter and series filter landing on the same field. For a date field
    # that is a genuine intersection (period x age both bucket created_on); for
    # anything else Redmine cannot AND two filters on one field, so unless the
    # two are identical the cell is inexpressible.
    def combine_same_field(first, second, field)
      return first if first == second
      return nil unless date_filter?(field)

      intersect_dates(first, second, field)
    end

    # ------------------------------------------------------------------
    # Merging into the inherited filters
    # ------------------------------------------------------------------

    def merge_inherited(inherited, bucket, field)
      return bucket if inherited.nil?
      return bucket unless date_filter?(field)

      intersect_dates(inherited, bucket, field)
    end

    def intersect_dates(inherited, bucket, field)
      outer = date_bounds(inherited)
      inner = date_bounds(bucket)

      # The BUCKET's own dates are what make the element specific, so they are
      # checked first. When they cannot be read as dates — a date-format custom
      # field holding something that is not one — there is nothing to narrow with,
      # and falling back to the inherited filter alone would put the report's whole
      # date range behind one chart element. Refuse instead.
      if inner == :relative
        Rails.logger.debug("[sql_aggregation] the #{field} bucket carries no usable date " \
                           "(#{Array(fetch(bucket, :values)).inspect}) — no drill-through URL")
        return nil
      end

      return bucket if outer == :any     # "is set" ∩ range = range

      if outer == :relative
        Rails.logger.debug("[sql_aggregation] the report query filters #{field} with the relative " \
                           "operator #{operator_of(inherited).inspect}, which cannot be intersected " \
                           'at render time — the drill-down falls back to the bucket range and can ' \
                           'show more issues than the chart element')
        return bucket
      end

      if outer == :none                  # inherited "none": only "none" survives
        return inner == :none ? bucket : nil
      end

      # The inherited filter carries absolute bounds from here on.
      return nil       if inner == :none # a NULL date is inside no range
      return inherited if inner == :any  # "is set" adds nothing to a range

      # Backstop: every symbolic case is handled above, and the arithmetic below
      # needs two [from, to] pairs. Without this, a missed case would reach
      # Symbol#[] — which answers "n" instead of raising — and only fail later, as
      # a rescued comparison error rather than a refusal.
      return nil unless outer.is_a?(Array) && inner.is_a?(Array)

      from = [outer[0], inner[0]].compact.max
      to   = [outer[1], inner[1]].compact.min
      return bucket if from.nil? && to.nil?
      # Disjoint: the report query and the bucket do not overlap at all. Reachable
      # for a zero-count period bucket outside the query's own date filter. An
      # inverted >< range would work (Redmine returns nothing) but reads as a bug;
      # no URL says the same thing honestly.
      return nil if from && to && from > to

      range_filter(field, from, to)
    end

    # [from, to] for an absolute date filter (either end may be nil = open), or
    # :any / :none / :relative. Date granularity is enough: Redmine's own date
    # filters are day-based.
    def date_bounds(filter)
      values = Array(fetch(filter, :values))
      case operator_of(filter)
      when '><' then absolute(parse_date(values[0]), parse_date(values[1]))
      when '>=' then absolute(parse_date(values[0]), nil)
      when '<=' then absolute(nil, parse_date(values[0]))
      when '='  then (day = parse_date(values[0])) ? [day, day] : :relative
      when '*'  then :any
      when '!*' then :none
      else :relative
      end
    end

    # An absolute operator whose value did not parse carries no usable bound;
    # treating it as relative keeps the merge on the safe (bucket-range) path
    # instead of silently dropping the constraint.
    def absolute(from, to)
      return :relative if from.nil? && to.nil?

      [from, to]
    end

    def operator_of(filter)
      fetch(filter, :operator).to_s
    end

    # Deliberately NOT Date.parse: that reads "30" as the 30th of the current month
    # and would invent a bound out of a value Redmine itself rejects. This is the
    # exact shape Query#validate_query_filters accepts for a date filter.
    def parse_date(value)
      match = ISO_DATE_RE.match(value.to_s.strip)
      return nil unless match

      Date.new(match[1].to_i, match[2].to_i, match[3].to_i)
    rescue StandardError # 2026-02-31 parses as a match but is not a date
      nil
    end

    def range_filter(field, from, to)
      if from && to
        { field: field, operator: '><', values: [iso(from), iso(to)] }
      elsif from
        { field: field, operator: '>=', values: [iso(from)] }
      else
        { field: field, operator: '<=', values: [iso(to)] }
      end
    end

    def iso(date)
      date.strftime('%Y-%m-%d')
    end

    # ------------------------------------------------------------------
    # Serialisation
    # ------------------------------------------------------------------

    # Hash#to_query sorts its keys, so the same filter set always yields the same
    # URL — which is what makes these URLs testable and cache-friendly.
    def query_string(filters, level = :all)
      copy.filters = filters
      params = copy.as_params.reject { |_key, value| value.nil? || value == '' }
      # reject, not Hash#except: that one is Ruby 3.0 core and this plugin still
      # supports the 2.7 floor Redmine 5.1 declares.
      if (dropped = COSMETIC_PARAMS[level])
        # Compared as strings: as_params uses Symbol keys today, and this file's
        # whole premise is that Redmine's serialisation may change under us.
        params = params.reject { |key, _value| dropped.any? { |name| name.to_s == key.to_s } }
      end
      # Redmine's own "no filters" marker (see QueriesHelper#query_as_hidden_field_tags):
      # without it, build_from_params falls back to IssueQuery's default
      # status_id=o and the drill-down would be narrower than the report.
      params[:f] = [''] if filters.empty?
      params.to_query
    end

    def path
      @path ||= begin
        identifier = project_identifier
        identifier ? "#{host}/projects/#{identifier}/issues" : "#{host}/issues"
      end
    end

    # Absolute, like VersionDrop: the same markup is exported to PDF, where a
    # relative path has nothing to resolve against.
    def host
      "#{Setting.protocol}://#{Setting.host_name}"
    end

    # A query without a project drills through to the global issue list; its
    # inherited project_id filter, if any, travels in f/op/v by itself.
    def project_identifier
      project = @query.project
      return nil if project.nil?

      # Redmine routes accept either, so fall back to the id for the (impossible
      # in practice) project without an identifier.
      identifier = project.identifier.to_s.strip
      identifier = project.id.to_s if identifier.empty?
      identifier.empty? ? nil : identifier
    end

    # One reusable unsaved IssueQuery: #as_params is not memoised, so assigning
    # #filters and re-reading the params is all a second URL needs. Building a
    # fresh IssueQuery per chart element would allocate thousands of AR objects
    # on a large crosstab.
    def copy
      @copy ||= begin
        query = IssueQuery.new(name: '_', project: @query.project)
        query.filters         = {}
        query.column_names    = @query.column_names
        query.group_by        = @query.group_by
        query.totalable_names = @query.totalable_names
        query.sort_criteria   = @query.sort_criteria
        query
      end
    end

    # Shallow dup per call: entries are only ever replaced as a whole, never
    # mutated, so the report query's own filters hash is never touched.
    def inherited_filters
      @inherited_filters ||= (@query.filters || {}).each_with_object({}) do |(field, options), memo|
        memo[field.to_s] = options
      end
      @inherited_filters.dup
    end

    def filter_available?(field)
      return true if available_filter_keys.include?(field)

      unless @logged_fields.include?(field)
        @logged_fields << field
        Rails.logger.warn("[sql_aggregation] #{field.inspect} is not an available issue-list filter " \
                          '(a custom field needs is_filter and must be enabled for the project and ' \
                          'tracker) — no drill-through URL for those elements')
      end
      false
    end

    def available_filter_keys
      @available_filter_keys ||= copy.available_filters.keys.map(&:to_s)
    rescue StandardError => e
      Rails.logger.warn("[sql_aggregation] available_filters could not be read: #{e.class}: #{e.message}")
      @available_filter_keys = []
    end

    # Redmine validates the operator against the filter TYPE
    # (Query#operators_by_filter_type) and renders "filter is invalid" for a
    # combination it does not allow — :list_status has no !*, a boolean custom
    # field is a plain :list with only = and !. Refuse those here instead, so the
    # element simply is not clickable.
    def operator_allowed?(field, operator)
      allowed = allowed_operators(field)
      return true if allowed.nil? || allowed.empty?
      return true if allowed.include?(operator)

      unless @logged_fields.include?(field)
        @logged_fields << field
        Rails.logger.warn("[sql_aggregation] Redmine does not allow the operator #{operator.inspect} " \
                          "on #{field.inspect} — no drill-through URL for those elements")
      end
      false
    end

    def allowed_operators(field)
      @allowed_operators ||= {}
      return @allowed_operators[field] if @allowed_operators.key?(field)

      type = filter_type(field)
      table = copy.respond_to?(:operators_by_filter_type) ? copy.operators_by_filter_type : nil
      @allowed_operators[field] = (type && table) ? table[type] : nil
    rescue StandardError
      @allowed_operators[field] = nil
    end

    def filter_type(field)
      @filter_types ||= {}
      return @filter_types[field] if @filter_types.key?(field)

      @filter_types[field] = copy.respond_to?(:type_for) ? copy.type_for(field) : nil
    rescue StandardError
      @filter_types[field] = nil
    end

    def date_filter?(field)
      @date_filter ||= {}
      return @date_filter[field] if @date_filter.key?(field)

      type = filter_type(field)
      @date_filter[field] = type ? DATE_TYPES.include?(type) : DATE_FIELD_NAME_RE.match?(field)
    end
  end
end
