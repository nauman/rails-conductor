class AddOrganizationToMcpCalls < ActiveRecord::Migration[8.1]
  def change
    # Nullable: most MCP calls run admin-global (no single org). When a call
    # acts on a specific server/app, we record which org it touched for the audit log.
    add_reference :mcp_calls, :organization, null: true, foreign_key: true, index: true
  end
end
