class ApplicationController < ActionController::Base
  before_action :halt_request, if: -> { request.headers["X-Halt-Request"] == "true" }

  private

  def halt_request
    head :unauthorized
  end
end
