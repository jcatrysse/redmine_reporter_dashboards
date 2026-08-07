class InlineIndex < ActiveRecord::Migration[6.1]
  def change
    create_table :reporter_dashboards_templates do |t|
      t.integer :project_id
      t.index [:project_id]
    end
  end
end
