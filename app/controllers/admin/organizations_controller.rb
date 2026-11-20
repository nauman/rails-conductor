module Admin
  class OrganizationsController < BaseController
    def index
      @organizations = Organization.includes(:users).order(:name)
    end

    def show
      @organization = Organization.find(params[:id])
    end

    # Plan 02 § 5.3: an admin can always demote or suspend. Suspension revokes
    # tokens and OAuth grants; SshConnection then refuses the org's servers.
    def suspend
      organization = Organization.find(params[:id])
      organization.suspend!(by: current_user, reason: "admin")
      redirect_to admin_organization_path(organization), notice: "#{organization.name} is suspended."
    end

    # Back to `new`, never straight to `trusted`: a reinstated org earns trust
    # again through the same promotion rule. Its revoked tokens stay revoked.
    def reinstate
      organization = Organization.find(params[:id])
      organization.change_trust!(organization.self_signed_up? ? "new" : "trusted", reason: "admin reinstate", by: current_user)
      redirect_to admin_organization_path(organization), notice: "#{organization.name} is reinstated as #{organization.trust_level}."
    end
  end
end
