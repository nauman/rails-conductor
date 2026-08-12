class DeployChecklistItemsController < ApplicationController
  include OperatorOnly
  before_action :set_app
  before_action :set_item, only: [ :update, :destroy ]

  def create
    AppRunbook.new(@app, actor: current_user).add_item(
      content: item_params[:content], required: item_params.fetch(:required, true),
      expected_revision: item_params[:expected_revision]
    )
    redirect_to app_path(@app, anchor: "runbook")
  end

  # Toggle the done state (checkbox) or edit the content.
  def update
    AppRunbook.new(@app, actor: current_user).check_item(
      item_id: params[:id], done: ActiveModel::Type::Boolean.new.cast(item_params[:done]),
      expected_revision: item_params[:expected_revision]
    )
    redirect_to app_path(@app, anchor: "runbook")
  end

  def destroy
    AppRunbook.new(@app, actor: current_user).remove_item(
      item_id: params[:id], expected_revision: params[:expected_revision]
    )
    redirect_to app_path(@app, anchor: "runbook")
  end

  private

  def set_app
    @app = current_organization.apps.find(params[:app_id])
  end

  def set_item
    @item = @app.runbook_summary[:checklist].find { |item| item[:id].to_s == params[:id].to_s }
    return if @item

    redirect_to app_path(@app, anchor: "runbook"), alert: "Checklist item not found."
  end

  def item_params
    params.require(:deploy_checklist_item).permit(:content, :required, :done, :expected_revision)
  end
end
