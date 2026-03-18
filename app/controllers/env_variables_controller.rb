class EnvVariablesController < ApplicationController
  before_action :set_app
  before_action :set_env_variable, only: [:update, :destroy]

  def create
    @env_variable = @app.env_variables.build(env_variable_params)

    if @env_variable.save
      redirect_to app_path(@app, anchor: "env-vars"), notice: "Environment variable added."
    else
      redirect_to app_path(@app, anchor: "env-vars"), alert: @env_variable.errors.full_messages.join(", ")
    end
  end

  def update
    if @env_variable.update(env_variable_params)
      redirect_to app_path(@app, anchor: "env-vars"), notice: "Environment variable updated."
    else
      redirect_to app_path(@app, anchor: "env-vars"), alert: @env_variable.errors.full_messages.join(", ")
    end
  end

  def destroy
    @env_variable.destroy
    redirect_to app_path(@app, anchor: "env-vars"), notice: "Environment variable removed."
  end

  private

  def set_app
    @app = App.find(params[:app_id])
  end

  def set_env_variable
    @env_variable = @app.env_variables.find(params[:id])
  end

  def env_variable_params
    params.require(:env_variable).permit(:key, :value, :secret)
  end
end
