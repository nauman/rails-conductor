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

      result = ToolRegistry.call(name, input, user: mcp_user)

      if result.success?
        render json: { result: strip_organization(name, result.value) }
      else
        render json: { error: result.error }, status: :unprocessable_entity
      end
    end

    private

    # Resource tools embed the affected Organization under `_organization` so the
    # call can be attributed in the audit trail. We log it for attribution and
    # strip it from the payload so the internal record never leaks to the client.
    def strip_organization(tool_name, value)
      return value unless value.is_a?(Hash)

      org = value[:_organization] || value["_organization"]
      if org
        Rails.logger.info("[MCP] #{tool_name} affected organization=#{org.id} (#{org.name}) actor=#{mcp_user&.email}")
      end
      value.except(:_organization, "_organization")
    end

    def authenticate_mcp_token!
      token = request.headers['Authorization']&.sub(/\ABearer\s+/, '')
      expected = ENV['CONDUCTOR_MCP_TOKEN']

      if expected.blank?
        render json: { error: 'MCP not configured (CONDUCTOR_MCP_TOKEN not set)' }, status: :service_unavailable
      elsif !ActiveSupport::SecurityUtils.secure_compare(token.to_s, expected)
        render json: { error: 'Unauthorized' }, status: :unauthorized
      end
    end

    # MCP calls run as the first admin user (system actor).
    def mcp_user
      @mcp_user ||= User.admins.first
    end
  end
end
