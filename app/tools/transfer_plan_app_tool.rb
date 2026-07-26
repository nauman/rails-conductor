# Read-only dry-run for an app transfer (spec 26): emits the staged change set
# (compute / database / edge / cutover / drain) + warnings for moving an app to
# a target server, without mutating anything. The "make sense of it" artifact an
# agent reviews before a transfer is executed.
class TransferPlanAppTool
  include ActorScoped

  DEFINITION = {
    name: "transfer_plan",
    description: "Dry-run an app transfer to another server: emit the staged change set " \
      "(compute/database/edge/cutover/drain) + warnings, with ZERO mutation. " \
      "app_id/app_name + target_server_id/target_server_name.",
    input_schema: {
      type: "object",
      properties: {
        app_id:              { type: "integer", description: "App to move, by id (or app_name)" },
        app_name:            { type: "string",  description: "App to move, by name (or app_id)" },
        target_server_id:    { type: "integer", description: "Destination server, by id (or target_server_name)" },
        target_server_name:  { type: "string",  description: "Destination server, by name (or target_server_id)" }
      },
      required: []
    }
  }.freeze

  def initialize(user:)
    @user = user
  end

  def call(input)
    app = find_app(input)
    return Result.fail("App not found: #{input['app_id'] || input['app_name']}") unless app

    target = find_target(input)
    return Result.fail("Target server not found: #{input['target_server_id'] || input['target_server_name']}") unless target

    plan = AppTransferPlan.new(app: app, target_server: target).call
    Result.ok(plan.to_h.merge(_organization: app.organization || app.server&.organization))
  rescue AppTransferPlan::InvalidTarget => e
    Result.fail(e.message)
  end

  private

  def find_target(input)
    if input["target_server_id"].present?
      visible_servers.find_by(id: input["target_server_id"])
    elsif input["target_server_name"].present?
      visible_servers.find_by(name: input["target_server_name"])
    end
  end
end
