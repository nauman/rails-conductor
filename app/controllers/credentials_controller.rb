class CredentialsController < ApplicationController
  include OperatorOnly
  operator_only_all_actions! # reads expose decrypted secrets — owner/admin only
  owner_only_controller! :credentials # fleet-wide provider keys, not per-app config
  before_action :set_credential, only: [:edit, :update, :destroy, :verify]

  def index
    @credentials = current_organization.credentials.order(created_at: :desc)
  end

  def new
    @credential = current_organization.credentials.new
  end

  def edit
  end

  def create
    @credential = current_organization.credentials.new(credential_params)

    if @credential.save
      redirect_to credentials_path, notice: "Credential created successfully."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update
    if @credential.update(credential_params)
      redirect_to credentials_path, notice: "Credential updated successfully."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @credential.destroy
    redirect_to credentials_path, notice: "Credential deleted."
  end

  # Verify a connection's credentials. Cloudflare → token + cache zones; SES → SMTP auth.
  def verify
    error, ok_msg =
      if @credential.cloudflare?
        [ @credential.verify_cloudflare!, "verified — #{@credential.zones_list.size} zone(s) found." ]
      elsif @credential.ses?
        [ @credential.verify_ses!, "verified — SES SMTP credentials accepted." ]
      else
        return redirect_to credentials_path, alert: "Verify isn't available for #{@credential.provider.titleize}."
      end

    if error
      redirect_to credentials_path, alert: "#{@credential.name} verify failed: #{error}"
    else
      redirect_to credentials_path, notice: "#{@credential.name} #{ok_msg}"
    end
  end

  private

  def set_credential
    @credential = current_organization.credentials.find(params[:id])
  end

  def credential_params
    params.require(:credential).permit(:name, :provider, :api_key, :api_secret, :account_id, :region, :endpoint, :active)
  end
end
