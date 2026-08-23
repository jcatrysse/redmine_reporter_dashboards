# frozen_string_literal: true

# T-27 — the upgrade diagnostic's rules, asserted without a database.
#
# `AuthoringAudit` is pure for the same reason `Permissions.collisions` is: the caller
# passes the roles, so every rule below is checked here rather than only in a suite that
# needs Redmine booted. The functional test
# (`test/functional/reporter_preflight_controller_test.rb`) covers the other half — that
# the page reads real `Role` rows and renders them — and deliberately does not re-test
# these rules.
#
# THE TWO EXAMPLES THE `Accept:` LIST NAMES BY HAND are `absent base plugin` and
# `holds ours and not theirs`. Both are marked below so a later edit cannot quietly drop
# one.

# The DB-less suite loads nothing for itself — `spec_helper` deliberately does not pull
# the plugin in (it would drag `project_page.rb` and Redmine::I18n behind it), so each
# file requires exactly the lib files it exercises. `permissions.rb` first: the audit
# reads `Permissions.authoring_names` out of it.
require_relative '../spec_helper'
require_relative '../../lib/redmine_reporter_dashboards/permissions'
require_relative '../../lib/redmine_reporter_dashboards/permissions/authoring_audit'

RSpec.describe RedmineReporterDashboards::Permissions::AuthoringAudit do
  # A stand-in for `Role`. Four readers is the whole contract this module needs, which is
  # what keeps it testable without ActiveRecord — and asserting against a Struct rather
  # than a mock means an example cannot pass because a stub answered a method the real
  # class does not have.
  #
  # --- IT IS A `let` AND EMPHATICALLY NOT A CONSTANT ---------------------------------
  #
  # `Role = Struct.new(...)` inside an `RSpec.describe` block defines **`Object::Role`**
  # for the whole process: the block is a closure whose lexical scope is the file's top
  # level. HANDOVER §1 records that trap costing a session when two spec files each
  # defined `FIXTURES`. Here it would be worse than a collision between two specs —
  # `Role` is REDMINE'S OWN MODEL, so in any run where this file is loaded alongside a
  # booted Redmine the plugin's spec suite would redefine it. A `let` is scoped to the
  # example.
  let(:role_class) { Struct.new(:id, :name, :builtin, :permissions) }

  def role(id:, name:, permissions:, builtin: 0)
    role_class.new(id, name, builtin, permissions)
  end

  # The names, read once from the model rather than retyped. A test that hardcodes
  # `:add_reporter_dashboards_templates` keeps passing after the model renames it, which
  # is the failure mode this whole file exists to prevent one level up.
  # `own_authoring` is the AUDIT'S set, which is narrower than the permission model's
  # `authoring_names` — see curator decision #4 and `NOT_AUTHORING_IN_PRACTICE`.
  let(:own_authoring) { described_class.own_authoring }
  let(:base_authoring) { described_class::BASE_AUTHORING.first }

  describe 'what counts as authoring' do
    it 'names exactly one base-plugin permission, measured from that plugin source' do
      # If this ever grows, it is because somebody MEASURED a new one — not because a
      # name looked plausible. The comment in the module carries the evidence.
      expect(described_class::BASE_AUTHORING).to eq(%i[manage_report_templates])
    end

    it "takes our side of the list from the permission model's authoring flag" do
      expect(own_authoring).to include(:add_reporter_dashboards_templates,
                                       :edit_reporter_dashboards_templates)
      expect(own_authoring).not_to include(:view_reporter_dashboards_reports)
    end

    # CURATOR DECISION #4, 2026-08-13 — NARROW THE DIAGNOSTIC, DO NOT CHANGE THE FLAG.
    #
    # `manage_public_reporter_dashboards_templates` carries `authoring: true` and cannot
    # write a template: the controller additionally requires `add_…` for new/create and an
    # edit permission for edit/update, and a functional test holds this permission ALONE
    # and asserts 403 on both. Reporting it made this page warn about people who cannot
    # author — the cry-wolf failure it exists to avoid.
    it 'excludes the public-visibility permission, which cannot author' do
      expect(RedmineReporterDashboards::Permissions.authoring_names)
        .to include(:manage_public_reporter_dashboards_templates)
      expect(own_authoring).not_to include(:manage_public_reporter_dashboards_templates)
    end

    # THE SUBTRACTION NAMES WHAT IT EXCLUDES, so a fifth authoring permission added later
    # is reported by DEFAULT. A hand-typed list of three would silently stop covering one.
    it 'is the authoring flag minus exactly the excluded set, and nothing else' do
      expect(own_authoring)
        .to eq(RedmineReporterDashboards::Permissions.authoring_names -
               described_class::NOT_AUTHORING_IN_PRACTICE)
      expect(described_class::NOT_AUTHORING_IN_PRACTICE)
        .to eq(%i[manage_public_reporter_dashboards_templates])
    end

    # AND THE CONSEQUENCE ON A ROW, because the constant alone is not the behaviour: a
    # role holding ONLY that permission must produce no row at all.
    it 'emits no row for a role holding only the public-visibility permission' do
      roles = [role(id: 1, name: 'Publisher',
                    permissions: [:manage_public_reporter_dashboards_templates])]

      expect(described_class.rows(roles)).to be_empty
      expect(described_class.any?(roles)).to be(false)
    end

    # ...while the same role holding a real authoring permission as well is still
    # reported, and the public one is NOT listed beside it — the row prints what it holds,
    # and printing a permission the page has decided is not authoring would undo the fix.
    it 'reports a role holding both, listing only the authoring one' do
      roles = [role(id: 1, name: 'Publisher',
                    permissions: %i[manage_public_reporter_dashboards_templates
                                    add_reporter_dashboards_templates])]

      expect(described_class.rows(roles).first.own).to eq(%i[add_reporter_dashboards_templates])
    end
  end

  describe 'the empty answers' do
    # --- THE `Accept:` EXAMPLE: THE BASE PLUGIN IS ABSENT ---------------------------
    #
    # "the list is empty, not an error". Absent means nobody holds its permission, which
    # is the same observable whether the plugin was never installed or has been removed
    # — the audit asks the permission tables and never the plugin registry, so it cannot
    # tell the two apart and does not need to.
    it 'is empty, not an error, when no role holds the base plugin permission' do
      roles = [role(id: 1, name: 'Manager', permissions: %i[view_issues edit_issues]),
               role(id: 2, name: 'Developer', permissions: [])]

      expect { described_class.rows(roles) }.not_to raise_error
      expect(described_class.rows(roles)).to eq([])
      expect(described_class.any?(roles)).to be(false)
    end

    it 'is empty when there are no roles at all' do
      expect(described_class.rows([])).to eq([])
    end

    # `Role#permissions` is nil until something is granted — core's own `add_permission!`
    # guards with `unless permissions.is_a?(Array)`. A NoMethodError inside a
    # `before_action` would take the whole admin page down.
    it 'treats a role whose permissions column is nil as holding nothing' do
      roles = [role(id: 1, name: 'Fresh', permissions: nil)]

      expect { described_class.rows(roles) }.not_to raise_error
      expect(described_class.rows(roles)).to eq([])
    end

    it 'ignores nil and empty entries inside the permissions array' do
      roles = [role(id: 1, name: 'Odd', permissions: [nil, '', :view_issues])]

      expect(described_class.rows(roles)).to eq([])
    end
  end

  describe 'the three verdicts' do
    # --- THE `Accept:` EXAMPLE: OURS AND NOT THEIRS ---------------------------------
    #
    # Not hypothetical. Core's `DefaultData::Loader` grants Manager every setable
    # permission on a fresh install, `require: :member` included, so this row appears
    # without anybody choosing it — and this diagnostic is the only thing that says so.
    it 'reports a role holding ours and not theirs as only_own' do
      roles = [role(id: 1, name: 'Manager', permissions: own_authoring + [:view_issues])]

      row = described_class.rows(roles).first
      expect(row.only_own?).to be(true)
      expect(row.only_base?).to be(false)
      expect(row.both?).to be(false)
      expect(row.own).to eq(own_authoring)
      expect(row.base).to eq([])
    end

    it 'reports a role holding theirs and not ours as only_base' do
      roles = [role(id: 1, name: 'Reporter author', permissions: [base_authoring])]

      row = described_class.rows(roles).first
      expect(row.only_base?).to be(true)
      expect(row.only_own?).to be(false)
      expect(row.base).to eq([base_authoring])
      expect(row.own).to eq([])
    end

    it 'reports a role holding both as both' do
      roles = [role(id: 1, name: 'Both',
                    permissions: [base_authoring, :add_reporter_dashboards_templates])]

      row = described_class.rows(roles).first
      expect(row.both?).to be(true)
      expect(row.only_base?).to be(false)
      expect(row.only_own?).to be(false)
    end

    # Exactly one of the three is true for every row the audit emits, because the view
    # renders them as an if/elsif chain with no fourth branch. A row satisfying none
    # would print the `only_own` sentence about a role that does not hold ours.
    it 'puts every emitted row in exactly one of the three states' do
      roles = [role(id: 1, name: 'A', permissions: [base_authoring]),
               role(id: 2, name: 'B', permissions: own_authoring),
               role(id: 3, name: 'C', permissions: own_authoring + [base_authoring])]

      described_class.rows(roles).each do |row|
        states = [row.both?, row.only_base?, row.only_own?]
        expect(states.count(true)).to eq(1), "#{row.role_name} matched #{states}"
      end
    end
  end

  describe 'roles that hold nothing are left out' do
    # A diagnostic about code execution, not a second roles screen. An install with forty
    # roles and two authors must print two rows, or nobody reads it.
    it 'emits only the roles holding an authoring permission' do
      roles = [role(id: 1, name: 'Author', permissions: [base_authoring]),
               role(id: 2, name: 'Reader', permissions: %i[view_issues]),
               role(id: 3, name: 'Nobody', permissions: [])]

      expect(described_class.rows(roles).map(&:role_name)).to eq(['Author'])
    end
  end

  describe 'string permission names' do
    # The column is a serialized Array, and a fixture, an import or an older Redmine may
    # leave Strings in it. Comparing a String against a Symbol answers "nobody holds it",
    # which is this diagnostic FAILING OPEN — the one failure direction that matters.
    it 'matches a permission stored as a String exactly as it matches a Symbol' do
      symbolic = [role(id: 1, name: 'R', permissions: [base_authoring])]
      stringly = [role(id: 1, name: 'R', permissions: [base_authoring.to_s])]

      expect(described_class.rows(stringly).map(&:to_a))
        .to eq(described_class.rows(symbolic).map(&:to_a))
      expect(described_class.rows(stringly).first.base?).to be(true)
    end
  end

  describe 'builtin roles' do
    # THE ASYMMETRY THE PAGE EXISTS TO SHOW. `:manage_report_templates` is registered with
    # no `require:`, so `Role#setable_permissions` subtracts nothing for Non-member or
    # Anonymous and an administrator CAN tick it there — code execution for people who are
    # not members, and for Anonymous, people with no account. Ours cannot land there,
    # because `Entry#requires` derives `:member` from `authoring`.
    it 'flags a builtin role holding the base permission' do
      roles = [role(id: 2, name: 'Anonymous', builtin: 2, permissions: [base_authoring])]

      expect(described_class.rows(roles).first.builtin?).to be(true)
    end

    it 'does not flag a givable role' do
      roles = [role(id: 1, name: 'Manager', builtin: 0, permissions: [base_authoring])]

      expect(described_class.rows(roles).first.builtin?).to be(false)
    end

    it 'treats a nil builtin column as givable rather than raising' do
      roles = [role(id: 1, name: 'Odd', builtin: nil, permissions: [base_authoring])]

      expect(described_class.rows(roles).first.builtin?).to be(false)
    end
  end

  describe 'ordering' do
    # CLAUDE.md §6: no collection assertion without an explicit order. This one is also
    # PRINTED, so an unordered read would make the page shuffle between visits on three
    # engines that do not agree about unordered row order.
    it 'orders by role name' do
      roles = [role(id: 3, name: 'Zulu', permissions: [base_authoring]),
               role(id: 1, name: 'Alpha', permissions: [base_authoring]),
               role(id: 2, name: 'Mike', permissions: [base_authoring])]

      expect(described_class.rows(roles).map(&:role_name)).to eq(%w[Alpha Mike Zulu])
    end

    it 'breaks a duplicate name on the id, so the order is total' do
      roles = [role(id: 7, name: 'Same', permissions: [base_authoring]),
               role(id: 2, name: 'Same', permissions: [base_authoring])]

      expect(described_class.rows(roles).map(&:role_id)).to eq([2, 7])
    end
  end

  describe 'the row is frozen' do
    # `Row` freezes at construction, all the way down, for the reason `Permissions::Entry`
    # does: a comment calling data immutable while it is not is how somebody later writes
    # a shared-mutable-state bug against it.
    it 'freezes the row and both permission lists' do
      row = described_class.rows([role(id: 1, name: 'R', permissions: [base_authoring])]).first

      expect(row).to be_frozen
      expect(row.base).to be_frozen
      expect(row.own).to be_frozen
    end
  end
end
