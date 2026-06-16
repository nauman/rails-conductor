module Admin
  # Platform-admin (webmaster) area. Visible across all organizations.
  class BaseController < ApplicationController
    before_action :require_admin!
    skip_before_action :require_onboarding
  end
end
