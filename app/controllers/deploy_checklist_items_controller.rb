class DeployChecklistItemsController < ApplicationController
  include OperatorOnly
  before_action :set_app
  before_action :set_item, only: [ :update, :destroy ]

  def create
    @app.deploy_checklist_items.create(content: item_params[:content], required: item_params.fetch(:required, true))
    redirect_to app_path(@app, anchor: "runbook")
  end

  # Toggle the done state (checkbox) or edit the content.
  def update
    @item.update(item_params)
    redirect_to app_path(@app, anchor: "runbook")
  end

  def destroy
    @item.destroy
    redirect_to app_path(@app, anchor: "runbook")
  end

  private

  def set_app
    @app = current_organization.apps.find(params[:app_id])
  end

  def set_item
    @item = @app.deploy_checklist_items.find(params[:id])
  end

  def item_params
    params.require(:deploy_checklist_item).permit(:content, :required, :done)
  end
end
