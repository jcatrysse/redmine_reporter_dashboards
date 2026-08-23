class LongIndex < ActiveRecord::Migration[6.1]
  def change
    create_table(:reporter_dashboards_templates) { |t| t.integer :project_id }
    add_index :reporter_dashboards_templates, [:project_id, :visibility]
  end
end
