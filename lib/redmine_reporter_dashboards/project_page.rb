# frozen_string_literal: true

module RedmineReporterDashboards
  module ProjectPage
    include Redmine::I18n

    GROUPS = ['top', 'top-left', 'top-middle', 'top-right', 'left', 'middle', 'right'].freeze
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

    def self.groups
      GROUPS.dup.freeze
    end

    def self.blocks
      CORE_BLOCKS.merge(additional_blocks).freeze
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
      blocks.key?(name) ? blocks[name].merge(name: name) : nil
    end

    def self.additional_blocks
      @additional_blocks ||= Dir.glob(
        "#{Redmine::Plugin.directory}/*/app/views/reporter_project_pages/blocks/_*.{rhtml,erb}"
      ).each_with_object({}) do |file, hash|
        name = File.basename(file).split('.').first.delete_prefix('_')
        hash[name] = { label: name.to_sym, partial: "reporter_project_pages/blocks/#{name}" }
      end
    end

    def self.default_layout
      {
        'top' => [],
        'top-left' => [],
        'top-middle' => [],
        'top-right' => [],
        'left' => [],
        'middle' => [],
        'right' => []
      }
    end
  end
end
