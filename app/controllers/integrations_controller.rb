# Settings → Integrations: configure Conductor-wide integrations in the browser.
#
# Today this is the GitHub App (app_id + PEM private key) — the UI equivalent of
# the `set_github_app` MCP tool. Stored Conductor-wide (organization: nil), so
# it's admin-only. Reuses SetGithubAppTool for validation + storage so the UI and
# the MCP path behave identically.
class IntegrationsController < ApplicationController
  before_action :require_admin!

  def show
    @github_app = Credential.for_provider("github_app").active.first
    @configured = @github_app&.api_key.present? && @github_app&.api_secret.present?
  end

  def update
    result = SetGithubAppTool.new(user: current_user).call(
      "app_id" => params[:app_id].to_s, "private_key" => params[:private_key].to_s
    )

    if result.success?
      redirect_to integrations_path, notice: "GitHub App saved. Install it on your org(s), then your apps can deploy from their repos."
    else
      @github_app = Credential.for_provider("github_app").active.first
      @configured = @github_app&.api_key.present? && @github_app&.api_secret.present?
      flash.now[:alert] = result.error
      render :show, status: :unprocessable_entity
    end
  end

  # Confirm the App can see your orgs (the UI equivalent of github_installations).
  def verify
    gh = GithubApp.from_config
    if gh.nil?
      redirect_to integrations_path, alert: "Configure the GitHub App first."
      return
    end

    @installations = gh.installations
    redirect_to integrations_path, notice: "Installed on: #{@installations.map { |i| i[:account] }.join(', ').presence || 'no orgs yet — click Install on the App page'}."
  rescue GithubApp::Error => e
    redirect_to integrations_path, alert: e.message
  end
end
