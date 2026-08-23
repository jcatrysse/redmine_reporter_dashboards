class DefineMethodDown < ActiveRecord::Migration[6.1]
  def change
    create_table(:x) { |t| t.string :a }
  end
  define_method(:down) { drop_table :reporter_project_tabs }
end
