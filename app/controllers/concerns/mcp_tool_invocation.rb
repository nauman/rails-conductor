# Shared tool dispatch + audit logging for the MCP endpoints.
#
# Runs a ToolRegistry tool, times it, records an McpCall for the audit log
# (attributing the affected org), and returns the tool's Result. Both the REST
# controller and the JSON-RPC transport call this so the invocation path — and
# the `_organization` marker handling — lives in exactly one place.
module McpToolInvocation
  extend ActiveSupport::Concern

  private

  # Invoke a tool by name with a Hash of input, log the call, return its Result.
  def invoke_tool(name, input)
    input = input.to_h.stringify_keys

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = ToolRegistry.call(name, input, user: mcp_user)
    duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round

    McpCall.record(
      tool_name:    name,
      arguments:    input,
      result:       result,
      duration_ms:  duration_ms,
      user:         mcp_user,
      organization: affected_organization(result)
    )

    result
  end

  # Tool definitions in MCP shape (name/description/inputSchema).
  def tool_definitions
    ToolRegistry.definitions.map do |d|
      { name: d[:name], description: d[:description], inputSchema: d[:input_schema] }
    end
  end

  # The org a successful resource tool acted on, or nil (admin-global).
  def affected_organization(result)
    return nil unless result.success?
    value = result.value
    value[:_organization] if value.is_a?(Hash)
  end

  # Strip the internal `_organization` marker before returning to the client.
  def presentable_value(value)
    value.is_a?(Hash) ? value.except(:_organization) : value
  end
end
