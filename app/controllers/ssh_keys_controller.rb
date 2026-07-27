class SshKeysController < ApplicationController
  include OperatorOnly
  operator_only_all_actions! # reads expose decrypted secrets — owner/admin only
  before_action :set_ssh_key, only: [ :show, :edit, :update, :destroy ]

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

  # Generate a deploy keypair on the Conductor server itself (the a hosted PaaS
  # model): Conductor keeps the private key and shows you the public key to
  # authorize on your servers. No pasting, nothing generated on your machine.
  def generate
    keypair = DeployKeyGenerator.generate(comment: "conductor-#{current_organization.name.parameterize}")
    @ssh_key = current_organization.ssh_keys.new(name: params[:name].presence || "Conductor deploy key")
    @ssh_key.private_key = keypair[:private_key]

    if @ssh_key.save
      # Store ssh-keygen's authoritative OpenSSH public key + fingerprint (the
      # model's derived values can differ in format from an authorized_keys line).
      @ssh_key.update_columns(public_key: keypair[:public_key], fingerprint: keypair[:fingerprint])
      redirect_to ssh_key_path(@ssh_key), notice: "Deploy key generated. Add its public key to your servers (shown below)."
    else
      redirect_to new_ssh_key_path, alert: @ssh_key.errors.full_messages.to_sentence
    end
  rescue DeployKeyGenerator::Error => e
    redirect_to new_ssh_key_path, alert: "Could not generate a key: #{e.message}"
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
