# frozen_string_literal: true

module RedmineReporterDashboards
  module Liquid
    module Drops
      # Every URL this layer emits is ABSOLUTE, and that is a design decision with a
      # measurable payoff rather than a style preference.
      #
      # `Report#build_content` in the base plugin spends 38 lines plus a regexp fallback
      # rewriting relative hrefs into absolute ones after the document is built, because
      # a PDF engine has no request context to resolve `/issues/42` against. Rewriting
      # after the fact means guessing which attributes are URLs, and the guess is a
      # Nokogiri pass over the whole document that runs on every render.
      #
      # Absolute-by-construction beats rewriting-after-the-fact: there is nothing to
      # guess, nothing to walk, and no attribute the rewriter forgot. §3.2 names this as
      # what makes those 38 lines unnecessary.
      #
      # --- WHY `Setting`, AND NOT A ROUTE HELPER ---
      #
      # `url_for(only_path: false)` needs `default_url_options`, which is request state.
      # A scheduled report has no request. `Setting.protocol` and `Setting.host_name`
      # are what Redmine itself uses for mail, which is the other place it builds a URL
      # with no request — so this is Redmine's own answer to the same question, not a
      # second one.
      #
      # `Setting.host_name` may carry a path prefix (`redmine.example/redmine`), and it
      # is preserved: an install mounted under a sub-path is exactly the install where a
      # hand-built URL goes wrong.
      module AbsoluteUrl
        module_function

        # Memoised per render is not worth it — `Setting` is itself cached by Redmine,
        # and a memo here would be a stale base URL for the lifetime of a drop that
        # outlived a settings change.
        def base_url
          "#{::Setting.protocol}://#{::Setting.host_name}"
        end

        # `path` is expected to start with '/'. Asserted rather than fixed up: a caller
        # passing 'issues/42' has made a mistake, and quietly inserting the slash would
        # hide it until somebody read a URL with a doubled or missing separator.
        def absolute(path)
          raise ArgumentError, "#{path.inspect} is not an absolute path" unless path.to_s.start_with?('/')

          "#{base_url}#{path}"
        end
      end
    end
  end
end
