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

    # Protocol revision we implement + the ones we still accept from clients.
    PROTOCOL_VERSION   = "2025-06-18"
    SUPPORTED_VERSIONS = %w[2025-06-18 2025-03-26 2024-11-05].freeze
    SERVER_VERSION     = ENV.fetch("KAMAL_VERSION", "dev")

    before_action :validate_origin!
    before_action :validate_protocol_version!

    # POST /mcp — a single JSON-RPC request. (2025-06-18 removed JSON-RPC batching.)
    def handle
      payload = parse_body
      return render_error(nil, -32700, "Parse error") if payload.nil?
      return render_error(nil, -32600, "Batch requests are not supported (MCP #{PROTOCOL_VERSION})") if payload.is_a?(Array)

      response = handle_message(payload)
      response ? render(json: response) : head(:accepted) # nil = a notification, no reply
    end

    # GET /mcp — we don't offer a server-initiated SSE stream.
    def stream
      head :method_not_allowed
    end

    private

    # DNS-rebinding protection (MCP transport spec): browsers attach Origin;
    # reject any that isn't this server's own host. Native clients (claude mcp,
    # Cursor) send no Origin and pass through untouched.
    def validate_origin!
      origin = request.headers["Origin"]
      return if origin.blank? || allowed_origin?(origin)

      render json: error(nil, -32600, "Origin not allowed"), status: :forbidden
    end

    def allowed_origin?(origin)
      host = (URI(origin).host rescue nil)
      return false if host.blank?

      [ request.host, ENV["APP_HOST"].presence, "localhost", "127.0.0.1", "[::1]" ].compact.include?(host)
    end

    # Honor the negotiated MCP-Protocol-Version header (sent after initialize)
    # instead of silently ignoring it: an unknown version is a 400.
    def validate_protocol_version!
      version = request.headers["MCP-Protocol-Version"]
      return if version.blank? || SUPPORTED_VERSIONS.include?(version)

      render json: error(nil, -32600, "Unsupported MCP-Protocol-Version: #{version}"), status: :bad_request
    end

    # Route one JSON-RPC message. Returns a response Hash, or nil for a
    # notification (no reply). Never raises on malformed input.
    def handle_message(message)
      return error(nil, -32600, "Invalid Request") unless message.is_a?(Hash)

      id     = message["id"]
      method = message["method"].to_s
      params = message["params"].nil? ? {} : message["params"]
      return error(id, -32602, "Invalid params: expected an object") unless params.is_a?(Hash)

      case method
      when "initialize"          then result(id, initialize_result(params))
      when "ping"                then result(id, {})
      when "tools/list"          then result(id, { tools: tool_definitions })
      when "tools/call"          then call_tool(id, params)
      when %r{\Anotifications/}  then nil # initialized / cancelled / etc. — no reply
      else error(id, -32601, "Method not found: #{method}")
      end
    end

    def initialize_result(params)
      requested = params["protocolVersion"]
      negotiated = SUPPORTED_VERSIONS.include?(requested) ? requested : PROTOCOL_VERSION
      {
        protocolVersion: negotiated,
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
