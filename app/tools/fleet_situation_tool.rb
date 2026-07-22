# MCP: the "resume" read. A reconnecting agent calls this once to reorient —
# what's in flight, what needs a decision, what just happened — instead of
# stitching together several reads. Actor-scoped; read-only.
class FleetSituationTool
  include ActorScoped

  DEFINITION = {
    name: "fleet_situation",
    description: "Resume point for a reconnecting agent: in-flight operations, a needs-attention worklist " \
      "(blocked/failed deploys, failed seeds, deploy holds, at-risk servers — each with the app + runbook state), " \
      "and recent terminal events. Call this first after (re)connecting to pick up where work left off.",
    input_schema: {
      type: "object",
      properties: {
        recent_limit: { type: "integer", description: "How many recent terminal deployments to include (default 8, max 25)" }
      },
      required: []
    }
  }.freeze

  def initialize(user:)
    @user = user
  end

  def call(input = {})
    Result.ok(FleetSituation.new(server_scope: visible_servers, recent_limit: input["recent_limit"] || 8).snapshot)
  end
end
