# Read-only edge inspection. It intentionally reports through EdgeOperations so
# Caddy apps never get mistaken for kamal-proxy apps by a reader.
class EdgeStatusTool
  include ActorScoped

  def initialize(user:, operations_factory: nil)
    @user = user
    @operations_factory = operations_factory || ->(app) { EdgeOperations.new(app) }
  end

  def call(input)
    app = find_app(input)
    return Result.fail("App not found. Provide app_id or app_name.") unless app

    result = @operations_factory.call(app).call("inspect", message: nil)
    Result.ok({ app: app.name, edge: app.server&.edge_type, operation: :inspect, result: result,
                _organization: app.organization || app.server&.organization })
  rescue EdgeOperations::UnsupportedOperation => e
    Result.fail(e.message)
  end
end
