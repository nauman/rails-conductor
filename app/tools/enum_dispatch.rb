# Shared dispatch for the consolidated, flat `action`-enum MCP tools. The
# including class declares an
# `ACTIONS` map of action-string => single-purpose implementation class; this
# concern picks the handler by `input["action"]` and passes the whole input
# through (each handler reads only the keys it knows; the extra `action` key is
# ignored). JSON Schema can't express "param X required only when action=Y", so
# the schema stays permissive and each handler validates its own params and
# returns a legible Result.fail.
module EnumDispatch
  def initialize(user:)
    @user = user
  end

  def call(input = {})
    actions = self.class::ACTIONS
    handler = actions[input["action"]]
    unless handler
      return Result.fail("Missing or unknown action '#{input['action']}'. Set action to one of: #{actions.keys.join(', ')}.")
    end

    handler.new(user: @user).call(input)
  end
end
