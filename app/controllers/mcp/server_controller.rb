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

      McpCall.record(tool_name: name, arguments: input, result: result, duration_ms: duration_ms, user: mcp_user)

      if result.success?
        render json: { result: result.value }
      else
        render json: { error: result.error }, status: :unprocessable_entity
      end
    end

    private

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
