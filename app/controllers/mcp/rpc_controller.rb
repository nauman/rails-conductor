# MCP standard transport — JSON-RPC 2.0 over HTTP (Streamable HTTP, JSON mode).
#
# This is the endpoint an MCP client registers natively:
#   claude mcp add --transport http conductor https://<host>/mcp \
#     --header "Authorization: Bearer <token>"
#
# It speaks the same ToolRegistry tools as the REST surface (Mcp::ServerController)
# but wraps them in the JSON-RPC envelope MCP clients expect: initialize,
# tools/list, tools/call, ping. Requests get a single application/json response
# (we don't push server-initiated messages, so we don't need SSE).
#
# Authentication: Bearer token, identical to the REST surface.
module Mcp
  class RpcController < ActionController::API
    include McpAuthentication
    include McpToolInvocation

    # Protocol revision we implement. Clients negotiate; we echo a version we
    # support. See https://spec.modelcontextprotocol.io.
    PROTOCOL_VERSION = "2025-06-18"
    SERVER_VERSION   = ENV.fetch("KAMAL_VERSION", "dev")

    # POST /mcp — a single JSON-RPC request (or a batch array).
    def handle
      payload = parse_body
      return render_error(nil, -32700, "Parse error") if payload.nil?

      responses = Array.wrap(payload).map { |message| handle_message(message) }.compact

      if responses.empty?
        head :accepted            # all notifications — no response body
      elsif payload.is_a?(Array)
        render json: responses
      else
        render json: responses.first
      end
    end

    # GET /mcp — we don't offer a server-initiated SSE stream.
    def stream
      head :method_not_allowed
    end

    private

    # Route one JSON-RPC message. Returns a response Hash, or nil for
    # notifications (methods with no id, which must not be answered).
    def handle_message(message)
      return nil unless message.is_a?(Hash)

      id     = message["id"]
      method = message["method"].to_s
      params = message["params"] || {}

      case method
      when "initialize"
        result(id, initialize_result)
      when "ping"
        result(id, {})
      when "tools/list"
        result(id, { tools: tool_definitions })
      when "tools/call"
        call_tool(id, params)
      when /\Anotifications\//
        nil                       # initialized / cancelled / etc. — acknowledge silently
      else
        error(id, -32601, "Method not found: #{method}")
      end
    end

    def initialize_result
      {
        protocolVersion: PROTOCOL_VERSION,
        capabilities:    { tools: { listChanged: false } },
        serverInfo:      { name: "conductor", version: SERVER_VERSION }
      }
    end

    # tools/call — params: { name:, arguments: }. A tool-level failure is
    # reported as a successful JSON-RPC response with isError: true (per MCP),
    # not a protocol error.
    def call_tool(id, params)
      name = params["name"].to_s
      args = params["arguments"] || {}

      return error(id, -32602, "Missing tool name") if name.blank?

      outcome = invoke_tool(name, args)
      text    = outcome.success? ? json_text(presentable_value(outcome.value)) : outcome.error.to_s

      result(id, {
        content: [ { type: "text", text: text } ],
        isError: !outcome.success?
      })
    end

    def json_text(value)
      value.is_a?(String) ? value : JSON.pretty_generate(value)
    end

    # --- JSON-RPC envelope helpers ---------------------------------------

    # A result for a request, or nil for a notification (no id → no reply).
    def result(id, value)
      return nil if id.nil?
      { jsonrpc: "2.0", id: id, result: value }
    end

    def error(id, code, message)
      { jsonrpc: "2.0", id: id, error: { code: code, message: message } }
    end

    # Render a top-level protocol error (bad JSON, unauthorized) immediately.
    def render_error(id, code, message)
      render json: error(id, code, message)
    end

    def parse_body
      raw = request.raw_post
      return {} if raw.blank?
      JSON.parse(raw)
    rescue JSON::ParserError
      nil
    end

    # Unauthorized as a JSON-RPC error (HTTP 401 so clients see the auth failure).
    def render_unauthorized
      render json: error(nil, -32001, "Unauthorized"), status: :unauthorized
    end
  end
end
