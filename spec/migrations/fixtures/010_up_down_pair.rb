class UpDownPair < ActiveRecord::Migration[6.1]
  def up; create_table(:x) { |t| t.string :a }; end
  def down; drop_table :x; end
end
