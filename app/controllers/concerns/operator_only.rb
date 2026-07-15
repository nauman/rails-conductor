# Gate an infrastructure controller so members can view (GET/HEAD) but only an
# owner/admin can mutate or execute (POST/PATCH/PUT/DELETE). Uses the shared
# OperatorPolicy so the boundary is identical to the MCP/tool layer.
module OperatorOnly
  extend ActiveSupport::Concern

  included do
    before_action :require_operator!, unless: :operator_read_only_request?
  end

  private

  def operator_read_only_request?
    request.get? || request.head?
  end

  def require_operator!
    return if OperatorPolicy.operator?(current_user, current_organization)

    respond_to do |format|
      format.html { redirect_to root_path, alert: "This action requires an organization owner." }
      format.json { render json: { error: "Owner access required" }, status: :forbidden }
      format.any  { head :forbidden }
    end
  end
end
