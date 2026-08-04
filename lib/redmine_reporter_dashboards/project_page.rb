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

    # Widgets that need an OPTIONAL plugin to render.
    #
    # Their partials deliberately live in blocks/optional/ rather than blocks/, so
    # `additional_blocks`'s glob cannot pick them up: on a Redmine without
    # redmine_reporter they must not merely fail politely, they must never be
    # offerable in the first place. A picker entry for a widget that can only ever
    # render an apology is a worse experience than no entry at all.
    OPTIONAL_BLOCKS = {
      'report_by_issues' => {
        label: :report_by_issues,
        partial: 'reporter_project_pages/blocks/optional/report_by_issues',
        requires_plugin: :redmine_reporter
      },
      'report_by_spent_time' => {
        label: :report_by_spent_time,
        partial: 'reporter_project_pages/blocks/optional/report_by_spent_time',
        requires_plugin: :redmine_reporter
      }
    }.freeze

    # What the picker may offer: unavailable optional widgets are absent.
    def self.blocks
      CORE_BLOCKS.merge(additional_blocks).merge(available_optional_blocks).freeze
    end

    # Everything this plugin knows how to name, available or not.
    #
    # find_block resolves against THIS, not `blocks`, so a widget already sitting on
    # somebody's dashboard when its plugin is uninstalled is still recognised. Letting
    # it resolve to nil instead would make it render as nothing — and a widget that
    # renders as nothing loses its own contextual controls, so nobody could remove it
    # from the layout again.
    def self.all_known_blocks
      CORE_BLOCKS.merge(additional_blocks).merge(OPTIONAL_BLOCKS).freeze
    end

    def self.available_optional_blocks
      OPTIONAL_BLOCKS.select { |_name, definition| optional_block_available?(definition) }
    end

    def self.optional_block_available?(definition)
      required = definition[:requires_plugin]
      return true if required.nil?

      case required
      when :redmine_reporter then RedmineReporterDashboards.reporter_present?
      else false
      end
    end

    # True when the named block is known but its plugin is not installed.
    def self.block_degraded?(name)
      definition = OPTIONAL_BLOCKS[name]
      return false if definition.nil?

      !optional_block_available?(definition)
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
      known = all_known_blocks
      return nil unless known.key?(name)

      known[name].merge(name: name, degraded: block_degraded?(name))
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
