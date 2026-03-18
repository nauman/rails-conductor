class DeploymentsController < ApplicationController
  def show
    @deployment = Deployment.find(params[:id])
    @app = @deployment.app
  end
end
