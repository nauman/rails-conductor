# Gate an infrastructure controller so members can view (GET/HEAD) but only an
# owner/admin can mutate or execute (POST/PATCH/PUT/DELETE). Uses the shared
# OperatorPolicy so the boundary is identical to the MCP/tool layer.
module OperatorOnly
  extend ActiveSupport::Concern

  included do
    before_action :require_operator!, unless: :operator_read_only_request?
  end

  class_methods do
    # For controllers whose READS also expose secrets (credentials, SSH keys):
    # gate every action, GET included — a member must not open an edit/show page
    # that renders a decrypted private key or API secret.
    def operator_only_all_actions!
      skip_before_action :require_operator!, raise: false
      before_action :require_operator!
    end
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
