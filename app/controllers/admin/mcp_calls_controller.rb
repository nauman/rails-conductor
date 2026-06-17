module Admin
  class McpCallsController < BaseController
    def index
      @mcp_calls = McpCall.includes(:user).recent.limit(200)
    end
  end
end
