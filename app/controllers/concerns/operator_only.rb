# Gate an infrastructure controller so members can view (GET/HEAD) but only an
# operator (owner OR editor) can mutate or execute. Uses the shared
# OperatorPolicy so the boundary is identical to the MCP/tool layer.
#
# Three levels of gate, coarse to fine:
#
#   include OperatorOnly              — members read; operators mutate
#   operator_only_all_actions!        — gate GET too (reads expose secrets)
#   owner_only :destroy, :destroy     — a specific action needs an owner-only
#                                       capability, GET or not
#   owner_only_controller! :execute   — the whole controller is owner-only
#
# Owner-only actions are checked on every request method, because an owner-only
# *read* (a decrypted credential, a script body) is just as sensitive as a write.
module OperatorOnly
  extend ActiveSupport::Concern

  included do
    class_attribute :owner_only_capabilities, instance_writer: false, default: {}

    before_action :require_operator!, unless: :operator_read_only_request?
    before_action :require_owner_capability!
  end

  class_methods do
    # For controllers whose READS also expose secrets (credentials, SSH keys):
    # gate every action, GET included — a member must not open an edit/show page
    # that renders a decrypted private key or API secret.
    def operator_only_all_actions!
      skip_before_action :require_operator!, raise: false
      before_action :require_operator!
    end

    # Declare that `actions` require an owner-only capability. Merges rather than
    # replaces so a controller can declare several bands.
    def owner_only(capability, *actions)
      self.owner_only_capabilities =
        owner_only_capabilities.merge(actions.flatten.index_with { capability }.transform_keys(&:to_s))
    end

    # Every action in this controller requires `capability`. Used where nothing
    # the controller does is editor-safe (scripts, credentials, SSH keys).
    def owner_only_controller!(capability)
      before_action { require_capability!(capability) }
    end
  end

  private

  def operator_read_only_request?
    request.get? || request.head?
  end

  def require_operator!
    return if OperatorPolicy.operator?(current_user, current_organization)

    deny_capability("This action requires an organization owner or editor.")
  end

  def require_owner_capability!
    capability = self.class.owner_only_capabilities[action_name]
    return if capability.nil?

    require_capability!(capability)
  end

  def require_capability!(capability)
    return if OperatorPolicy.can?(current_user, current_organization, capability)

    deny_capability(DENIAL_MESSAGES.fetch(capability, "This action requires an organization owner."))
  end

  DENIAL_MESSAGES = {
    destroy: "Deleting this requires an organization owner.",
    execute: "Running commands requires an organization owner.",
    credentials: "Stored credentials and SSH keys require an organization owner.",
    manage_members: "Managing members requires an organization owner.",
    repository: "Changing an app's source repository requires an organization owner."
  }.freeze

  def deny_capability(message)
    respond_to do |format|
      format.html { redirect_to root_path, alert: message }
      format.json { render json: { error: message }, status: :forbidden }
      format.any  { head :forbidden }
    end
  end
end
