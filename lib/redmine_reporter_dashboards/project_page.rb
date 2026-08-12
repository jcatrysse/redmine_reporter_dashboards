# frozen_string_literal: true

module RedmineReporterDashboards
  module ProjectPage
    include Redmine::I18n

    MAX_BLOCK_OCCURS = 15

    CORE_BLOCKS = {
      'issuesassignedtome' => { label: :label_assigned_to_me_issues },
      'issuesreportedbyme' => { label: :label_reported_issues },
      'issuesupdatedbyme' => { label: :label_updated_issues },
      'issueswatched' => { label: :label_watched_issues },
      'issuequery' => { label: :label_issue_plural },
      'news' => { label: :label_news_latest },
      'calendar' => { label: :label_calendar },
      'documents' => { label: :label_document_plural },
      'timelog' => { label: :label_spent_time },
      'activity' => { label: :label_activity }
    }.freeze

    # THE TWO REPORT WIDGETS, WHICH THIS PLUGIN NOW OWNS OUTRIGHT (T-26a, FR-01).
    #
    # They used to be `OPTIONAL_BLOCKS`, declared with a `requires_plugin:` naming the base
    # plugin and hidden from the picker wherever it was absent, because their partials
    # named its classes and iframed its routes. Nothing here does any more: the lookup is
    # `WidgetReport`/`Template.visible` and the render is `Reporting::ReportRun`, so there
    # is no configuration in which these two widgets cannot render and no reason to offer
    # them conditionally. The optional-widget machinery went with them rather than being
    # left behind with no entries — an unreachable mechanism is a comment, and this file
    # already carries the argument for that in `zero_reporter.allowlist`.
    #
    # THEY ARE REGISTERED HERE RATHER THAN DISCOVERED BY `additional_blocks`'s GLOB, and
    # the reason is the LABEL. The glob derives one from the filename, so a globbed
    # `report_by_issues` would look up a bare `report_by_issues` locale key — an
    # un-namespaced name the base plugin also defines, in the one configuration where both
    # plugins are installed and one of the two wins by load order. CLAUDE.md §10 asks for
    # namespaced keys; an explicit entry is how these get one. Their partials therefore
    # live in `report_blocks/`, which the glob (`blocks/_*.erb`, non-recursive) cannot see.
    #
    # The block NAMES are a stored contract — they are the keys in every existing
    # dashboard's layout and settings — so they are unchanged even though nothing behind
    # them is.
    REPORT_BLOCKS = {
      'report_by_issues' => {
        label: :label_reporter_widget_report_by_issues,
        partial: 'reporter_project_pages/report_blocks/report_by_issues'
      },
      'report_by_spent_time' => {
        label: :label_reporter_widget_report_by_spent_time,
        partial: 'reporter_project_pages/report_blocks/report_by_spent_time'
      }
    }.freeze

    # Everything this plugin knows how to name — which is also everything the picker may
    # offer, now that no widget depends on a plugin that may not be there.
    #
    # `find_block` resolves against this too. A widget contributed by a plugin that has
    # since been uninstalled resolves to nil and renders as nothing, which loses its own
    # contextual controls — the hazard the old `all_known_blocks` guarded against for the
    # two report widgets. That case is now only reachable for a THIRD-PARTY widget, whose
    # partial has left the glob with it, and there is nothing this plugin can render in
    # its place.
    def self.blocks
      CORE_BLOCKS.merge(additional_blocks).merge(REPORT_BLOCKS).freeze
    end

    def self.block_options(blocks_in_use = [])
      options = []
      blocks.each do |block, block_options|
        indexes = blocks_in_use.filter_map do |name|
          if name =~ /\A#{block}(__(\d+))?\z/
            Regexp.last_match(2).to_i
          end
        end

        occurs = indexes.size
        block_id = indexes.any? ? "#{block}__#{indexes.max + 1}" : block
        block_id = nil if occurs >= MAX_BLOCK_OCCURS

        label = block_options[:label]
        options << [l("my.blocks.#{label}", default: [label, label.to_s.humanize]), block_id]
      end
      options
    end

    def self.valid_block?(block, blocks_in_use = [])
      block.present? && block_options(blocks_in_use).map(&:last).include?(block)
    end

    def self.find_block(block)
      block.to_s =~ /\A(.*?)(__\d+)?\z/
      name = Regexp.last_match(1)
      known = blocks
      return nil unless known.key?(name)

      known[name].merge(name: name)
    end

    def self.additional_blocks
      @additional_blocks ||= Dir.glob(
        "#{Redmine::Plugin.directory}/*/app/views/reporter_project_pages/blocks/_*.{rhtml,erb}"
      ).each_with_object({}) do |file, hash|
        name = File.basename(file).split('.').first.delete_prefix('_')
        hash[name] = { label: name.to_sym, partial: "reporter_project_pages/blocks/#{name}" }
      end
    end

    # A fresh dashboard starts with no rows; widgets add their own rows as they
    # are placed. The layout is an ordered Array of rows (see RowLayout).
    def self.default_layout
      []
    end
  end
end
