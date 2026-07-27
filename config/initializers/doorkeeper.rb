# frozen_string_literal: true

# OAuth 2.1 authorization server for the MCP endpoint (spec 06).
#
# Why: an MCP client (Codex, claude.ai, Cursor) should be able to connect by
# signing in through the browser, instead of the user hand-minting a bearer token
# at /mcp_tokens and pasting it into a config file. Static ApiTokens keep working
# — this is an additional way in (see McpAuthentication).
#
# Shape: authorization-code + PKCE only, public clients created by dynamic client
# registration (RFC 7591), tokens audience-bound to this MCP resource (RFC 8707)
# and organization-bound (Conductor confines an MCP caller to one org).
Doorkeeper.configure do
  orm :active_record

  # Only the HTML authorize endpoint inherits this; /oauth/token runs on
  # doorkeeper's metal controller, so it is unaffected by the app's gates/CSRF.
  base_controller "OauthBaseController"

  # Who may authorize. The block is instance_eval'd in OauthBaseController, so it
  # can use the app's passwordless helpers and redirect for the sign-in and
  # org-selection steps.
  resource_owner_authenticator do
    if current_user.nil?
      # Stash the authorize URL so the magic link returns here and the flow resumes.
      save_passwordless_redirect_location!(User)
      redirect_to user_sign_in_path, alert: "Sign in to connect your Conductor account."
      nil
    else
      bind_mcp_organization!  # may redirect to the org picker
      current_user unless performed?
    end
  end

  # Consent is OUR screen, not doorkeeper's: bind_mcp_organization! renders it on
  # GET /oauth/authorize and only lets the flow through on the CSRF-protected POST
  # it submits. By the time doorkeeper is asked to authorize, the user has already
  # approved this client, org, and scope — hence skip here rather than render
  # doorkeeper's own view on top of ours.
  #
  # Do NOT turn this into an unconditional auto-approve: registration is open
  # (RFC 7591), so any client can exist. Without an interactive step, an attacker
  # could register a redirect URI they control and get a signed-in user's browser
  # to hand them a code with no interaction at all — PKCE doesn't help, because
  # the attacker IS the client holding the verifier.
  skip_authorization { true }

  # Store only digests of access/refresh tokens. Doorkeeper defaults to plaintext;
  # a leaked backup or read-only replica would otherwise hand over live bearer
  # tokens. Matches ApiToken, which stores a SHA-256 digest.
  hash_token_secrets

  # Authorization code + PKCE only. No implicit, no password grant.
  grant_flows %w[authorization_code]
  force_pkce
  pkce_code_challenge_methods %w[S256] # OAuth 2.1: no `plain`
  use_refresh_token

  # RFC 8252: native clients (Codex CLI, the mcp-remote bridge) receive the code
  # on an ephemeral loopback listener, which is plain http. Require https for
  # every other redirect target.
  force_ssl_in_redirect_uri do |uri|
    host = (uri.respond_to?(:hostname) ? uri.hostname : uri.host).to_s.downcase
    !Rails.env.development? && !%w[localhost 127.0.0.1 ::1].include?(host)
  end

  access_token_expires_in 2.hours

  # `mcp` = full (deploy) access, `mcp_read` = read-only. A client that asks for
  # mcp_read alone gets a token the MCP layer refuses every write tool on, which
  # mirrors the read/deploy scopes on ApiToken.
  default_scopes :mcp
  optional_scopes :mcp_read

  # Carried authorize-request -> grant -> access token (and across refreshes):
  #   resource        RFC 8707 audience; /mcp rejects a token minted elsewhere.
  #   organization_id the single org this token may act in.
  custom_access_token_attributes [ :resource, :organization_id ]
end
