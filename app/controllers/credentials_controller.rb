class CredentialsController < ApplicationController
  include OperatorOnly
  operator_only_all_actions! # reads expose decrypted secrets — owner/admin only
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

  # Verify a Cloudflare token + cache its account/zones (multi-account resolution).
  def verify
    unless @credential.cloudflare?
      return redirect_to credentials_path, alert: "Verify is only for Cloudflare connections."
    end

    if (error = @credential.verify_cloudflare!)
      redirect_to credentials_path, alert: "Cloudflare verify failed: #{error}"
    else
      redirect_to credentials_path, notice: "#{@credential.name} verified — #{@credential.zones_list.size} zone(s) found."
    end
  end

  private

  def set_credential
    @credential = current_organization.credentials.find(params[:id])
  end

  def credential_params
    params.require(:credential).permit(:name, :provider, :api_key, :api_secret, :account_id, :active)
  end
end
