module Oauth
  # OAuth discovery for MCP clients (spec 06). These two documents are the whole
  # reason a client can offer "Connect" instead of asking for a pasted token:
  #   /.well-known/oauth-authorization-server  (RFC 8414) — where to authorize
  #   /.well-known/oauth-protected-resource    (RFC 9728) — who guards /mcp
  # Both are public and unauthenticated by design.
  class MetadataController < ActionController::API
    # `mcp` = deploy (full), `mcp_read` = read-only. Mirrors ApiToken's scopes.
    SCOPES = %w[mcp mcp_read].freeze

    def authorization_server
      render json: {
        issuer: base,
        authorization_endpoint: "#{base}/oauth/authorize",
        token_endpoint: "#{base}/oauth/token",
        registration_endpoint: "#{base}/oauth/register",
        revocation_endpoint: "#{base}/oauth/revoke",
        response_types_supported: %w[code],
        grant_types_supported: %w[authorization_code refresh_token],
        code_challenge_methods_supported: %w[S256],
        # Public clients only — PKCE stands in for a client secret.
        token_endpoint_auth_methods_supported: %w[none],
        scopes_supported: SCOPES
      }
    end

    def protected_resource
      render json: {
        resource: "#{base}/mcp",
        authorization_servers: [ base ],
        scopes_supported: SCOPES,
        bearer_methods_supported: %w[header],
        resource_documentation: "#{base}/docs/mcp"
      }
    end

    private

    def base = request.base_url
  end
end
