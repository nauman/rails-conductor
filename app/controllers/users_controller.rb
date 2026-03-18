class UsersController < ApplicationController
  before_action :require_admin!
  before_action :set_user, only: [:destroy, :toggle_admin]

  def index
    @users = User.order(created_at: :asc)
  end

  def create
    email = params[:email].to_s.downcase.strip
    @user = User.new(email: email, admin: params[:admin] == "1")

    if @user.save
      redirect_to users_path, notice: "User #{email} added."
    else
      redirect_to users_path, alert: @user.errors.full_messages.join(", ")
    end
  end

  def destroy
    if @user == current_user
      redirect_to users_path, alert: "You cannot remove yourself."
    else
      @user.destroy
      redirect_to users_path, notice: "User removed."
    end
  end

  def toggle_admin
    if @user == current_user
      redirect_to users_path, alert: "You cannot change your own admin status."
    else
      @user.update(admin: !@user.admin?)
      redirect_to users_path, notice: "#{@user.email} is now #{@user.admin? ? 'an admin' : 'a member'}."
    end
  end

  private

  def set_user
    @user = User.find(params[:id])
  end
end
