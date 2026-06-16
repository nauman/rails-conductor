module Admin
  class UsersController < BaseController
    def index
      @users = User.includes(:organizations).order(:created_at)
    end
  end
end
