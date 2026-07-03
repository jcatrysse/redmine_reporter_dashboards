# frozen_string_literal: true

module ReporterProjectPagesHelper
  REPORTER_PROJECT_LIMITS = [5, 10, 25, 50, 100].freeze

  # Directional controls. On Redmine 6 (SVG icon sprite) we use the core
  # angle-* icons, all four of which exist in the core sprite. On Redmine 5,
  # which has no SVG sprite and no complete arrow set in its CSS icon font, we
  # fall back to accessible Unicode arrow glyphs so the buttons render on both.
  REPORTER_MOVE_ICONS = {
    'up' => 'angle-up', 'down' => 'angle-down',
    'left' => 'angle-left', 'right' => 'angle-right'
  }.freeze
  REPORTER_MOVE_GLYPHS = {
    'up' => "▲", 'down' => "▼", 'left' => "◀", 'right' => "▶"
  }.freeze
  REPORTER_MOVE_LABELS = {
    'up' => :label_move_up, 'down' => :label_move_down,
    'left' => :label_move_left, 'right' => :label_move_right
  }.freeze

  # True when the running Redmine renders icons through the SVG sprite system
  # introduced in Redmine 6.0 (IconsHelper#sprite_icon).
  def reporter_dashboard_svg_icons?
    Redmine::VERSION::MAJOR >= 6
  end

  # A single move control (link) rendered version-safely. Used both for widget
  # movement and for tab ordering, so the two stay visually consistent and both
  # work on Redmine 5 and 6.
  def reporter_dashboard_move_link(direction, url)
    direction = direction.to_s
    label = l(REPORTER_MOVE_LABELS[direction])

    if reporter_dashboard_svg_icons?
      link_to sprite_icon(REPORTER_MOVE_ICONS[direction], label), url,
              method: :post, class: 'icon-only reporter-move-control',
              title: label, 'aria-label' => label
    else
      glyph = content_tag('span', REPORTER_MOVE_GLYPHS[direction], 'aria-hidden' => 'true')
      link_to glyph, url,
              method: :post,
              class: 'reporter-move-control reporter-move-control--glyph',
              title: label, 'aria-label' => label
    end
  end

  def render_reporter_project_blocks(blocks, tab, project)
    content = ''.html_safe
    if blocks.present?
      blocks.each do |block|
        content << render_reporter_project_block(block, tab, project).to_s
      end
    end
    content
  end

  def render_reporter_project_block(block, tab, project)
    # M1: only spent-time reports require the time-entries permission.
    #     Issue reports use :view_issues, which authorize already enforces.
    base_block = block.to_s.sub(/__\d+\z/, '')
    if base_block == 'report_by_spent_time' &&
       !User.current.allowed_to?(:view_time_entries, project, global: true)
      return ''
    end

    content = render_reporter_project_block_content(block, tab, project)
    if content.present?
      contextual = ''.html_safe
      if manage_reporter_project_page?(project)
        moves = reporter_project_block_move_controls(block, tab, project)
        close = link_to(sprite_icon('close', l(:button_delete)),
                        remove_reporter_project_block_path(project_id: project.id, block: block, tab: tab.id),
                        method: :post,
                        class: 'icon-only icon-close', title: l(:button_delete))
        contextual = content_tag('div', moves + close, class: 'contextual')
      end

      content_tag('div', contextual + content, class: 'mypage-box', id: "reporter-block-#{block}")
    end
  end

  # Up/down/left/right buttons for a widget. A direction is only rendered when
  # the move would actually change the layout (RowLayout#can_move?), so widgets
  # at an edge don't show dead controls.
  def reporter_project_block_move_controls(block, tab, project)
    controls = ''.html_safe
    RedmineReporterDashboards::RowLayout::DIRECTIONS.each do |direction|
      next unless tab.can_move_block?(block, direction)

      controls << reporter_dashboard_move_link(
        direction,
        move_reporter_project_block_path(project_id: project.id, block: block, tab: tab.id, direction: direction)
      )
    end
    # A widget alone on the page can't move in any direction; don't emit an empty
    # wrapper (it would still add margin next to the close button).
    return ''.html_safe if controls.blank?

    content_tag('span', controls, class: 'reporter-move-controls')
  end

  def render_reporter_project_block_content(block, tab, project)
    block_definition = RedmineReporterDashboards::ProjectPage.find_block(block)
    unless block_definition
      Rails.logger.warn("Unknown block \"#{block}\" found in project #{project.identifier} (id=#{project.id})")
      return
    end

    settings = tab.block_settings(block)
    partial = block_definition[:partial]
    if partial
      begin
        render(partial: partial, locals: {
                 user:     User.current,
                 project:  project,
                 settings: settings,
                 block:    block,
                 tab:      tab,
                 editable: manage_reporter_project_page?(project)
               })
      rescue ActionView::MissingTemplate
        Rails.logger.warn("Partial \"#{partial}\" missing for block \"#{block}\" in project #{project.identifier} (id=#{project.id})")
        return nil
      end
    else
      send :"render_reporter_project_#{block_definition[:name]}_block", block, settings, project
    end
  end

  def reporter_project_block_select_tag(tab, project)
    blocks_in_use = tab.block_rows.flatten
    options = content_tag('option')
    RedmineReporterDashboards::ProjectPage.block_options(blocks_in_use).each do |label, block|
      options << content_tag('option', label, value: block, disabled: block.blank?)
    end
    select_tag('block', options, id: 'reporter-block-select',
                                 onchange: "$('#reporter-block-form').submit();")
  end

  def reporter_project_limit_options(selected)
    options = [[l(:label_all), '0']] + REPORTER_PROJECT_LIMITS.map { |limit| [limit, limit] }
    options_for_select(options, selected)
  end

  def reporter_project_block_limit(settings, default: 10)
    limit_value = settings[:limit] || settings['limit']
    return default if limit_value.blank?

    limit = limit_value.to_i
    return nil if limit.zero?
    return limit if REPORTER_PROJECT_LIMITS.include?(limit)

    default
  end

  def reporter_project_group_by_options(query, settings)
    group_by = reporter_project_group_by_selection(query, settings)
    options = [[l(:label_none), '']] +
              query.groupable_columns.map { |column| [column.caption, column.name.to_s] }
    options_for_select(options, group_by.to_s)
  end

  def reporter_project_group_by_value(query, settings)
    group_by = settings[:group_by] || settings['group_by']
    return if group_by.blank?

    reporter_project_group_by_allowed?(query, group_by) ? group_by : nil
  end

  def manage_reporter_project_page?(project)
    User.current.admin? || User.current.allowed_to?(:manage_reporter_project_page, project)
  end

  def render_reporter_project_issuesassignedtome_block(block, settings, project)
    query = IssueQuery.new(name: l(:label_assigned_to_me_issues), project: project, user: User.current)
    query.add_filter 'assigned_to_id', '=', ['me']
    query.column_names = settings[:columns].presence || ['tracker', 'status', 'subject']
    query.sort_criteria = settings[:sort].presence || [['priority', 'desc'], ['updated_on', 'desc']]
    query.group_by = reporter_project_group_by_value(query, settings)
    issues = query.issues(limit: reporter_project_block_limit(settings))

    render partial: 'reporter_project_pages/core_blocks/issues',
           locals: { query: query, issues: issues, block: block, settings: settings, project: project, tab: @tab,
                     editable: manage_reporter_project_page?(project) }
  end

  def render_reporter_project_issuesreportedbyme_block(block, settings, project)
    query = IssueQuery.new(name: l(:label_reported_issues), project: project, user: User.current)
    query.add_filter 'author_id', '=', ['me']
    query.column_names = settings[:columns].presence || ['tracker', 'status', 'subject']
    query.sort_criteria = settings[:sort].presence || [['updated_on', 'desc']]
    query.group_by = reporter_project_group_by_value(query, settings)
    issues = query.issues(limit: reporter_project_block_limit(settings))

    render partial: 'reporter_project_pages/core_blocks/issues',
           locals: { query: query, issues: issues, block: block, settings: settings, project: project, tab: @tab,
                     editable: manage_reporter_project_page?(project) }
  end

  def render_reporter_project_issuesupdatedbyme_block(block, settings, project)
    query = IssueQuery.new(name: l(:label_updated_issues), project: project, user: User.current)
    query.add_filter 'updated_by', '=', ['me']
    query.column_names = settings[:columns].presence || ['tracker', 'status', 'subject']
    query.sort_criteria = settings[:sort].presence || [['updated_on', 'desc']]
    query.group_by = reporter_project_group_by_value(query, settings)
    issues = query.issues(limit: reporter_project_block_limit(settings))

    render partial: 'reporter_project_pages/core_blocks/issues',
           locals: { query: query, issues: issues, block: block, settings: settings, project: project, tab: @tab,
                     editable: manage_reporter_project_page?(project) }
  end

  def render_reporter_project_issueswatched_block(block, settings, project)
    query = IssueQuery.new(name: l(:label_watched_issues), project: project, user: User.current)
    query.add_filter 'watcher_id', '=', ['me']
    query.column_names = settings[:columns].presence || ['tracker', 'status', 'subject']
    query.sort_criteria = settings[:sort].presence || [['updated_on', 'desc']]
    query.group_by = reporter_project_group_by_value(query, settings)
    issues = query.issues(limit: reporter_project_block_limit(settings))

    render partial: 'reporter_project_pages/core_blocks/issues',
           locals: { query: query, issues: issues, block: block, settings: settings, project: project, tab: @tab,
                     editable: manage_reporter_project_page?(project) }
  end

  def render_reporter_project_issuequery_block(block, settings, project)
    query = IssueQuery.visible.where(project_id: [nil, project.id]).find_by(id: settings[:query_id])

    if query
      query.column_names = settings[:columns] if settings[:columns].present?
      query.sort_criteria = settings[:sort] if settings[:sort].present?
      query.group_by = reporter_project_group_by_value(query, settings) if reporter_project_group_by_configured?(settings)
      issues = query.issues(limit: reporter_project_block_limit(settings))
      render partial: 'reporter_project_pages/core_blocks/issues',
             locals: { query: query, issues: issues, block: block, settings: settings, project: project, tab: @tab,
                       editable: manage_reporter_project_page?(project) }
    else
      queries = IssueQuery.visible.where(project_id: [nil, project.id]).sorted
      render partial: 'reporter_project_pages/core_blocks/issue_query_selection',
             locals: { queries: queries, block: block, settings: settings, project: project, tab: @tab,
                       editable: manage_reporter_project_page?(project) }
    end
  end

  def render_reporter_project_news_block(block, settings, project)
    news = project.news.visible.limit(reporter_project_block_limit(settings)).includes(:author, :project)
                   .order("#{News.table_name}.created_on DESC").to_a

    render partial: 'reporter_project_pages/core_blocks/news',
           locals: { block: block, news: news, settings: settings, project: project, tab: @tab,
                     editable: manage_reporter_project_page?(project) }
  end

  def render_reporter_project_documents_block(block, settings, project)
    documents = project.documents.visible.order("#{Document.table_name}.created_on DESC")
                       .limit(reporter_project_block_limit(settings)).to_a

    render partial: 'reporter_project_pages/core_blocks/documents',
           locals: { block: block, documents: documents, settings: settings, project: project, tab: @tab,
                     editable: manage_reporter_project_page?(project) }
  end

  def render_reporter_project_calendar_block(block, settings, project)
    calendar = Redmine::Helpers::Calendar.new(User.current.today, current_language, :week)
    calendar.events = Issue.visible.where(project: project)
      .where("(start_date>=? and start_date<=?) or (due_date>=? and due_date<=?)", calendar.startdt, calendar.enddt,
             calendar.startdt, calendar.enddt)
      .includes(:project, :tracker, :priority, :assigned_to)
      .references(:project, :tracker, :priority, :assigned_to)
      .to_a

    render partial: 'reporter_project_pages/core_blocks/calendar',
           locals: { calendar: calendar, block: block, settings: settings, project: project, tab: @tab,
                     editable: manage_reporter_project_page?(project) }
  end

  def render_reporter_project_timelog_block(block, settings, project)
    days = settings[:days].to_i
    days = 7 if days < 1 || days > 365

    entries = TimeEntry.visible.where(project: project, user_id: User.current.id)
      .where("#{TimeEntry.table_name}.spent_on BETWEEN ? AND ?", User.current.today - (days - 1), User.current.today)
      .joins(:activity, :project)
      .references(:issue => [:tracker, :status])
      .includes(:issue => [:tracker, :status])
      .order("#{TimeEntry.table_name}.spent_on DESC, #{Project.table_name}.name ASC, #{Tracker.table_name}.position ASC, #{Issue.table_name}.id ASC")
      .to_a
    entries_by_day = entries.group_by(&:spent_on)

    render partial: 'reporter_project_pages/core_blocks/timelog',
           locals: { block: block, entries: entries, entries_by_day: entries_by_day, days: days, settings: settings,
                     project: project, tab: @tab, editable: manage_reporter_project_page?(project) }
  end

  def render_reporter_project_activity_block(block, settings, project)
    events_by_day = Redmine::Activity::Fetcher.new(User.current, project: project)
      .events(nil, nil, limit: reporter_project_block_limit(settings))
      .group_by { |event| User.current.time_to_date(event.event_datetime) }

    render partial: 'reporter_project_pages/core_blocks/activity',
           locals: { block: block, events_by_day: events_by_day, settings: settings, project: project, tab: @tab,
                     editable: manage_reporter_project_page?(project) }
  end

  private

  def reporter_project_group_by_selection(query, settings)
    group_by = reporter_project_group_by_value(query, settings)
    group_by.presence || query.group_by
  end

  def reporter_project_group_by_allowed?(query, group_by)
    query.groupable_columns.any? { |column| column.name.to_s == group_by.to_s }
  end

  def reporter_project_group_by_configured?(settings)
    settings.key?(:group_by) || settings.key?('group_by')
  end
end
