class CredentialsController < ApplicationController
  before_action :set_credential, only: [:edit, :update, :destroy]

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

  private

  def set_credential
    @credential = current_organization.credentials.find(params[:id])
  end

  def credential_params
    params.require(:credential).permit(:name, :provider, :api_key, :api_secret, :active)
  end
end
