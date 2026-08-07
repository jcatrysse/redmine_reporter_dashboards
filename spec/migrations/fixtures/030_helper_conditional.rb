class HelperConditional < ActiveRecord::Migration[6.1]
  def change
    create_the_table
  end

  private

  def create_the_table
    unless table_exists?(:sneaky)
      create_table(:sneaky) { |t| t.string :a }
    end
  end
end
