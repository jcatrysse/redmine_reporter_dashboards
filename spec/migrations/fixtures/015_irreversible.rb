class Irrev < ActiveRecord::Migration[6.1]
  def change
    raise ActiveRecord::IrreversibleMigration
  end
end
