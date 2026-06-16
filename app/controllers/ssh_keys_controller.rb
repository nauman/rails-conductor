class SshKeysController < ApplicationController
  before_action :set_ssh_key, only: [:show, :edit, :update, :destroy]

  def index
    @ssh_keys = current_organization.ssh_keys.order(created_at: :desc)
  end

  def show
  end

  def new
    @ssh_key = current_organization.ssh_keys.new
  end

  def edit
  end

  def create
    @ssh_key = current_organization.ssh_keys.new(ssh_key_params)

    if @ssh_key.save
      redirect_to ssh_keys_path, notice: "SSH key added successfully."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update
    if @ssh_key.update(ssh_key_params)
      redirect_to ssh_keys_path, notice: "SSH key updated successfully."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    if @ssh_key.servers.any?
      redirect_to ssh_keys_path, alert: "Cannot delete SSH key that is in use by servers."
    else
      @ssh_key.destroy
      redirect_to ssh_keys_path, notice: "SSH key deleted."
    end
  end

  private

  def set_ssh_key
    @ssh_key = current_organization.ssh_keys.find(params[:id])
  end

  def ssh_key_params
    params.require(:ssh_key).permit(:name, :private_key, :passphrase)
  end
end
