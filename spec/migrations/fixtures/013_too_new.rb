class TooNew < ActiveRecord::Migration[7.2]
  def change; create_table(:x) { |t| t.string :a }; end
end
