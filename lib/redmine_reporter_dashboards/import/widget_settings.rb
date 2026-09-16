# frozen_string_literal: true

module RedmineReporterDashboards
  module Import
    # §Findings S-29 — TRANSLATE THE REPORT-WIDGET SETTINGS A DASHBOARD CARRIED OVER.
    #
    # --- THE DEFECT THIS EXISTS FOR ---
    #
    # A dashboard widget stores one number: `report_template_id`. Until T-26a it named a row
    # in the base plugin's `report_templates`; it now names a row in
    # `reporter_dashboards_templates`. Those are different tables and BOTH NUMBER FROM 1, so
    # after a migration the stored id usually still resolves — to an unrelated report of
    # ours, rendered silently, looking exactly like it worked. Nothing leaks
    # (`Template.visible(actor)` still bounds whatever resolves) but the widget shows a
    # report nobody configured, and "it will simply not resolve" — which an earlier comment
    # in `widget_report.rb` claimed — is the UNLIKELY case rather than the normal one.
    #
    # `Runner` already records where each copy came from (`source_template_id`), so the
    # translation is a lookup rather than a guess. What was missing is that nothing applied
    # it: the importer wrote our tables and never touched `reporter_project_tabs`.
    #
    # --- WHY EVERY STORED ID IS READ AS A BASE-PLUGIN ID, AND WHY THAT IS NOT A GUESS ---
    #
    # It is a fact about the release, not an inference about a row: before T-26a the only
    # thing that could write `report_template_id` was a widget whose picker listed the base
    # plugin's templates. So a value written before this release IS a base id.
    #
    # What makes that safe to act on twice is the MARKER, not the arithmetic. After a
    # rewrite the block carries `report_template_origin: 'rrd'`, and this module skips any
    # block that has it. Without the marker, idempotence would rest on "our new id probably
    # is not also one of their old ids" — which is the same probabilistic reasoning that
    # produced the defect, one level in, and this repository has a finding for exactly that
    # class of argument.
    #
    # --- WHAT IT REFUSES TO DO ---
    #
    # A stored id with no imported counterpart is LEFT ALONE and reported (`:unknown`). It
    # could be a template the import skipped, a row deleted before the migration, or —
    # after somebody re-picked in the widget's own settings form — already one of ours. All
    # three are cases where a rewrite would be inventing a mapping, and the honest answer is
    # the settings form the widget already falls back to.
    #
    # It also never touches `layout`, never adds or removes a widget, and never writes a
    # tab unless at least one of that tab's changes is a `:rewritten` (see `#save`) — so a
    # tab whose every widget is `:unknown` keeps its `updated_on`, a dry run and a real run
    # report the same thing, and a re-run writes nothing.
    module WidgetSettings
      # The key the widgets read. Unchanged on purpose — it is what every existing
      # dashboard holds and what `_report_settings.html.erb` still posts; only its MEANING
      # moved, which is the whole of S-29.
      SETTING = 'report_template_id'

      # The marker. A sibling key rather than a new column, because it is a fact about ONE
      # widget's settings and `BlockSettings.sanitize` already keeps an unknown key as a
      # bounded scalar — so it survives every later save of the settings form.
      ORIGIN_SETTING = 'report_template_origin'
      ORIGIN = 'rrd'

      Change = Struct.new(:project_id, :tab_id, :block, :from, :to, :status, :name,
                          keyword_init: true)

      class << self
        # `mapping` is `{ source_template_id => Template | nil }`, built by the caller from
        # the import's own outcomes so this module never re-derives who came from where.
        #
        # **A nil VALUE IS DIFFERENT FROM AN ABSENT KEY, and the difference is the dry run.**
        # On `import:plan` nothing has been written, so the copies have no ids yet — the
        # caller can still say WHICH sources will have one, and that is the half of the
        # answer an operator needs ("these three widgets will be repointed; this one cannot
        # be mapped"). An absent key means there is no copy and the widget is left alone; a
        # present key with no template means "there will be, and its id is not knowable
        # yet". The first version of this method tested the VALUE, so every dry run reported
        # no widget changes at all — a plan that could not predict its own run, which is
        # exactly what `Runner`'s class comment calls "worse than no plan at all".
        #
        # `dry_run:` therefore stops at the SAVE rather than at the walk.
        def apply(mapping, dry_run: false)
          changes = []

          each_tab do |tab|
            tab_changes = rewrite_tab(tab, mapping)
            next if tab_changes.empty?

            changes.concat(tab_changes)
            save(tab, tab_changes) unless dry_run
          end

          changes
        end

        # The blocks whose `report_template_id` this module owns — the two report widgets
        # and their `__N` instances. Read from `WidgetReport` rather than re-listed, because
        # two lists of the same two block names is one list that goes stale.
        def report_block?(block)
          WidgetReport::SOURCE_BY_BLOCK.key?(ProjectPage.base_block_name(block))
        end

        private

        # Ordered, so two runs against the same data report in the same order — CLAUDE.md
        # §6, and the reason an operator can diff two plan outputs at all.
        def each_tab(&block)
          ReporterProjectTab.order(:project_id, :id).each(&block)
        end

        def rewrite_tab(tab, mapping)
          settings = tab.settings
          return [] unless settings.is_a?(Hash)

          settings.filter_map do |block, block_settings|
            next unless report_block?(block)
            next unless block_settings.is_a?(Hash)

            change = rewrite_block(tab, block.to_s, block_settings, mapping)
            change unless change.nil?
          end
        end

        def rewrite_block(tab, block, block_settings, mapping)
          # ALREADY TRANSLATED. Asked first, so a re-run is a no-op even where the numbers
          # would happen to line up again.
          return nil if read(block_settings, ORIGIN_SETTING).to_s == ORIGIN

          stored = read(block_settings, SETTING)
          return nil if stored.blank?

          source_id = stored.to_i
          unless mapping.key?(source_id)
            return Change.new(project_id: tab.project_id, tab_id: tab.id, block: block,
                              from: source_id, to: nil, status: :unknown, name: nil)
          end

          # NO TEMPLATE MEANS NO WRITE, whatever `dry_run` says. It is only reachable on a
          # dry run today, and a guard that depends on the caller having passed the right
          # flag is one the next caller can lose — writing `nil` into the key a widget
          # resolves through is the one outcome worse than leaving the stale id.
          template = mapping[source_id]
          if template
            write(block_settings, SETTING, template.id)
            write(block_settings, ORIGIN_SETTING, ORIGIN)
          end

          Change.new(project_id: tab.project_id, tab_id: tab.id, block: block,
                     from: source_id, to: template&.id, status: :rewritten,
                     name: template&.name)
        end

        # `:unknown` changes nothing, so a tab whose every widget is unknown must not be
        # written — `updated_on` moving on a row nothing changed is what makes an operator
        # distrust the next run's output.
        def save(tab, changes)
          return unless changes.any? { |change| change.status == :rewritten }

          tab.save!
        end

        # The settings Hash is YAML-serialized and reaches us with either key shape
        # depending on who wrote it last: `BlockSettings.sanitize` symbolizes, an older row
        # may hold strings. Both are read, and a write keeps whichever shape the block
        # already uses so this does not leave one settings Hash with two spellings of one
        # key.
        def read(block_settings, key)
          block_settings[key.to_sym] || block_settings[key]
        end

        def write(block_settings, key, value)
          if block_settings.key?(key)
            block_settings[key] = value
          else
            block_settings[key.to_sym] = value
          end
        end
      end
    end
  end
end
