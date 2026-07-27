module Oauth
  # Dynamic Client Registration (RFC 7591, spec 06). An MCP client — Codex, the
  # mcp-remote bridge, the claude.ai connector — POSTs its redirect URIs and gets
  # back a public client_id. No secret is issued: these are public clients that
  # authenticate with PKCE.
  #
  # Open by design. Registration grants nothing on its own; the security boundary
  # is the user's authorize step (sign in, pick an org) and the audience/membership
  # checks at /mcp. Rate-limited in config/initializers/rack_attack.rb.
  class RegistrationsController < ActionController::API
    SUPPORTED_SCOPES = Oauth::MetadataController::SCOPES

    def create
      redirect_uris = Array(registration_params[:redirect_uris]).reject(&:blank?)
      return render(json: { error: "invalid_redirect_uri" }, status: :bad_request) if redirect_uris.empty?

      scopes = requested_scopes
      return render(json: { error: "invalid_scope" }, status: :bad_request) if scopes.nil?

      application = Doorkeeper::Application.new(
        name: registration_params[:client_name].presence || "MCP client",
        redirect_uri: redirect_uris.join("\n"),
        scopes: scopes.join(" "),
        confidential: false # public client — PKCE, not a secret
      )

      # A rejected redirect URI is the client's error, not a 500 (e.g. plain http
      # to a non-loopback host — see force_ssl_in_redirect_uri).
      unless application.save
        return render json: { error: "invalid_redirect_uri",
                              error_description: application.errors.full_messages.to_sentence },
                      status: :bad_request
      end

      render json: {
        client_id: application.uid,
        client_id_issued_at: application.created_at.to_i,
        client_name: application.name,
        redirect_uris: redirect_uris,
        token_endpoint_auth_method: "none",
        grant_types: %w[authorization_code refresh_token],
        response_types: %w[code],
        scope: scopes.join(" ")
      }, status: :created
    end

    private

    # nil signals an unsupported scope was asked for; [] is never returned.
    def requested_scopes
      scopes = registration_params[:scope].to_s.split
      return SUPPORTED_SCOPES if scopes.empty?

      scopes if (scopes - SUPPORTED_SCOPES).empty?
    end

    def registration_params
      params.permit(:client_name, :scope, :token_endpoint_auth_method,
                    redirect_uris: [], grant_types: [], response_types: [])
    end
  end
end
