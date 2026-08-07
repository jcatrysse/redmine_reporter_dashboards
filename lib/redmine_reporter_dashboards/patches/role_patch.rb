# frozen_string_literal: true

module RedmineReporterDashboards
  module Patches
    # T-23, closing finding **S-8**.
    #
    # --- WHAT ORPHANS A ROW, AND WHY ONLY CORE CAN STOP IT ---
    #
    # `reporter_dashboards_templates_roles` is the same shape as core's `queries_roles`
    # (`db/migrate/20130602092539_create_queries_roles.rb`), and `Template` declares its
    # half of the association. That half is not what deletes the join rows when a role
    # goes: Rails' `has_and_belongs_to_many` installs a `before_destroy` that clears the
    # join table **on the class being destroyed**, and the class being destroyed is
    # `Role`. Core's `Role` declares `has_and_belongs_to_many :queries`
    # (`app/models/role.rb:73`) for exactly this reason and cannot possibly know about
    # ours, so without this file a deleted role leaves its rows behind for ever.
    #
    # --- THE CONSEQUENCE IS BOUNDED, AND THAT IS NOT A REASON TO SKIP IT ---
    #
    # An orphan contributes nothing on read — the association INNER JOINs `roles`, so a
    # row pointing at a role that no longer exists resolves to nothing, and a
    # ROLES-visible template whose roles have all gone becomes invalid on its next save
    # rather than silently widening. Redmine does not reuse role ids either. So this is
    # not a live privilege leak; it is unbounded growth in a join table and a set of rows
    # that would come back to life if anybody ever did reuse an id. S-8 recorded it as a
    # known gap owed by whichever task built the UI, which is this one.
    #
    # --- WHY `dependent:` IS NOT WRITTEN HERE ---
    #
    # `has_and_belongs_to_many` has no `dependent:` option for the join rows: deleting
    # them is unconditional and built in. Passing one would be silently ignored on some
    # Rails versions and an ArgumentError on others, across the three Rails majors this
    # plugin spans. The join table is the only thing deleted — the templates themselves
    # are untouched, which is right: a template that named a role that has been deleted
    # is a template whose author has to choose again, not a template to destroy.
    module RolePatch
      def self.included(base)
        base.class_eval do
          has_and_belongs_to_many :reporter_dashboards_templates,
                                  class_name: 'RedmineReporterDashboards::Template',
                                  join_table: 'reporter_dashboards_templates_roles',
                                  foreign_key: 'role_id',
                                  association_foreign_key: 'template_id'
        end
      end
    end
  end
end

unless Role.included_modules.include?(RedmineReporterDashboards::Patches::RolePatch)
  Role.include RedmineReporterDashboards::Patches::RolePatch
end
