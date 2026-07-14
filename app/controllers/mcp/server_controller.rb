# MCP (Model Context Protocol) — custom REST surface.
#
# A simple, human-curlable JSON API over the ToolRegistry tools:
#   GET  /mcp/list  → { tools: [...] }
#   GET  /mcp/skill → { name, skill }  (the agent how-to)
#   POST /mcp/call  → { name: "conductor_read", input: { action: "fleet_status" } } → { result: ... }
#
# For agents that speak the standard MCP JSON-RPC transport (Claude Code,
# Cursor, Desktop), see Mcp::RpcController at POST /mcp. Both share the auth and
# dispatch concerns so the tool-call path lives once.
#
# Authentication: Bearer token (per-user/org ApiToken, or CONDUCTOR_MCP_TOKEN).
module Mcp
  class ServerController < ActionController::API
    include McpAuthentication
    include McpToolInvocation

    SKILL_DOC = Rails.root.join("docs/skills/conductor/SKILL.md")

    # GET /mcp/list — all available tool definitions.
    def list
      render json: { tools: tool_definitions }
    end

    # GET /mcp/skill — the judgment layer that complements /mcp/list.
    def skill
      render json: { name: "conductor", skill: SKILL_DOC.read }
    end

    # POST /mcp/call — { "name": ..., "input": { "action": ... } }
    def call
      name  = params[:name].to_s
      input = (params[:input] || {}).to_unsafe_h

      result = invoke_tool(name, input)

      if result.success?
        render json: { result: presentable_value(result.value) }
      else
        render json: { error: result.error }, status: :unprocessable_entity
      end
    end
  end
end
