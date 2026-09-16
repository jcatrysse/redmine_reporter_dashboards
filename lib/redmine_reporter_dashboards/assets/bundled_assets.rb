# frozen_string_literal: true

module RedmineReporterDashboards
  module Assets
    # THE PLUGIN'S OWN STATIC FILES, and the one place this Ruby layer knows where they
    # are on disk.
    #
    # §6: "Ship **pre-built, non-digested** files; rely on Redmine's plugin-asset
    # mirror… This matters twice: the **PDF path reads the same files off disk and
    # inlines them**, and a digested asset would have no stable on-disk path." This is
    # the half that reads them.
    #
    # --- THE PLUGIN'S `assets/`, NOT `public/plugin_assets/` ---
    #
    # Redmine mirrors `plugins/<name>/assets` into `public/plugin_assets/<name>` at boot.
    # Either would answer, and this reads the SOURCE for two reasons. The mirror is a
    # copy whose freshness depends on when Redmine last ran its mirror step, and a stale
    # copy inlined into a PDF is a silent version skew between what the browser shows and
    # what the document contains. And the mirror lives outside the plugin, so nothing
    # about it is checkable by `script/gates/vendor_integrity.sh` — which recomputes the
    # sha256 of the file HERE.
    #
    # --- WHY THE ROOT IS A CONSTANT AND THE STORE IS NOT ---
    #
    # `LocalStore` takes its roots as a constructor argument (mechanism E5: ports, not
    # ambient state) so a spec can point it at a fixture tree. This constant is what the
    # PRODUCTION caller passes in. Two different jobs; conflating them is how a spec ends
    # up asserting against the real plugin directory and passing for the wrong reason.
    module BundledAssets
      # `…/lib/redmine_reporter_dashboards/assets/bundled_assets.rb` -> the plugin root.
      PLUGIN_ROOT = File.expand_path('../../..', __dir__)
      ROOT = File.join(PLUGIN_ROOT, 'assets')

      # The URL prefix Redmine serves the mirror under. `Redmine::Utils.relative_url_root`
      # is NOT consulted here: a sub-path install's prefix is stripped by `Origin` before
      # a path reaches the store, so this layer only ever sees the un-prefixed form. One
      # place decides that, and it is not this one.
      URL_PREFIX = '/plugin_assets/redmine_reporter_dashboards'

      module_function

      # The roots map `LocalStore` wants. A Hash rather than a single value because the
      # attachment mapper and any future root are the same shape, and a caller composing
      # two roots should not have to know which is which.
      def roots
        { URL_PREFIX => ROOT }
      end

      # Present so a diagnostic can say "the plugin's assets are not where this code
      # thinks they are" rather than reporting every asset as unresolvable. That happens
      # for real: a packaging step that copies `lib/` and forgets `assets/`.
      def available?
        File.directory?(ROOT)
      end
    end
  end
end
