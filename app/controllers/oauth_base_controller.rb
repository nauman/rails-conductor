# Base controller for doorkeeper's HTML authorize endpoint (spec 06).
#
# Inherits current_user + the passwordless helpers from ApplicationController but
# skips the app gates: the OAuth flow decides for itself who may authorize (via
# the initializer's resource_owner_authenticator), and an un-onboarded org must
# not bounce a connector into the onboarding wizard mid-handshake.
class OauthBaseController < ApplicationController
  skip_before_action :authenticate_user!
  skip_before_action :set_current_organization
  skip_before_action :require_onboarding

  # Params a consent form must hand back for doorkeeper to build the same
  # authorization request the client asked for.
  AUTHORIZE_PARAMS = %w[
    client_id redirect_uri response_type scope state
    code_challenge code_challenge_method resource
  ].freeze

  private

  # The interactive gate in front of every authorization: approve this client,
  # for this organization.
  #
  # Two jobs, and both matter:
  #
  # 1. **Consent.** A GET must never mint anything. Registration is open (RFC
  #    7591), so anyone can be a client; if a GET could authorize, an attacker
  #    would register a redirect URI they control, send a signed-in user to the
  #    authorize URL, and receive a code without the user doing anything. PKCE is
  #    no defence there — the attacker is the client. So GET renders a form and
  #    only the CSRF-protected POST it submits is allowed through.
  # 2. **Organization binding.** Conductor confines an MCP caller to ONE org
  #    (Current.org_scoped), exactly as an org-bound ApiToken does, so the token
  #    being minted has to carry one. It travels as the `organization_id` param
  #    and is captured onto the grant/token by `custom_access_token_attributes`.
  #
  # Trust nothing from the client: membership is verified before the param is
  # honoured, and again on every MCP call (McpAuthentication) — a token must not
  # outlive the membership it was minted under.
  #
  # Renders (halting the filter chain) unless the request is an approved POST.
  def bind_mcp_organization!
    # set_current_organization is skipped here, so do its self-heal ourselves —
    # a user created before orgs existed must still be able to connect.
    current_user.ensure_personal_organization!
    organizations = current_user.organizations.reload

    return unless request.get? || request.post?
    # An unknown client or an unregistered redirect URI is doorkeeper's error to
    # report — don't show a consent screen for a request that can't succeed.
    return unless authorizable_client?

    if request.post?
      return if params[:organization_id].present? && organizations.exists?(id: params[:organization_id])

      render "oauth/organization_forbidden", status: :forbidden, locals: { organizations: organizations }
      return
    end

    render "oauth/consent", locals: {
      organizations: organizations,
      client: requested_client,
      scopes: requested_scopes,
      hidden_params: params.slice(*AUTHORIZE_PARAMS).permit!.to_h
    }
  end

  def requested_client
    return @requested_client if defined?(@requested_client)

    @requested_client = Doorkeeper::Application.find_by(uid: params[:client_id].to_s)
  end

  def authorizable_client?
    requested_client.present? &&
      requested_client.redirect_uri.to_s.split.include?(params[:redirect_uri].to_s)
  end

  # What the client asked for, defaulted the way doorkeeper will default it.
  def requested_scopes
    params[:scope].presence&.split || Doorkeeper.config.default_scopes.to_a
  end
end
