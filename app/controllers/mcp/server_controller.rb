# MCP (Model Context Protocol) server endpoint.
#
# Exposes the ToolRegistry tools over HTTP JSON-RPC so that any MCP-compatible
# AI agent (Claude Desktop, ../conductor chat, Cursor, etc.) can call conductor
# tools directly.
#
# Authentication: Bearer token via CONDUCTOR_MCP_TOKEN env var.
#
# Endpoints:
#   GET  /mcp/list  → returns { tools: [...] }
#   POST /mcp/call  → { name: "fleet_status", input: {} } → { result: ... }
#
module Mcp
  class ServerController < ActionController::API
    before_action :authenticate_mcp_token!

    # GET /mcp/list
    # Returns all available tool definitions.
    def list
      render json: {
        tools: ToolRegistry.definitions.map do |d|
          {
            name:        d[:name],
            description: d[:description],
            inputSchema: d[:input_schema]
          }
        end
      }
    end

    # POST /mcp/call
    # Body: { "name": "fleet_status", "input": {} }
    def call
      name  = params[:name].to_s
      input = (params[:input] || {}).to_unsafe_h.stringify_keys

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = ToolRegistry.call(name, input, user: mcp_user)
      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round

      # Affected-org logging: resource tools embed the org they touched under the
      # `_organization` key of their (Hash) Result payload. We record it on the
      # McpCall for the audit log, then strip the key so it never leaks to the client.
      # List tools (fleet_status, recent_logs) return arrays and log no single org.
      organization = affected_organization(result)

      McpCall.record(
        tool_name:    name,
        arguments:    input,
        result:       result,
        duration_ms:  duration_ms,
        user:         mcp_user,
        organization: organization
      )

      if result.success?
        render json: { result: presentable_value(result.value) }
      else
        render json: { error: result.error }, status: :unprocessable_entity
      end
    end

    private

    # The org a successful resource tool acted on, or nil (admin-global).
    def affected_organization(result)
      return nil unless result.success?
      value = result.value
      value[:_organization] if value.is_a?(Hash)
    end

    # Strip the internal `_organization` marker before responding to the client.
    def presentable_value(value)
      value.is_a?(Hash) ? value.except(:_organization) : value
    end

    def authenticate_mcp_token!
      token = request.headers['Authorization']&.sub(/\ABearer\s+/, '')

      # Multi-tenant: a per-user / per-org API token runs as that user (a
      # non-admin), so tools are scoped to their organizations (see ActorScoped).
      if (api_token = ApiToken.authenticate(token))
        @mcp_user = api_token.user
        return
      end

      # Legacy single-tenant: the shared CONDUCTOR_MCP_TOKEN runs as the first
      # admin (global scope), preserving existing behaviour.
      expected = ENV['CONDUCTOR_MCP_TOKEN']
      if expected.present? && ActiveSupport::SecurityUtils.secure_compare(token.to_s, expected)
        @mcp_user = User.admins.first
        return
      end

      render json: { error: 'Unauthorized' }, status: :unauthorized
    end

    # The actor for this MCP call — a per-user token's user, or the first admin
    # for the legacy shared token. Tools scope resource access off this user.
    def mcp_user
      @mcp_user
    end
  end
end
