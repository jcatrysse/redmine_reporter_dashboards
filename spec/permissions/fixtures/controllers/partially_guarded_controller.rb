# frozen_string_literal: true

# FIXTURE, not production code. Never loaded — `ControllerSource` reads it as text.
#
# It exists because the four real controllers in `app/controllers/` contain no `only:`, no
# `except:` and no `skip_before_action`, so a reader that ignored all three would pass every
# assertion made against them. That is precisely what the review of T-40 broke: two lines
# here left three of four mapped actions unauthorized and the suite green.
class PartiallyGuardedController < ApplicationController
  before_action :find_project_by_project_id
  before_action :authorize, only: [:create]
  skip_before_action :authorize, only: [:order]

  def create; end

  def update; end

  def destroy; end

  def order; end
end
