# frozen_string_literal: true

# FIXTURE, not production code. Never loaded — `ControllerSource` reads it as text.
#
# Every construct in here is one the AST reader has to answer correctly, and none of them
# appears in `app/controllers/`. The review of T-40 found the first version of the reader
# silently missing the two in the middle, each of which is a routable action with no guard.
class AwkwardDefinitionsController < ApplicationController
  before_action :authorize
  before_action :only_for_two, only: %i[plain_action defined_by_method]
  before_action :everything_but, except: :plain_action

  # An ordinary action.
  def plain_action; end

  # A version conditional. This plugin spans three Rails majors, so this is not a contrived
  # shape — and a `def` nested inside an `if` is not a direct statement of the class body.
  if defined?(::Rails)
    def conditionally_defined; end
  end

  define_method(:defined_by_method) { nil }

  # A class method, which is never an action.
  def self.class_level_helper; end

  class << self
    def also_class_level; end
  end

  # Explicitly private, inline. The `def` is this call's argument, not a statement of the
  # class body, and it must not be reported as an action.
  private def inline_private_helper; end

  protected

  def protected_helper; end

  public

  # Public again, after both markers.
  def public_after_protected; end

  private

  def tail_private_helper; end
end
