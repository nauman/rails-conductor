class ScriptsController < ApplicationController
  before_action :set_script, only: [:show, :edit, :update, :destroy]

  def index
    @scripts = Script.order(:script_type, :name)
  end

  def show
    @servers = Server.with_ssh.order(:name)
  end

  def new
    @script = Script.new(script_type: 'provision')
  end

  def edit
  end

  def create
    @script = Script.new(script_params)
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

  def set_script
    @script = Script.find(params[:id])
  end

  def script_params
    params.require(:script).permit(:name, :description, :body, :script_type)
  end
end
