# Public build-info endpoint. Returns the running release's git sha (kamal injects
# it as KAMAL_VERSION) so a deploy is externally verifiable — compare /version to
# origin/main's HEAD. Inherits ActionController::Base (not ApplicationController)
# to stay auth-free, like the rails health check. No secrets exposed.
class VersionController < ActionController::Base
  def show
    render json: {
      app: "conductor",
      version: ENV["KAMAL_VERSION"].presence || "unknown",
      env: Rails.env
    }
  end
end
