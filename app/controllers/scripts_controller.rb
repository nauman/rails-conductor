class ScriptsController < ApplicationController
  include OperatorOnly
  before_action :set_script, only: [ :show, :edit, :update, :destroy ]
  before_action :require_editable_script!, only: [ :edit, :update, :destroy ]

  def index
    @scripts = Script.visible_to(current_organization).order(:script_type, :name)
  end

  def show
    # Only this org's SSH-ready servers are offered as run targets.
    @servers = current_organization.servers.with_ssh.order(:name)
  end

  def new
    @script = current_organization.scripts.new(script_type: "provision")
  end

  def edit
  end

  def create
    # Always owned by the acting org — never a global/built-in (that's admin-only).
    @script = current_organization.scripts.new(script_params)
    if @script.save
      redirect_to @script, notice: "Script created."
    else
      render :new, status: :unprocessable_content
    end
  end

  def update
    if @script.update(script_params)
      redirect_to @script, notice: "Script updated."
    else
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    @script.destroy!
    redirect_to scripts_path, notice: "Script deleted."
  end

  private

  # Members see built-ins + their own org's scripts; a foreign-org id 404s.
  def set_script
    @script = Script.visible_to(current_organization).find(params[:id])
  end

  # Built-ins are platform-admin-only; org scripts only by that org's operators.
  def require_editable_script!
    return if @script.editable_by?(current_user, current_organization)

    redirect_to scripts_path, alert: @script.built_in? ?
      "Built-in scripts can only be changed by a platform admin." :
      "You can't modify this script."
  end

  def script_params
    params.require(:script).permit(:name, :description, :body, :script_type)
  end
end
