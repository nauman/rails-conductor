# The mutating edge surface. This is deliberately an action inside
# conductor_app, not a second deployment tool: EdgeOperations owns the
# Caddy-vs-kamal-proxy decision and this handler only applies authorization and
# confirmation policy at the MCP boundary.
class EdgeAppTool
  include ActorScoped

  OPERATIONS = %w[reconcile redeploy maintenance live].freeze

  def initialize(user:, operations_factory: nil)
    @user = user
    @operations_factory = operations_factory || ->(app, user) { EdgeOperations.new(app, user: user, force: false) }
  end

  def call(input)
    app = find_app(input)
    return Result.fail("App not found. Provide app_id or app_name.") unless app

    operation = input["operation"].to_s
    return Result.fail("Unknown edge operation '#{operation}'. Use: #{OPERATIONS.join(', ')}.") unless OPERATIONS.include?(operation)
    return Result.fail("Edge operation '#{operation}' requires confirm:true.") unless input["confirm"] == true

    operations = @operations_factory.call(app, @user)
    value = operations.call(operation, message: input["message"])
    Result.ok({ app: app.name, operation: operation, result: value, _organization: app.organization || app.server&.organization })
  rescue EdgeOperations::UnsupportedOperation => e
    Result.fail(e.message)
  end
end
