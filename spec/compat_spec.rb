# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/redmine_reporter_dashboards/compat'

# stub_const throughout, and NOT a `module ActiveRecord; class Base; end; end` at the top
# of the file. The first version of this spec did exactly that and broke 46 examples in
# spec/sql_aggregation, which define their own richer ActiveRecord::Base stub behind
# `unless defined?(...)` — a poor stub loaded first wins, and the specs that needed the
# rich one fail with no hint as to why. stub_const creates what is missing, restores what
# was there, and leaves nothing behind for the next file (CLAUDE.md §6: no example may
# depend on the order the files loaded in).
RSpec.describe RedmineReporterDashboards::Compat do
  describe '.base_record' do
    let(:active_record_base) { Class.new }

    before { stub_const('ActiveRecord::Base', active_record_base) }

    # Redmine 6.0 and later. ApplicationRecord is a real autoloadable constant there.
    it 'is ApplicationRecord where that class exists' do
      stub_const('ApplicationRecord', Class.new(active_record_base))

      expect(described_class.base_record).to be(::ApplicationRecord)
    end

    # Redmine 5.1, which has no such class — and where `class Foo < ApplicationRecord`
    # raised NameError on every page and every test from v0.5.0 until 2026-08-05.
    it 'is ActiveRecord::Base where it does not' do
      hide_const('ApplicationRecord') if Object.const_defined?(:ApplicationRecord)

      expect(described_class.base_record).to be(active_record_base)
    end

    it 'always returns a class a model can inherit from' do
      expect(described_class.base_record).to be_a(Class)
    end
  end
end
