module Admin
  class OrganizationsController < BaseController
    def index
      @organizations = Organization.includes(:users).order(:name)
    end

    def show
      @organization = Organization.find(params[:id])
    end
  end
end
