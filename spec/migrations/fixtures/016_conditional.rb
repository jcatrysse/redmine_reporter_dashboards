class Conditional < ActiveRecord::Migration[6.1]
  def change
    unless table_exists?(:z)
      create_table(:z) { |t| t.string :a }
    end
  end
end
