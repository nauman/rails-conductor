# Onboarding step 2 (plan 02 § 3): register a server with proof of control.
#
# Conductor generates an org-scoped key, shows the one authorized_keys line to
# install (its comment carries this registration's nonce), and verifies by
# connecting with that key and reading the nonce back. Until then no job runs on
# the server (SshConnection refuses it).
class OnboardingServersController < ApplicationController
  before_action :require_operator!
  before_action :set_server, only: [ :show, :verify ]

  def new
    @server = current_organization.servers.new(ssh_user: "deploy", ssh_port: 22)
  end

  def create
    @server = current_organization.servers.new(server_params.merge(status: "offline"))
    key = generate_key
    @server.ssh_key = key
    if key && @server.save
      ServerOwnership.issue_nonce!(@server)
      redirect_to onboarding_server_verification_path(@server)
    else
      key&.destroy
      @server.errors.add(:base, "Conductor could not generate a key") unless key
      render :new, status: :unprocessable_entity
    end
  end

  def show
    ServerOwnership.issue_nonce!(@server) if @server.ownership_nonce.blank?
    @authorized_keys_line = ServerOwnership.authorized_keys_line(@server)
  end

  def verify
    result = ServerOwnership.new(@server).verify!
    if result.ok?
      redirect_to onboarding_agent_path, notice: "#{@server.name} is verified. #{result.detail}"
    else
      @authorized_keys_line = ServerOwnership.authorized_keys_line(@server)
      @verification_error = result.detail
      render :show, status: :unprocessable_entity
    end
  end

  private

  def require_operator!
    redirect_to root_path, alert: "Only an owner or editor can register servers." unless current_operator?
  end

  def set_server
    @server = current_organization.servers.find(params[:id])
  end

  def server_params
    params.require(:server).permit(:name, :ip_address, :ssh_user, :ssh_port)
  end

  def generate_key
    keypair = DeployKeyGenerator.generate(comment: "conductor-#{current_organization.id}")
    key = current_organization.ssh_keys.new(name: "Conductor key for #{server_params[:name].to_s.first(60)} #{SecureRandom.hex(3)}")
    key.private_key = keypair[:private_key]
    return nil unless key.save

    key.update_columns(public_key: keypair[:public_key], fingerprint: keypair[:fingerprint])
    key
  rescue DeployKeyGenerator::Error
    nil
  end
end
