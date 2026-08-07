class ComputedIndexName < ActiveRecord::Migration[6.1]
  def change
    create_table(:x) { |t| t.integer :a }
    n = "index_" + ("x" * 80)
    add_index :x, [:a], name: n
  end
end
