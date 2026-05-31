# frozen_string_literal: true

# Idempotent: guards against tables that may already exist from a prior install
# of the dashboard tabs feature (e.g. when it still lived inside redmine_reporter).
class CreateReporterDashboardsTables < ActiveRecord::Migration[5.2]
  def change
    unless table_exists?(:reporter_project_tabs)
      create_table :reporter_project_tabs do |t|
        t.integer :project_id, null: false
        t.string :title, null: false
        t.text :description
        t.integer :position
        t.text :layout
        t.text :settings
        t.timestamps null: false
      end

      add_index :reporter_project_tabs, [:project_id, :position]
    end
  end
end
