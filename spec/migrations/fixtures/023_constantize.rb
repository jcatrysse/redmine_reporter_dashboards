class Constantized < ActiveRecord::Migration[6.1]
  def change
    "RedmineReporterDashboards::Template".constantize.update_all(content: "x")
  end
end
